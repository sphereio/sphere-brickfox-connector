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
    throw new Error 'Source path is required' unless @_options.source
    @sync = new ProductSync @_options
    @rest = new Rest @_options

  ###
  Reads given products XML file and creates new products in Sphere.
  @param {function} callback The callback function to be invoked when the method finished its work.
  @return Result of the given callback
  ###
  execute: (callback) ->
    console.log "ProductImport started..."

    @_readFile @_options.source
    .then (fileContent) =>
      Q.all [@_parseXml(fileContent), @_getProductTypes()]
    .spread (result, productTypes) =>
      console.log "Sphere product types: #{utils.pretty productTypes}"
      # TODO: match attributes
      console.log "Products found in XML: #{_.size(result.Products?.Product)}"
      products = @_buildProductsData(result)
      console.log "Create new product requests to send: #{_.size products}"
      @_batch _.map(products, (p) => @_createProduct p), callback, 100
    .fail (error) ->
      console.log "Error on execute method; #{error.stack}"
      callback false

  _readFile: (path) -> utils.readFile path

  _parseXml: (file) -> utils.parseXML file

  _getProductTypes: ->
    deferred = Q.defer()
    @rest.GET '/product-types', (error, response, body) ->
      if error
        deferred.reject error
      else
        deferred.resolve body
    deferred.promise

  _batch: (productList, callback, numberOfParallelRequest = 50) =>
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
      console.error error
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

  _createProduct: (product) ->
    deferred = Q.defer()
    @rest.POST '/products', product, (error, response, body) ->
      if error
        deferred.reject "Create product with id: #{product.ProductId} failed. Error: #{error}"
      else
        if response.statusCode isnt 201
          message = "Error on new product creation; Request: \n #{utils.pretty product} \n\n Response: " + utils.pretty body
          deferred.reject message
        else
          console.log "status OK"
          message = "Create new product with id: #{product.ProductId} succeeded."
          deferred.resolve message
    deferred.promise

module.exports = ProductImport
