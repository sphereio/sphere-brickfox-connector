fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
utils = require '../../lib/utils'
ProductSync = require('sphere-node-sync').ProductSync

###
Creates new products in Sphere by given XML file.
###
class ProductImport

  constructor: (@_options = {}) ->
    throw new Error 'Source path is required' unless @_options.source
    @sync = new ProductSync @_options

  ###
  Reads given products XML file and creates new products in Sphere.
  @param {function} callback The callback function to be invoked when the method finished its work.
  @return Result of the given callback
  ###
  execute: (callback) ->
    console.log "ProductImport started..."

    @_readFile @_options.source
    .then (result) =>
      Q.all [@_parseXml(result), @_getProductTypes()]
    .spread (result, productTypes) =>
      # TODO: match attributes
      products = @_buildProductsData(result)
      @_batch _.map(products, (p) => @_createProduct p), callback, 100
    .fail (error) ->
      console.log error.stack
      callback false

  _readFile: (path) -> utils.readFile path

  _parseXml: (file) -> utils.parseXML file

  _getProductTypes: ->
    deferred = Q.defer()
    @sync._rest.GET '/product-types', (e, r, b) ->
      console.log b
      if e
        deferred.reject e
      else
        deferred.resolve b
    deferred.promise

  _batch: (productList, callback, numberOfParallelRequest = 50) =>
    console.log productList
    current = _.take productList, numberOfParallelRequest
    Q.all(current)
    .then (result) =>
      # TODO: do something with result?
      if _.size(current) < numberOfParallelRequest
        callback true
      else
        @_batch _.tail(productList, numberOfParallelRequest), callback, numberOfParallelRequest
    .fail (error) ->
      console.log error.stack
      callback false

  _buildProductsData: (data) ->
    products = []
    _.each data.Products?.Product, (p) ->
      name = utils.xmlVal(p.Descriptions[0].Description[0], "Title")
      slug = utils.generateSlug(name)
      product =
        ProductId: utils.xmlVal(p, "ProductId")
        name:
          en: name
        slug:
          en: slug
        productType:
          id: "BrickfoxType"
          typeId: "product-type"
        variants: []
      products.push product
      product = _.last products
      _.each p.Variations[0].Variation, (v) ->
        variant =
          VariationId: utils.xmlVal(v, "VariationId")
          VariationItemNumber: utils.xmlVal(v, "VariationItemNumber")
          EAN: utils.xmlVal(v, "EAN")
          Available: utils.xmlVal(v, "Available")
        product.variants.push variant
    # console.log "Create new product JSON requests:\n #{utils.pretty(products)}"
    # return products list
    products

  _createProduct: (products) ->
    deferred = Q.defer()
    @sync._rest.POST '/products', JSON.stringify(product), (error, response, body) ->
      console.log "kuku"
      if error
        deferred.reject "Create product with id: #{product.ProductId} failed. Error: #{error}"
      else
        if !(response.statusCode is 201)
          message = "Error on creating new product, response.statusCode: #{response.statusCode}:\n" + utils.pretty(JSON.parse(body))
          console.error message
          deferred.reject message
        else
          message = "Create new product with id: #{product.ProductId} succeeded."
          console.log message
          deferred.resolve message
    deferred.promise

module.exports = ProductImport
