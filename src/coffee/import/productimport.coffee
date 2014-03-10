fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
utils = require '../../lib/utils'
{ProductSync} = require('sphere-node-sync')
{Rest} = require('sphere-node-connect')

###
Imports Brickfox products provided as XML into Sphere.
###
# TODO: split up product from category and manufacturers logic
class ProductImport

  constructor: (@_options = {}) ->
    throw new Error 'XML source path is required' unless @_options.products
    throw new Error 'Product import attributes mapping (Brickfox -> SPHERE) file path is required' unless @_options.mapping
    @sync = new ProductSync @_options
    @rest = new Rest @_options
    @logger = @_options.appLogger
    @successCounter = 0
    @failCounter = 0
    @success = false

  ###
  # Reads given import XML files and creates/updates product types, categories and products in Sphere (product types and categories has to be imported first)
  # Detailed steps:
  # 1) Fetch product type, categories and load import XML files
  #
  # 2) Build product type updates (creates missing manufacturers)
  # 2.1) Send product type updates
  #
  # 3) Build category creates (new categories only)
  # 3.1) Send category creates
  #
  # 4) Fetch categories (get fresh list after category creates)
  #
  # 5) Build category updates (updates for existing/old categories plus sets parent child relations on all categories)
  # 5.1) Send category updates
  #
  # 6) Build product creates
  # 6.1) Send product creates
  #
  # 7) TODO: Build product updates
  # 7.1) TODO: Send product updates
  #
  # 8) TODO: Build category deletes
  # 8.1) TODO: Send category deletes
  #
  # @param {function} callback The callback function to be invoked when the method finished its work.
  # @return Result of the given callback
  ###
  execute: (callback) ->
    @startTime = new Date().getTime()
    @logger.info 'ProductImport execution started.'

    Q.spread [
      @_loadMapping @_options.mapping
      @_loadProductsXML @_options.products
      @_loadManufacturersXML @_options.manufacturers
      @_loadCategoriesXML @_options.categories
      @_fetchProductTypes()
      @_fetchCategories()
      ],
      (mapping, productsXML, manufacturersXML, categoriesXML, fetchedProductTypes, fetchedCategories) =>
        @logger.debug "mapping:\n#{mapping}"
        @logger.debug "productsXML:\n#{utils.pretty productsXML}"
        @logger.debug "fetchedProductTypes:\n#{utils.pretty fetchedProductTypes}"
        @mapping = JSON.parse mapping
        @productsXML = productsXML
        @categoriesXML = categoriesXML
        @fetchedCategories = @_transformByCategoryExternalId fetchedCategories.results
        @toBeImported = _.size(productsXML.Products?.Product)
        @productType = @_getProductType(fetchedProductTypes, @_options)
        manufacturers = @_buildManufacturers(manufacturersXML, @productType) if manufacturersXML
        @_updateProductType(@productType.id, manufacturers) if manufacturers
    .then (productTypeUpdateResult) =>
      @logger.info '[Categories] Categories XML import started...'
      @logger.info "[Categories] Fetched categories count before create: '#{_.size @fetchedCategories}'"
      @categories = @_buildCategories(@categoriesXML) if @categoriesXML
      @categoryCreates = @_buildCategoryCreates(@categories, @fetchedCategories) if @categories
      @_batch(_.map(@categoryCreates, (c) => @_createCategory c), 100) if @categoryCreates
    .then (createCategoriesResult) =>
      # fetch created categories to get id's used for parent reference creation. Required only if new categories created.
      @_fetchCategories() if @categoryCreates
    .then (fetchedCategories) =>
      @fetchedCategories = @_transformByCategoryExternalId fetchedCategories.results if fetchedCategories
      @logger.info "[Categories] Fetched count after create: '#{_.size @fetchedCategories}'" if fetchedCategories
      categoryUpdates = @_buildCategoryUpdates(@categories, @fetchedCategories) if @categories
      @_batch(_.map(categoryUpdates, (c) => @_updateCategory c), 100) if categoryUpdates
    .then (updateCategoriesResult) =>
      @logger.info '[Products] Products XML import started...'
      @logger.info "[Products] Import products found: '#{_.size @productsXML.Products?.Product}'"
      products = @_buildProducts(@productsXML, @productType, @fetchedCategories)
      @logger.info "[Products] Create count: '#{_.size products}'"
      @_batch(_.map(products, (p) => @_createProduct p), 100) if products
    .fail (error) =>
      @logger.error "Error on execute method; #{error}"
      @logger.error "Error stack: #{error.stack}" if error.stack
      @_processResult(callback)
    .done (result) =>
      @success = true
      @_processResult(callback)

  _processResult: (callback) ->
    endTime = new Date().getTime()
    result = if @success then 'SUCCESS' else 'ERROR'
    @logger.info """ProductImport finished with result: #{result}.
                    #{@successCounter} product(s) out of #{@toBeImported} imported. #{@failCounter} failed.
                    Processing time: #{(endTime - @startTime) / 1000} seconds."""
    callback @success

  _loadMapping: (path) ->
    utils.readFile(path)

  _loadProductsXML: (path) ->
    utils.xmlToJson(path)

  _loadManufacturersXML: (path) ->
    utils.xmlToJson(path) if path

  _loadCategoriesXML: (path) ->
    utils.xmlToJson(path) if path

  ###
  # If manufacturers mapping is defined builds an array of update actions for mapped product type attribute
  #
  # @param {Object} data Data to get manufacturers information from
  # @param {Object} productType Product type with existing manufacturer values
  # @return {Array} List of product type update actions
  ###
  _buildManufacturers: (data, productType) ->
    @logger.info '[Manufacturers] Manufacturers XML import started...'
    @logger.debug "[Manufacturers] data:\n#{utils.pretty data}"

    if not @mapping.ManufacturerId
      @logger.info '[Manufacturers] Mapping for ManufacturerId is not defined. No manufacturers will be created.'
      return

    count = _.size(data.Manufacturers?.Manufacturer)
    if count
      @logger.info "[Manufacturers] Import manufacturers found: '#{count}'"
    else
      @logger.info '[Manufacturers] No manufacturers to import found or undefined. Please check manufacturers input XML.'
      return

    attributeName = @mapping.ManufacturerId.to
    # find attribute on product type
    matchedAttr = _.find productType.attributes, (value) -> value.name is attributeName
    if not matchedAttr
      throw new Error "Error on manufacturers import. ManufacturerId mapping attributeName: '#{attributeName}' could not be found on product type with id: '#{productType.id}'"

    actions = []
    # extract only keys from product type attribute values
    keys = _.pluck(matchedAttr.type.values, 'key')
    _.each data.Manufacturers.Manufacturer, (m) =>
      key = m.ManufacturerId[0]
      exists = _.contains(keys,  key)
      if not exists
        # attribute value does not exist yet -> create new addLocalizedEnumValue action
        value = @_getLocalizedValues(m.Translations[0], 'Name')
        action =
          action: 'addLocalizedEnumValue'
          attributeName: attributeName
          value:
            key: key
            label: value
        actions.push action

    if _.size(actions) > 0
      @logger.info "[Manufacturers] Update actions to send for attribute '#{attributeName}': '#{_.size actions}'"
      payload =
        version: productType.version
        actions: actions
    else
      @logger.info "[Manufacturers] No update action for manufacturers attribute '#{attributeName}' required."

  ###
  # Builds categories list from import data with all attributes (name, slug, parent <-> child relation) required for category creation or update.
  #
  # @param {Object} data Data to get categories information from
  # @return {Array} List of categories
  ###
  _buildCategories: (data) ->
    @logger.debug "[Categories] data:\n#{utils.pretty data}"
    count = _.size(data.Categories?.Category)
    if count
      @logger.info "[Categories] Import categories found: '#{count}'"
    else
      @logger.info '[Categories] No categories to import found or undefined. Please check categories input XML.'
      return
    categories = []
    _.each data.Categories.Category, (c) =>
      category = @_convertCategory(c)
      categories.push category
    @logger.info "[Categories] Import candidates count: '#{_.size categories}'"
    @logger.debug "[Categories] Import candidates data: '#{utils.pretty categories}'"
    categories

  ###
  # Builds list of category create object representations.
  #
  # @param {Array} data List of category candidates to import
  # @param {Array} fetchedCategories List of existing categories
  # @return {Array} List of category create representations
  ###
  _buildCategoryCreates: (data, fetchedCategories) =>
    creates = []
    _.each data, (c) ->
      exists = _.has(fetchedCategories, c.id)
      # we are interested in new categories only
      if not exists
        name = c.name
        slug = c.slug
        # set category external id (over slug as workaround)
        # TODO: do not use slug as external category id (required Sphere support of custom attributes on category first)
        slug.nl = c.id
        create =
          name: name
          slug: slug
        creates.push create

    count = _.size(creates)
    if count > 0
      @logger.info "[Categories] Create count: '#{count}'"
      creates
    else
      @logger.info "[Categories] No category create required."
      null

  ###
  # Builds list of category update object representations.
  #
  # @param {Array} data List of category candidates to update
  # @param {Array} fetchedCategories List of existing categories
  # @return {Array} List of category update representations
  ###
  _buildCategoryUpdates: (data, fetchedCategories) ->
    updates = []
    _.each data, (c) =>
      actions = []
      newName = c.name
      oldCategory = @_getCategoryByExternalId(c.id, fetchedCategories)
      oldName = oldCategory.name

      # check if category name changed
      if not _.isEqual(newName, oldName)
        action =
          action: "changeName"
          name: newName
        actions.push action

      parentId = c.parentId
      parentCategory = @_getCategoryByExternalId(parentId, fetchedCategories) if parentId
      # check if category need to be assigned to parent
      if parentCategory
        action =
          action: "changeParent"
          parent:
            typeId: "category"
            id: parentCategory.id
        actions.push action

      if _.size(actions) > 0
        wrapper =
          id: oldCategory.id
          actions:
            version: oldCategory.version
            actions: actions
        updates.push wrapper

    count = _.size(updates)
    if count > 0
      @logger.info "[Categories] Update count: '#{count}'"
      updates
    else
      @logger.info "[Categories] No category update required."
      null

  ###
  # Transforms a list of existing categories into a new object (map alike) using external category id as abject property name (key).
  #
  # @param {Array} fetchedCategories List of existing categories
  # @throws {Error} If category external id is not defined
  # @return {Array} List of of transformed categories
  ###
  _transformByCategoryExternalId: (fetchedCategories) ->
    map = {}
    _.each fetchedCategories, (el) ->
      # TODO: do not use slug as external category id (required Sphere support of custom attributes on category first)
      externalId = el.slug.nl
      throw new Error "[Categories] Slug for language 'nl' (workaround: used as 'externalId') in MC is empty; Category id: '#{el.id}'" if not externalId
      map[externalId] = el
    map

  ###
  # Returns category object with given external/Brickfox id. If category with requested external id was not found
  # an error is thrown as this id is used as common identifier for synchronization between Brickfox and Sphere categories.
  #
  # @param {Array} fetchedCategories List of existing categories
  # @throws {Error} If category external id is not defined
  # @return {Array} List of of transformed categories
  ###
  _getCategoryByExternalId: (id, fetchedCategories) ->
    category = fetchedCategories[id]
    throw new Error "Unexpected error. Category with externalId: '#{id}' not found." if not category
    category

  ###
  # Converts XML category data into Sphere category representation.
  #
  # @param {Object} categoryItem Category data
  # @return {Object} Sphere category representation
  ###
  _convertCategory: (categoryItem) ->
    names = @_getLocalizedValues(categoryItem.Translations[0], 'Name')
    slugs = @_getLocalizedSlugs(names)
    category =
      id: categoryItem.CategoryId[0]
      name: names
      slug: slugs
    category.parentId = categoryItem.ParentId if categoryItem.ParentId
    category

  ###
  # Retrieves asynchronously all categories from Sphere.
  #
  # @return {Object} If success returns promise with response body otherwise rejects with error message
  ###
  _fetchCategories: ->
    deferred = Q.defer()
    @rest.GET '/categories', (error, response, body) ->
      if error
        deferred.reject error
      else
        deferred.resolve body
    deferred.promise

  ###
  # Creates asynchronously category in Sphere.
  #
  # @param {Object} payload Create category request as JSON
  # @return {Object} If success returns promise with success message otherwise rejects with error message
  ###
  _createCategory: (payload) ->
    deferred = Q.defer()
    @rest.POST '/categories', payload, (error, response, body) ->
      if error
        deferred.reject "HTTP error on new category creation; Error: #{error}; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
      else
        if response.statusCode isnt 201
          message = "Error on new category creation; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
          deferred.reject message
        else
          message = 'New category created.'
          deferred.resolve message
    deferred.promise

  ###
  # Updates asynchronously category in Sphere.
  #
  # @param {Object} payload Update category request as JSON
  # @return {Object} If success returns promise with success message otherwise rejects with error message
  ###
  _updateCategory: (payload) ->
    deferred = Q.defer()
    @rest.POST "/categories/#{payload.id}", payload.actions, (error, response, body) ->
      if error
        deferred.reject "HTTP error on category update; Error: #{error}; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
      else
        if response.statusCode isnt 200
          message = "Error on category type update; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
          deferred.reject message
        else
          message = 'Category type updated.'
          deferred.resolve message
    deferred.promise

  ###
  # Retrieves asynchronously all product types from Sphere.
  #
  # @return {Object} If success returns promise with response body otherwise rejects with error message
  ###
  _fetchProductTypes: ->
    deferred = Q.defer()
    @rest.GET '/product-types', (error, response, body) ->
      if error
        deferred.reject error
      else
        deferred.resolve body
    deferred.promise

  ###
  # Updates asynchronously product type in Sphere.
  #
  # @param {String} id Product type id
  # @param {Object} payload Update product type request as JSON
  # @return {Object} If success returns promise with success message otherwise rejects with error message
  ###
  _updateProductType: (id, payload) =>
    deferred = Q.defer()
    @rest.POST "/product-types/#{id}", payload, (error, response, body) ->
      if error
        deferred.reject "HTTP error on product type update; Error: #{error}; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
      else
        if response.statusCode isnt 200
          message = "Error on product type update; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
          deferred.reject message
        else
          message = 'Product type updated.'
          deferred.resolve message
    deferred.promise

  ###
  # Creates asynchronously product in Sphere.
  #
  # @param {Object} payload Create product request as JSON
  # @return {Object} If success returns promise with success message otherwise rejects with error message
  ###
  _createProduct: (payload) =>
    deferred = Q.defer()
    @rest.POST '/products', payload, (error, response, body) =>
      if error
        @failCounter++
        deferred.reject "HTTP error on new product creation; Error: #{error}; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
      else
        if response.statusCode isnt 201
          @failCounter++
          message = "Error on new product creation; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
          deferred.reject message
        else
          @successCounter++
          message = 'New product created.'
          deferred.resolve message
    deferred.promise

  ###
  # Executes in parallel defined number of asynchronous promise requests.
  #
  # @param {Array} list List of promise requests to fire
  # @param {Array} numberOfParallelRequest Number of requests to be fired in parallel
  # @return {Boolean} Returns true if all promises could be successfully resolved
  ###
  _batch: (list, numberOfParallelRequest) ->
    deferred = Q.defer()
    doBatch = (list, numberOfParallelRequest) ->
      current = _.take list, numberOfParallelRequest
      Q.all(current)
      .then (result) ->
        if _.size(current) < numberOfParallelRequest
          deferred.resolve true
        else
          doBatch _.tail(list, numberOfParallelRequest), numberOfParallelRequest
      .fail (error) ->
        deferred.reject error
     doBatch(list, numberOfParallelRequest)
     deferred.promise

  ###
  # Processes product XML data and builds a list of Sphere product representations.
  #
  # @param {Object} data Product XML data
  # @param {Object} productType Product type to use
  # @param {Array} fetchedCategories List of existing categories
  # @return {Array} List of Sphere product representations
  ###
  _buildProducts: (data, productType, fetchedCategories) =>
    products = []
    _.each data.Products?.Product, (p) =>
      names = @_getLocalizedValues(p.Descriptions[0], 'Title')
      descriptions = @_getLocalizedValues(p.Descriptions[0], 'LongDescription')
      slugs = @_getLocalizedSlugs(names)

      # create product
      product =
        name: names
        slug: slugs
        productType:
          id: productType.id
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
        @_processValue(product, variantBase, key, value)

      # extract Attributes from product
      _.each p.Attributes, (item) =>
        @_processAttributes(item, product, variantBase)

      # add variants
      _.each p.Variations[0].Variation, (v, index, list) =>
        variant = @_buildVariant(v, product, variantBase)
        if index is 0
          product.masterVariant = variant
        else
          product.variants.push variant

      products.push product
    # return products list
    products

  ###
  # Processes variant XML data and builds Sphere product variant representation.
  # Since some attributes (i.e: meta information) defined on variant only and has to be saved
  # on Sphere product (depending on configuration) we pass new product object for value processing here too.
  #
  # @param {Object} v Variant XML data
  # @param {Object} product New product object
  # @param {Object} variantBase Base attributes to use for new variant
  # @return {Object} Sphere product variant representation
  ###
  _buildVariant: (v, product, variantBase) ->
    variant = JSON.parse(JSON.stringify(variantBase))

    # exclude special attributes, which has to be handled differently
    simpleAttributes = _.omit(v, ['Currencies', 'Descriptions', 'Options', 'Attributes', 'VariationImages', '$'])
    _.each simpleAttributes, (value, key) =>
      @_processValue(product, variant, key, value)

    # process variant 'Currencies'
    _.each v.Currencies[0]?.Currency, (item) =>
      @_processCurrencies(item, product, variant)

    # process variant 'Options'
    _.each v.Options[0]?.Option, (item) =>
      key = item['$'].id
      value = item.Translations[0].Translation[0].OptionValue
      @_processValue(product, variant, key, value)

    # process variant 'Attributes'
    _.each v.Attributes, (item) =>
      @_processAttributes(item, product, variant)

    # process variant 'VariationImages'
    _.each v.VariationImages[0]?.VariationImage, (item) =>
      @_processImages(item, variant)

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
    _.each data.Categories[0]?.Category, (c) =>
      categoryId = c.CategoryId[0]
      existingCategory = @_getCategoryByExternalId(categoryId, fetchedCategories)
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
  ###
  _processImages: (item, variant) ->
    _.each item, (value, key) =>
      if _.has(@mapping, key)
        mapping = @mapping[key]
        url = value[0]
        if not _s.startsWith(url, 'http')
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
  ###
  _processCurrencies: (item, product, variant) ->
    _.each item, (value, key) =>
      if _.has(@mapping, key)
        mapping = @mapping[key]
        if mapping.type is 'special-price'
          price = {}
          currency = item['$'].currencyIso
          price.value =
            centAmount: @_getPriceAmount(value[0], mapping)
            currencyCode: currency
          country = mapping.specialMapping.country
          customerGroup = mapping.specialMapping.customerGroup
          channel = mapping.specialMapping.channel
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
          @_addValue(product, variant, value, mapping)

  ###
  # Extracts attribute values and depending on mapping
  # configuration it saves it on variant or product object.
  #
  # @param {Object} item Item to get attributes from
  # @param {Object} product Product object to save processed values to
  # @param {Object} variant Variant object to save processed values to
  ###
  _processAttributes: (item, product, variant) ->
    if item.Boolean
      _.each item.Boolean, (el) =>
        key = @_getAttributeKey(el)
        @_processValue(product, variant, key, el.Value[0])
    if item.Integer
      _.each item.Integer, (el) =>
        key = @_getAttributeKey(el)
        @_processValue(product, variant, key, el.Value[0])
    if item.String
      _.each item.String, (el) =>
        key = @_getAttributeKey(el)
        value = @_getLocalizedValues(el.Translations[0], 'Value')
        @_processValue(product, variant, key, value)

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
  # Returns localized values for all detected languages.
  #
  # @param {Object} mainNode Main XML node to get Localizations from
  # @param {String} name Element name to localize
  # @return {Object} Localized values
  ###
  _getLocalizedValues: (mainNode, name) ->
    localized = {}
    _.each mainNode, (item) ->
      _.each item, (val, index, list) ->
        lang = list[index]['$'].lang
        value = utils.xmlVal(list[index], name)
        localized[lang] = value
    localized

  ###
  # Returns slugified values for given localized parameter values.
  #
  # @param {Object} mainNode Main XML node to get Localizations from
  # @return {Object} Localized slugs
  ###
  _getLocalizedSlugs: (names) ->
    slugs = {}
    _.each names, (value, key, list) ->
      slug = utils.generateSlug(value)
      slugs[key] = slug
    slugs

  ###
  # Returns product type. If 'productTypeId' command line parameter has been used,
  # product type with given id is returned otherwise first element from the product
  # type list is returned.
  #
  # @param {Object} fetchedProductTypes Product types object
  # @param {Object} options Command line options
  # @throws {Error} If no product types were found
  # @throws {Error} If product type for given product type id was not found
  # @return {Object} Product type
  ###
  _getProductType: (fetchedProductTypes, options) ->
    productTypes = fetchedProductTypes.results
    if _.size(productTypes) == 0
      throw new Error "No product type defined for SPHERE project '#{options.config.project_key}'. Please create one before running product import."

    productType = null
    if options.productTypeId
      productType = _.find productTypes, (type) ->
        type.id is options.productTypeId
      if not productType
        throw new Error "SPHERE project '#{options.config.project_key}' does not contain product type with id: '#{options.productTypeId}'"
    else
      # take first available product type from the list
      productType = productTypes[0]
    productType

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
  # @param {Object} mapping Product import mapping
  # @throws {Error} If attribute type unknown or not supported yet
  ###
  _addValue: (product, variant, value, mapping) ->
    target = mapping.target
    type = mapping.type
    isCustom = mapping.isCustom
    key = mapping.to
    val

    switch type
      when 'text'
        val = value[0]
      when 'ltext'
        # take value as it is as it should have proper form already
        val = value
      when 'enum', 'lenum'
        val = _s.slugify value[0]
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
  ###
  _processValue: (product, variant, key, value) =>
    if _.has(@mapping, key)
      @_addValue(product, variant, value, @mapping[key])

module.exports = ProductImport
