fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
xml2js = require 'xml2js'
ProductSync = require('sphere-node-sync').ProductSync

###
Creates new products in Sphere by given XML file.
###
class ProductImport

  constructor: (options = {}) ->
    @sourcePath = options.source
    #TODO do i need product type code as command parameter?
    console.log options.config
    @sync = new ProductSync options

  ###
  Reads given products XML file and creates new products in Sphere.
  @param {function} callback The callback function to be invoked when the method finished its work.
  @return Result of the given callback
  ###
  execute: (callback) ->
    console.log "ProductImport started..."
    @parse(@sourcePath)
    .then (result) =>
      @buildProducts(result)
    .then (result) =>
      _.each result, (product) =>
        @create(product)
    .then (result) ->
      # return success status
      callback true
    .fail (error) ->
      console.log error

  parse: (file) ->
    deferred = Q.defer()
    parser = new xml2js.Parser()
    fs.readFile file, 'utf8', (error, content) ->
      if error
        console.error "Can not read file '#{file}'; #{error}"
        deferred.reject 'Error on creating new product: ' + error
        process.exit 2
      parser.parseString content, (error, result) ->
        if error
          console.error "Can not parse XML '#{file}'; #{error}"
          process.exit 2
        productsCount =  Object.keys(result.Products).length
        console.log "Products to import: #{productsCount}"
        deferred.resolve result
    deferred.promise

  buildProducts: (data) ->
    deferred = Q.defer()
    products = []
    _.each data.Products, (p) ->
      product =
        productType: "dummyType" #TODO
        variants: []
      products.push product
      product = _.last products
      _.each p.Product, (v) ->
        variant =
          ProductId: v.ProductId
          Active: v.Active
        product.variants.push variant
    # return products list
    deferred.resolve products
    deferred.promise

  create: (product) ->
    deferred = Q.defer()
    @sync._rest.POST '/products', JSON.stringify(product), (error, response, body) =>
      if error
        deferred.reject 'Error on creating new product: ' + error
      else
        if response.statusCode is 201
          deferred.resolve 'New product created.'
        else if response.statusCode is 400
          deferred.reject "Error on creating new product, response.statusCode: 400:\n" + @prettyPrint JSON.parse body
        else
          deferred.reject 'Error on creating new product: ' + body
    deferred.promise

  prettyPrint: (data) ->
    console.log JSON.stringify data, null, 4

module.exports = ProductImport