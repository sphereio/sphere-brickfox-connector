fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
utils = require '../../lib/utils'
{ProductSync} = require('sphere-node-sync')
{Rest} = require('sphere-node-connect')


#TODO: add code documentation

###
Creates new products in Sphere by given XML file.
###
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
  Reads given products XML file and creates new products in Sphere.
  @param {function} callback The callback function to be invoked when the method finished its work.
  @return Result of the given callback
  ###
  execute: (callback) ->
    @startTime = new Date().getTime()
    @logger.info 'ProductImport started...'

    Q.spread [
      @_loadMapping @_options.mapping
      @_loadProductsXML @_options.products
      @_loadManufacturersXML @_options.manufacturers
      @_loadCategoriesXML @_options.categories
      @_fetchProductTypes()
      ],
      (mappingData, productsData, manufacturersData, categoriesData, productTypesData) =>
        @logger.debug "mappingData:\n#{mappingData}"
        @logger.debug "productsData:\n#{utils.pretty productsData}"
        @logger.debug "productTypesData:\n#{utils.pretty productTypesData}"
        @mapping = JSON.parse mappingData
        @toBeImported = _.size(productsData.Products?.Product)
        productType = @_getProductType productTypesData
        manufacturers = @_processManufacturers(manufacturersData, productType) if manufacturersData
        @_updateProductType(productType, manufacturers) if manufacturers
        @_updateCategories categoriesData if categoriesData
        products = @_buildProductsData(productsData, productType)
        @logger.info "[Products] About to create '#{_.size products}' products."
        @_batch _.map(products, (p) => @_createProduct p), 100
    .fail (error) =>
      @logger.error "Error on execute method; #{error}"
      @logger.error "Error stack: #{error.stack}" if error.stack
      @_processResult(callback)
    .done (result) =>
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

  _processManufacturers: (manufacturersData, productType) ->
    @logger.info '[Manufacturers] Update manufacturers started...'
    @logger.debug "[Manufacturers] manufacturersData:\n#{utils.pretty manufacturersData}"

    if not @mapping.productMapping.ManufacturerId
      @logger.info '[Manufacturers] Mmapping for ManufacturerId is not defined. No manufacturers will be created.'
      return

    count = manufacturersData.Manufacturers?['$'].count
    if count
      @logger.info "[Manufacturers] Manufacturers found: '#{count}'"
    else
      @logger.info '[Manufacturers] No manufacturers found or undefined. Please check manufacturers input XML.'
      return

    attributeName = @mapping.productMapping.ManufacturerId.to
    matchedAttr = _.find productType.attributes, (value) -> value.name is attributeName
    if not matchedAttr
      throw new Error "Error on manufacturers import. ManufacturerId mapping attributeName: '#{attributeName}' could not be found on product type with id: '#{productType.id}'"

    actions = []
    keys = _.pluck(matchedAttr.type.values, 'key')
    _.each manufacturersData.Manufacturers.Manufacturer, (m) =>
      key = m.ManufacturerId[0]
      exists = _.contains(keys,  key)
      if not exists
        # create new addLocalizedEnumValue action
        value = @_getLocalizedValue(m.Translations[0], 'Name')
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
      @logger.info "[Manufacturers] No update action for attribute '#{attributeName}' required.'#{_.size actions}'"

  _updateCategories: (categoriesData) ->
    @logger.info '[Categories] Update categories started...'
    @logger.debug "[Categories] categoriesData:\n#{utils.pretty categoriesData}"

  _fetchProductTypes: ->
    deferred = Q.defer()
    @rest.GET '/product-types', (error, response, body) ->
      if error
        deferred.reject error
      else
        deferred.resolve body
    deferred.promise

  _updateProductType: (productType, payload) =>
    deferred = Q.defer()
    @rest.POST "/product-types/#{productType.id}", payload, (error, response, body) ->
      if error
        deferred.reject "HTTP error on product type update; Error: #{error}; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
      else
        if response.statusCode isnt 201
          message = "Error on product type update; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
          deferred.reject message
        else
          message = 'Product type updated.'
          deferred.resolve message
    deferred.promise

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

  _batch: (list, numberOfParallelRequest) =>
    current = _.take list, numberOfParallelRequest
    Q.all(current)
    .then (result) =>
      if _.size(current) < numberOfParallelRequest
        @success = true
      else
        @_batch _.tail(list, numberOfParallelRequest), numberOfParallelRequest
    .fail (error) =>
      @logger.error "Error batch processing; #{error}"
      @logger.error "Error stack: #{error.stack}" if error.stack
      @success = false

  _buildProductsData: (data, productType) =>
    products = []
    _.each data.Products?.Product, (p) =>
      names = @_getLocalizedValue(p.Descriptions[0], 'Title')
      descriptions = @_getLocalizedValue(p.Descriptions[0], 'LongDescription')
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

      variantBase =
        attributes: []
      # exclude product attributes which has to be handled differently
      simpleAttributes = _.omit(p, ['Attributes', 'Categories', 'Descriptions', 'Images', 'Variations', '$'])
      _.each simpleAttributes, (value, key) =>
        @_processValue(product, variantBase, key, value)

      # extract Attributes from variant
      _.each p.Attributes, (item) =>
        @_processAttributes(item, product, variantBase)

      # add variants
      _.each p.Variations[0].Variation, (v, index, list) =>
        variant = @_createVariant(v, product, variantBase)
        if index is 0
          product.masterVariant = variant
        else
          product.variants.push variant

      products.push product
    # return products list
    products

  _createVariant: (v, product, variantBase) ->
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
      @_processImages(item, product, variant)

    variant

  _processImages: (item, product, variant) ->
    _.each item, (value, key) =>
      if _.has(@mapping.productMapping, key)
        mapping = @mapping.productMapping[key]
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

  _processCurrencies: (item, product, variant) ->
    _.each item, (value, key) =>
      if _.has(@mapping.productMapping, key)
        mapping = @mapping.productMapping[key]
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
        value = @_getLocalizedValue(el.Translations[0], 'Value')
        @_processValue(product, variant, key, value)

  _getAttributeKey: (item) ->
    key = item['$']?.code
    if not key
      key = item.Translations[0].Translation[0].Name[0]
    key

  _getLocalizedValue: (mainNode, attribName) ->
    localized = {}
    _.each mainNode, (item) ->
      _.each item, (val, index, list) ->
        lang = list[index]['$'].lang
        value = utils.xmlVal(list[index], attribName)
        localized[lang] = value
    localized

  _getLocalizedSlugs: (names) ->
    slugs = {}
    _.each names, (value, key, list) ->
      slug = utils.generateSlug(value)
      slugs[key] = slug
    slugs

  _getProductType: (productTypesObj) ->
    productTypes = productTypesObj.results
    if _.size(productTypes) == 0
      throw new Error "No product type defined for SPHERE project '#{@_options.config.project_key}'. Please create one before running product import."

    productType = null
    if @_options.productTypeId
      productType = _.find productTypes, (type) =>
        type.id is @_options.productTypeId
      if not productType
        throw new Error "SPHERE project '#{@_options.config.project_key}' does not contain product type with id: '#{@_options.productTypeId}'"
    else
      # take first available product type from the list
      productType = productTypes[0]
    productType

  _getPriceAmount: (value, mapping) ->
    number = _s.toNumber(value, 2)
    if value and not isNaN number
      number = _s.toNumber(number * 100, 0)
    else
      throw new Error "Could not convert value: '#{utils.pretty value}' to number; mapping: '#{utils.pretty mapping}'"
    number

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

  _processValue: (product, variant, key, value) =>
    if _.has(@mapping.productMapping, key)
      @_addValue(product, variant, value, @mapping.productMapping[key])

module.exports = ProductImport
