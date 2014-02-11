fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
utils = require '../lib/utils'
xml2js = require 'xml2js'
ProductSync = require('sphere-node-sync').ProductSync

###
Creates new products in Sphere by given XML file.
###
class ProductImport

  constructor: (options = {}) ->
    @sourcePath = options.source
    @sync = new ProductSync options

  ###
  Reads given products XML file and creates new products in Sphere.
  @param {function} callback The callback function to be invoked when the method finished its work.
  @return Result of the given callback
  ###
  execute: (callback) ->
    console.log "ProductImport started..."

    utils.readFile @sourcePath
    .then (result) ->
      utils.parseXML result
    .then (result) =>
      console.log "Products to import: #{_.size result.Products}"
      @buildProductsData result
    .then (result) =>
      _.each result, (product) =>
        @create product
    .then (result) ->
      # return success status
      callback true
    .fail (error) ->
      console.log error

  buildProductsData: (data) ->
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
    console.log "Create new product JSON requests:\n #{utils.pretty(products)}"
    # return products list
    products

  create: (product) ->
    deferred = Q.defer()
    @sync._rest.POST '/products', JSON.stringify(product), (error, response, body) ->
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