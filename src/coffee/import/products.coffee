nutil = require 'util'
Q = require 'q'
_ = require 'lodash-node'
_s = require 'underscore.string'
{ProductSync} = require 'sphere-node-sync'
SphereClient = require 'sphere-node-client'
{Qutils} = require 'sphere-node-utils'
{_u} = require 'sphere-node-utils'
utils = require '../../lib/utils'



###
Imports Brickfox products provided as XML into SPHERE.IO
###
# TODO: Send product inventories / stock after product update / creation (or maybe creation only???)
# TODO: Send product updates for products with flag isNew = 0 and make sure product variants are not removed and created again but updated only
# TODO: Send category deletes for categories without products
class Products

  constructor: (@_options = {}) ->
    @productSync = new ProductSync @_options
    @client = new SphereClient @_options
    @client.setMaxParallel(100)
    @logger = @_options.appLogger
    @allEnumAttributes = []
    @productsUpdated = 0
    @productsCreated = 0
    @productsCreateSkipped = 0
    @productsCreateIgnored = 0
    @success = false

  execute: (productsXML, mappings) ->
    @startTime = new Date().getTime()
    Q.spread [
      @client.productTypes.perPage(0).fetch()
      @client.categories.perPage(0).fetch()
    ], (fetchedProductTypesResult, fetchedCategoriesResult) =>
      utils.assertProductIdMappingIsDefined mappings.productImport.mapping
      utils.assertVariationIdMappingIsDefined mappings.productImport.mapping
      utils.assertSkuMappingIsDefined mappings.productImport.mapping
      fetchedCategories = utils.transformByCategoryExternalId(fetchedCategoriesResult.body.results)
      productType = utils.getProductTypeByConfig(fetchedProductTypesResult.body.results, mappings.productImport.productTypeId, @_options.config.project_key)
      @logger.info "[Products] Total products to import: '#{_.size productsXML.Products?.Product}'"
      @products = @buildProducts(productsXML.Products?.Product, productType, fetchedCategories, mappings)

      if _.size(@allEnumAttributes) > 0
        @_logMissingAttributes(@allEnumAttributes, productType)

      productUpdates = @products.updates
      if _.size(productUpdates) > 0
        @logger.info "[Products] Update count: '#{_.size productUpdates}'"
        productIdMapping = mappings.productImport.mapping.ProductId.to
        counter = 0
        Qutils.processList productUpdates, (p) =>
          counter = counter + 1
          attr = @_findAttributeByName(p[0], productIdMapping, true)
          @_fetchProductByAttribute(attr)
          .then (fetchedProductResult) =>
            oldProduct = fetchedProductResult?.body?.results?[0]
            throw new Error "Could not find product to update by attribute name: '#{productIdMapping}' and value: '#{attr.value}' in SPHERE.IO" if not oldProduct
            @logger.info "[Products] About to update product with id: '#{attr.value}', counter: '#{counter}'"
            update = @productSync.buildActions(p[0], oldProduct).get()
            Q()
            # TODO: activate once SPHERE fixes delete and add variant with unique constraint attribute in one update action
            # TODO: make sure variants are not dropped and created from scratch but updated only.
            #@client.products.byId(oldProduct.id).update(update)
            #.then ->
            #  @productsUpdated = @productsUpdated + 1
    .then (updateProductsResult) =>
      productCreates = @products.creates
      if _.size(productCreates) > 0
        @logger.info "[Products] Create count: '#{_.size productCreates}'"
        if @_options.safeCreate
          productIdMapping = mappings.productImport.mapping.ProductId.to
          counter = 0
          Qutils.processList productCreates, (p) =>
            counter = counter + 1
            attr = @_findAttributeByName(p[0], productIdMapping, true)
            @_fetchProductByAttribute(attr)
            .then (fetchedProductResult) =>
              oldProduct = fetchedProductResult?.body?.results[0]
              if not oldProduct
                @logger.info "[Products] About to create product with id: '#{attr.value}', counter: '#{counter}'"
                # product does not exist yet, create it
                @_createProduct(p[0])
              else
                # product already exists - skip creation
                @productsCreateSkipped = @productsCreateSkipped + 1
                Q()
        else
          Q.all(_.map(productCreates, (p) => @_createProduct(p)))
    .then (createProductsResult) =>
      @success = true

  outputSummary: ->
    endTime = new Date().getTime()
    summary =
      result: if @success then 'SUCCESS' else 'ERROR'
      productsUpdated: @productsUpdated
      productsCreated: @productsCreated
      productsCreateDuplicatesSkipped: @productsCreateSkipped
      productsCreateProblemsIgnored: @productsCreateIgnored
      processingTimeInSec: (endTime - @startTime) / 1000
    @logger.info summary, "[Products]"

  _createProduct: (product) ->
    @client.products.create(product)
    .then =>
      @productsCreated = @productsCreated + 1
    .fail (error) =>
      if error.statusCode is 400 and @_options.continueOnProblems
        @productsCreateIgnored = @productsCreateIgnored + 1
        msg = "[Products] Product could not be created. Ignore and continue!; Reason:"
        @logger.warn error, msg
        Q.resolve msg
      else
        Q.reject error

  _logMissingAttributes: (attributes, productType) ->
    # group by objects name value
    groups = _.groupBy(attributes, 'name')
    _.each _.keys(groups), (attributeName) =>
      matchedAttr = _.find productType.attributes, (value) -> value.name is attributeName
      if not matchedAttr
        throw new Error "Product type with id: '#{productType.id}' does not define an attribute with name: '#{attributeName}'"
      # extract only keys from product type attribute values
      keys = _.pluck(matchedAttr.type.values, 'key')
      missing = []
      # find attribute keys not existing in product type
      _.each groups[attributeName], (val) ->
        if not _.contains(keys, val.key)
          exists = _.find missing, (m) -> m.key is val.key
          missing.push val if not exists

      if _.size(missing) > 0
        @logger.debug missing, "Detailed missing product type attribute values:"
        short = _.map missing, (m) -> _.pick(m, 'key', 'label')
        info =
          productTypeId: productType.id
          attributeName: attributeName
          missingValues: short
        @logger.warn info, "Missing product type attribute values:"

  _findAttributeByName: (product, name, failOnMiss = false) ->
    attr = _.find product.masterVariant.attributes, (a) -> a.name is name
    if not attr
      if failOnMiss
        throw new Error "Required attribute '#{name}' not defined for product: \n#{_u.prettify product}"
      else
        attr
    else
      attr

  _fetchProductByAttribute: (attribute) ->
    if attribute
      @client.productProjections.where("masterVariant(attributes(name=\"#{attribute.name}\" and value=\"#{attribute.value}\"))").staged().fetch()
    else
      Q(null)

  ###
  # Processes product XML data and builds a list of Sphere product representations.
  #
  # @param {Object} data Product XML data
  # @param {Object} productType Product type to use
  # @param {Array} fetchedCategories List of existing categories
  # @param {Object} mappings Product import attribute mappings
  # @return {Array} List of Sphere product representations
  ###
  buildProducts: (data, productType, fetchedCategories, mappings) =>
    productCreates = []
    productUpdates = []
    _.each data, (p) =>
      names = utils.getLocalizedValues(p.Descriptions?[0], 'Title')
      descriptions = utils.getLocalizedValues(p.Descriptions?[0], 'LongDescription')
      slugs = utils.generateLocalizedSlugs(names)

      # create product
      product =
        name: names
        slug: slugs
        productType:
          id: productType?.id
          typeId: 'product-type'
        description: descriptions
        variants: []

      # assign categories
      @_processCategories(product, p, fetchedCategories)

      variantBase =
        attributes: []
      # exclude product attributes which has to be handled differently
      simpleAttributes = _.omit(p, ['Attributes', 'Categories', 'Descriptions', 'Images', 'Variations', '$'])
      _.each simpleAttributes, (value, key) =>
        # in case any attribute form product is mapped to variant
        @_processValue(product, variantBase, key, value, mappings)

      # extract Attributes from product
      _.each p.Attributes, (item) =>
        @_processAttributes(item, product, variantBase, mappings)

      # add variants
      _.each p.Variations[0].Variation, (v, index, list) =>
        variant = @_buildVariant(v, product, variantBase, mappings)
        if index is 0
          product.masterVariant = variant
        else
          product.variants.push variant

      # this flag indicates if product is new or changed i.e.: attributes or description
      if p['$'].isNew is '1'
        productCreates.push product
      else
        productUpdates.push product

    # return products to create / update
    wrapper =
      creates: productCreates
      updates: productUpdates

  ###
  # Processes variant XML data and builds Sphere product variant representation.
  # Since some attributes (i.e: meta information) defined on variant only and has to be saved
  # on Sphere product (depending on configuration) we pass new product object for value processing here too.
  #
  # @param {Object} v Variant XML data
  # @param {Object} product New product object
  # @param {Object} variantBase Base attributes to use for new variant
  # @param {Object} mappings Product import attribute mappings
  # @return {Object} Sphere product variant representation
  ###
  _buildVariant: (v, product, variantBase, mappings) ->
    variant = JSON.parse(JSON.stringify(variantBase))

    # exclude special attributes, which has to be handled differently
    simpleAttributes = _.omit(v, ['Currencies', 'Descriptions', 'Options', 'Attributes', 'VariationImages', '$'])
    _.each simpleAttributes, (value, key) =>
      @_processValue(product, variant, key, value, mappings)

    # process variant 'Currencies'
    _.each v.Currencies?[0]?.Currency, (item) =>
      @_processCurrencies(item, product, variant, mappings)

    # process variant 'Options'
    _.each v.Options?[0]?.Option, (item) =>
      key = item['$'].id
      value = item.Translations[0].Translation[0].OptionValue
      @_processValue(product, variant, key, value, mappings)

    # process variant 'Attributes'
    _.each v.Attributes, (item) =>
      @_processAttributes(item, product, variant, mappings)

    # process variant 'VariationImages'
    _.each v.VariationImages?[0]?.VariationImage, (item) =>
      @_processImages(item, variant, mappings)

    variant

  ###
  # Adds / assigns category to product.
  #
  # @param {Object} product New product object to fill
  # @param {Object} data Data to extract category information from
  # @param {Array} fetchedCategories List of existing categories
  ###
  _processCategories: (product, data, fetchedCategories) ->
    catReferences = []
    _.each data.Categories?[0]?.Category, (c) ->
      categoryId = c.CategoryId[0]
      existingCategory = utils.getCategoryByExternalId(categoryId, fetchedCategories)
      id = existingCategory.id
      reference =
        typeId: "category"
        id: id
      catReferences.push reference

    if _.size(catReferences) > 0
      product.categories = catReferences

  ###
  # Adds / assigns images to product.
  #
  # @param {Object} item Item to get images from
  # @param {Object} variant Variant object to save images to
  # @param {Object} mappings Product import attribute mappings
  ###
  _processImages: (item, variant, mappings) ->
    productImportMappings = mappings.productImport.mapping
    _.each item, (value, key) ->
      if _.has(productImportMappings, key)
        mapping = productImportMappings[key]
        url = value[0]
        if not _s.startsWith(url, 'http') and mapping.specialMapping?.baseURL
          url = "#{mapping.specialMapping.baseURL}#{url}"
        image =
          url: url
          dimensions:
            w: 0
            h: 0

        if variant[mapping.to]
          variant[mapping.to].push image
        else
          variant[mapping.to] = [image]

  ###
  # Extracts price information from currency node and depending on mapping
  # configuration it saves it as variant price or custom attribute value.
  #
  # @param {Object} item Item to get currency prices from
  # @param {Object} product Product object to save processed values to
  # @param {Object} variant Variant object to save processed values to
  # @param {Object} mappings Product import attribute mappings
  ###
  _processCurrencies: (item, product, variant, mappings) ->
    productImportMappings = mappings.productImport.mapping
    _.each item, (value, key) =>
      if _.has(productImportMappings, key)
        mapping = productImportMappings[key]
        if mapping.type is 'special-price'
          price = {}
          currency = item['$'].currencyIso
          price.value =
            centAmount: @_getPriceAmount(value[0], mapping)
            currencyCode: currency
          country = mapping.specialMapping?.country
          customerGroup = mapping.specialMapping?.customerGroup
          channel = mapping.specialMapping?.channel
          if country
            price.country = mapping.specialMapping.country
          if customerGroup
            price.customerGroup =
              id: customerGroup
              typeId: 'customer-group'
          if channel
            price.channel =
              id: channel
              typeId: 'channel'

          if variant[mapping.to]
            variant[mapping.to].push price
          else
            variant[mapping.to] = [price]
        else
          @_addValue(product, variant, value, mapping, mappings)

  ###
  # Extracts attribute values and depending on mapping
  # configuration it saves it on variant or product object.
  #
  # @param {Object} item Item to get attributes from
  # @param {Object} product Product object to save processed values to
  # @param {Object} variant Variant object to save processed values to
  ###
  _processAttributes: (item, product, variant, mappings) ->
    if item.Boolean
      _.each item.Boolean, (el) =>
        key = @_getAttributeKey(el)
        @_processValue(product, variant, key, el.Value[0], mappings)
    if item.Integer
      _.each item.Integer, (el) =>
        key = @_getAttributeKey(el)
        @_processValue(product, variant, key, el.Value[0], mappings)
    if item.String
      _.each item.String, (el) =>
        key = @_getAttributeKey(el)
        value = utils.getLocalizedValues(el.Translations[0], 'Value')
        @_processValue(product, variant, key, value, mappings)

  ###
  # Returns attribute's key.
  #
  # @param {Object} item Item to get attribute key from
  # @return {String} key
  ###
  _getAttributeKey: (item) ->
    key = item['$']?.code
    if not key
      key = item.Translations[0].Translation[0].Name[0]
    key

  ###
  # Convert price into Sphere price amount.
  #
  # @param {String} value Price value
  # @param {Object} mapping Price mapping
  # @throws {Error} If price could not be converted
  # @return {Integer} Converted price
  ###
  _getPriceAmount: (value, mapping) ->
    number = _s.toNumber(value, 2)
    if value and not isNaN number
      number = _s.toNumber(number * 100, 0)
    else
      throw new Error "Could not convert value: '#{utils.pretty value}' to number; mapping: '#{utils.pretty mapping}'"
    number

  ###
  # Process passed value according to given mapping and adds / saves it to product or variant object.
  #
  # @param {Object} product Product object to save processed values to
  # @param {Object} variant Variant object to save processed values to
  # @param {Object} value Value to process
  # @param {Object} mapping mapping for the given value mapping
  # @param {Object} mappings Product import mappings
  # @throws {Error} If attribute type unknown or not supported yet
  ###
  _addValue: (product, variant, value, mapping, mappings) ->
    target = mapping.target
    type = mapping.type
    isCustom = mapping.isCustom
    key = mapping.to
    val

    switch type
      when 'text'
        val = @_transformValue(value[0], mapping, mappings)
      when 'ltext'
        # take value as it is as it should have proper form already
        val = value
      when 'enum', 'lenum'
        val = @_transformValue(value[0], mapping, mappings)
        if mapping.logoutMissing and isCustom
          attr =
            variantSKU: variant.sku
            name: key
            key: val
            label: value[0]
          @allEnumAttributes.push attr
      when 'number'
        val = _s.toNumber(value[0])
      when 'money'
        val = @_getPriceAmount(value[0], mapping)
        currency = if mapping.currency then mapping.currency else 'EUR'
        if val
          val =
            centAmount: val
            currencyCode: currency
      when 'special-tax'
        val = mapping.specialMapping[value[0]]
        if val
          val =
            id: val
            typeId: 'tax-category'
      else
        throw new Error "Unsupported attribute type: '#{type}' for value: '#{utils.pretty value}'; mapping: '#{utils.pretty mapping}'"

    if target is 'variant'
      if isCustom
        attribute =
          name: key
          value: val
        variant.attributes.push attribute
      else
        variant[key] = val
    else if target is 'product'
      product[key] = val

  ###
  # If mapping for given value key is defined, processes the value.
  #
  # @param {Object} product Product object to save processed values to
  # @param {Object} variant Variant object to save processed values to
  # @param {Object} key Mapping key
  # @param {Object} value Value to process
  # @param {Object} mappings Product import attribute mappings
  ###
  _processValue: (product, variant, key, value, mappings) =>
    productImportMappings = mappings.productImport.mapping
    if _.has(productImportMappings, key)
      @_addValue(product, variant, value, productImportMappings[key], mappings)

  ###
  # Transforms given value by transformer defined in the mapping.
  #
  # @param {Object} value Value to process
  # @param {Object} mapping Mapping for the given value
  # @param {Object} mappings Product import attribute mappings
  ###
  _transformValue: (value, mapping, mappings) ->
    valueTransformers = mappings.productImport.valueTransformers
    return value if not valueTransformers or not _.isString(value)

    newValue = value
    _.each mapping.transformers, (transformerName) ->
      transformer = valueTransformers[transformerName]
      switch transformer.type
        when 'regexp'
          find = new RegExp(transformer.find, 'g')
          replace = transformer.replace
          newValue = newValue.replace(find, replace)
        when 'upper'
          newValue = newValue.toUpperCase()
        when 'lower'
          newValue = newValue.toLowerCase()
        else
          throw new Error "Unsupported value transformer type: '#{transformer.type}' for value: '#{value}'; mapping: '#{_u.prettify mapping}'"

    newValue

module.exports = Products
