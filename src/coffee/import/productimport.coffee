fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
utils = require '../../lib/utils'
{ProductSync} = require('sphere-node-sync')
{Rest} = require('sphere-node-connect')

###
Creates new products in Sphere by given XML file.
###
class ProductImport

  constructor: (@_options = {}) ->
    throw new Error 'XML source path is required' unless @_options.source
    @sync = new ProductSync @_options
    @rest = new Rest @_options
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
    console.log "ProductImport started..."

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

  _addTextValue: (key, value) ->
    attribute =
      name: key
      value: value[0]

  _addOptionValue: (key, value) ->
    val = value.Translations[0].Translation[0]["OptionValue"][0]
    attribute =
      name: key
      value: value.Translations[0].Translation[0]["OptionValue"][0]

  #TODO this method is a playground and will be refactored
  _addVariant: (p, v, product, typesMap) ->
    attributes = []

    # exclude attributes which has to be handled differently
    pOmitted = _.omit(p, ['Attributes', 'Categories', 'Descriptions', 'Images', 'Variations', '$'])
    _.each pOmitted, (value, key) =>
      #console.log key + " : " + value
      if _.has(typesMap, key)
        type = typesMap[key].type.name
        switch type
          when "text" then attributes.push(@_addTextValue(key, value))
          else
            new Error "Unsupported type #{type}"

    _.each v.Options?[0].Option, (value) =>
      key = value["$"].id
      if _.has(typesMap, key)
        type = typesMap[key].type.name
        switch type
          when "text" then attributes.push(@_addTextValue(key, value))
          when "enum" then attributes.push(@_addOptionValue(key, value))
          else
            new Error "Unsupported type #{type}"

        #console.log "attribute type: " + type
        #console.log key + " : " + value

    variant =
      sku: utils.xmlVal(v, "VariationId")
      attributes: attributes
    product.variants.push variant

  _createProduct: (product) =>
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
