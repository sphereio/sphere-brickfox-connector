fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
utils = require '../../lib/utils'
{ProductSync} = require('sphere-node-sync')
{Rest} = require('sphere-node-connect')
{Logger} = require('sphere-node-connect')


###
Creates new products in Sphere by given XML file.
###
class ProductImport

  constructor: (@_options = {}) ->
    throw new Error 'XML source path is required' unless @_options.source
    @sync = new ProductSync @_options
    @rest = new Rest @_options
    @logger = @rest.logger
    @mapping
    @successCounter = 0
    @failCounter = 0
    @toBeImported = 0

  ###
  Reads given products XML file and creates new products in Sphere.
  @param {function} callback The callback function to be invoked when the method finished its work.
  @return Result of the given callback
  ###
  execute: (callback) ->
    @logger.info "ProductImport started..."

    @_readFile @_options.source
    .then (fileContent) =>
      Q.all [@_parseXml(fileContent), @_getProductTypes(), @_loadOptionalResource(@_options.mapping)]
    .spread (productData, productTypes, mapping) =>
      if mapping
        @mapping = JSON.parse mapping
      #console.log utils.pretty @mapping
      #console.log "Sphere product types: #{utils.pretty productTypes}"
      #console.log utils.pretty(productData)
      #console.log "Products found in XML: #{_.size(productData.Products?.Product)}"
      @toBeImported = _.size(productData.Products?.Product)
      productType = @_getProductType productTypes
      products = @_buildProductsData(productData, productType)
      console.log "Create new product requests to send: #{_.size products}"
      @_batch _.map(products, (p) => @_createProduct p), callback, 100
    .fail (error) ->
      console.log "Error on execute method; #{error.stack}"
      callback false

  _readFile: (path) -> utils.readFile path

  _parseXml: (file) -> utils.parseXML file

  _loadOptionalResource: (path) =>
    if path
      @_readFile path
    else
      Q.fcall (val) ->
        null


  _getProductTypes: ->
    deferred = Q.defer()
    @rest.GET '/product-types', (error, response, body) ->
      if error
        deferred.reject error
      else
        deferred.resolve body
    deferred.promise

  _batch: (productList, callback, numberOfParallelRequest) =>
    current = _.take productList, numberOfParallelRequest
    Q.all(current)
    .then (result) =>
      # TODO: do something with result?
      if _.size(current) < numberOfParallelRequest
        callback true
      else
        @_batch _.tail(productList, numberOfParallelRequest), callback, numberOfParallelRequest
    .fail (error) ->
      console.error "Error on create new product batch processing."
      if error.stack
        console.log "Error stack: #{error.stack}"
      console.error error
      callback false


  _getLocDescription: (descriptionsNode, attribName) ->
    desc = {}
    _.each descriptionsNode, (descriptions) ->
      _.each descriptions, (val, index, list) ->
        #console.log "Index: " + utils.pretty list
        #console.log "Test-Desc1: "+utils.pretty list[index]
        lang = list[index]["$"].lang
        value = utils.xmlVal(list[index], attribName)
        desc[lang] = value
    #console.log "Test-Descriptions: "+utils.pretty desc
    desc

  _getLocSlugs: (names) ->
    slugs = {}
    _.each names, (value, key, list) ->
      slug = utils.generateSlug(value)
      slugs[key] = slug
    #console.log "Test-Slugs: "+utils.pretty slugs
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


  _buildProductsData: (data, productType) =>
    console.log utils.pretty productType
    typesMap = {}
    _.each productType.attributes, (att) ->
      typesMap[att.name] = att

    products = []
    _.each data.Products?.Product, (p) =>
      names = @_getLocDescription(p.Descriptions[0], "Title")
      descriptions = @_getLocDescription(p.Descriptions[0], "LongDescription")
      slugs = @_getLocSlugs(names)

      # create product
      product =
        name: names
        slug: slugs
        productType:
          id: productType.id
          typeId: "product-type"
        description: descriptions
        variants: []

      # add variants
      _.each p.Variations[0].Variation, (v) =>
        @_addVariant(p, v, product, typesMap)
    # console.log "Create new product JSON requests:\n #{utils.pretty(products)}"
      products.push product
    # return products list
    products

  _addValue: (variant, key, value, type, isCustomAttr) ->
    console.log "Attribute type '#{type}'; isCustomAttr: #{isCustomAttr}, key: '#{key}', value '#{value[0]}'"
    attribute
    val

    switch type
      when "text"
        val = value[0]
        attribute =
          name: key
          value: val
      when "enum"
        val = _s.slugify value[0]
        attribute =
          name: key
          value: val
      else
        new Error "Unsupported attribute type '#{type}'; isCustomAttr: #{isCustomAttr}, key: '#{key}', value '#{utils.pretty value}'"

    if isCustomAttr
      variant.attributes.push attribute
    else
      variant[key] = val

  _addValues: (typesMap, variant, key, value) =>
    if _.has(typesMap, key)
      type = typesMap[key].type.name
      @_addValue(variant, key, value, type, false)
    else if @mapping and _.has(@mapping, key)
      type = @mapping[key].type
      isCustomAttr = @mapping[key].isCustom
      keyMapping = @mapping[key].to
      @_addValue(variant, keyMapping, value, type, isCustomAttr)

  _addVariant: (p, v, product, typesMap) ->
    variant =
      attributes: []

    # exclude product attributes which has to be handled differently
    simpleAttributes = _.omit(p, ['Attributes', 'Categories', 'Descriptions', 'Images', 'Variations', '$'])
    _.each simpleAttributes, (value, key) =>
      @_addValues(typesMap, variant, key, value)

    # extract Options from variant
    _.each v.Options?[0].Option, (value) =>
      key = value["$"].id
      val = value.Translations[0].Translation[0]["OptionValue"]
      @_addValues(typesMap, variant, key, val)

    product.variants.push variant

  _createProduct: (product) =>
    console.log utils.pretty product
    deferred = Q.defer()
    @rest.POST '/products', product, (error, response, body) =>
      if error
        @failCounter++
        deferred.reject "Create product with id: #{product.ProductId} failed. Error: #{error}"
      else
        if response.statusCode isnt 201
          @failCounter++
          message = "Error on new product creation; Request: \n #{utils.pretty product} \n\n Response: " + utils.pretty body
          deferred.reject message
        else
          @successCounter++
          message = "Create new product with id: #{product.ProductId} succeeded."
          deferred.resolve message
    deferred.promise

module.exports = ProductImport
