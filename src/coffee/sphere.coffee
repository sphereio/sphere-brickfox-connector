Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'

###
# Retrieves asynchronously all categories from Sphere.
#
# @return {Object} If success returns promise with response body otherwise rejects with error message
###
exports.fetchCategories = (rest) ->
  deferred = Q.defer()
  rest.GET '/categories', (error, response, body) ->
    if error
      deferred.reject error
    else
      if response.statusCode isnt 200
        message = "Error on fetch categories; \n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        deferred.resolve body
  deferred.promise

###
# Creates asynchronously category in Sphere.
#
# @param {Object} payload Create category request as JSON
# @return {Object} If success returns promise with success message otherwise rejects with error message
###
exports.createCategory = (rest, payload) ->
  deferred = Q.defer()
  rest.POST '/categories', payload, (error, response, body) ->
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
# @param {Object} data Update category request data
# @return {Object} If success returns promise with success message otherwise rejects with error message
###
exports.updateCategory = (rest, data) ->
  deferred = Q.defer()
  rest.POST "/categories/#{data.id}", data.payload, (error, response, body) ->
    if error
      deferred.reject "HTTP error on category update; Error: #{error}; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
    else
      if response.statusCode isnt 200
        message = "Error on category update; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        message = "Category with id: '#{data.id}' updated."
        deferred.resolve message
  deferred.promise

###
# Retrieves asynchronously all product types from Sphere.
#
# @return {Object} If success returns promise with response body otherwise rejects with error message
###
exports.fetchProductTypes = (rest) ->
  deferred = Q.defer()
  rest.GET '/product-types', (error, response, body) ->
    if error
      deferred.reject error
    else
      if response.statusCode isnt 200
        message = "Error on fetch product-types; \n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        deferred.resolve body
  deferred.promise

###
# Updates asynchronously product type in Sphere.
#
# @param {Object} data Update product type data
# @return {Object} If success returns promise with success message otherwise rejects with error message
###
exports.updateProductType = (rest, data) ->
  deferred = Q.defer()
  rest.POST "/product-types/#{data.id}", data.payload, (error, response, body) ->
    if error
      deferred.reject "HTTP error on product type update; Error: #{error}; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
    else
      if response.statusCode isnt 200
        message = "Error on product type update; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        message = "Product type with id: '#{data.id}' updated."
        deferred.resolve message
  deferred.promise

###
# Creates asynchronously product in Sphere.
#
# @param {Object} payload Create product request as JSON
# @return {Object} If success returns promise with success message otherwise rejects with error message
###
exports.createProduct = (rest, payload) ->
  deferred = Q.defer()
  rest.POST '/products', payload, (error, response, body) ->
    if error
      deferred.reject "HTTP error on new product creation; Error: #{error}; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
    else
      if response.statusCode isnt 201
        message = "Error on new product creation; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        message = 'New product created.'
        deferred.resolve message
  deferred.promise

###
# Updates asynchronously product in Sphere.
#
# @param {Object} data Update product request data
# @return {Object} If success returns promise with success message otherwise rejects with error message
###
exports.updateProduct = (rest, data) ->
  deferred = Q.defer()
  rest.POST "/products/#{data.id}", data.payload, (error, response, body) ->
    if error
      deferred.reject "HTTP error on product update; Error: #{error}; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
    else
      if response.statusCode isnt 200
        message = "Error on product update; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        message = "Product with id: '#{data.id}' updated."
        deferred.resolve message
  deferred.promise

###
# Queries asynchronously for products with given Brickfox product reference id.
#
# @param {String} id External product id attribute value
# @param {String} productExternalIdMapping External product id attribute name
# @return {Object} If success returns promise with response body otherwise rejects with error message
###
exports.queryProductsByExternProductId = (rest, id, productExternalIdMapping) ->
  deferred = Q.defer()
  predicate = "masterVariant(attributes(name=\"#{productExternalIdMapping}\" and value=#{id}))"
  query = "/product-projections?where=#{encodeURIComponent(predicate)}&staged=true"
  rest.GET query, (error, response, body) ->
    if error
      deferred.reject error
    else
      if response.statusCode isnt 200
        message = "Error on query products by extern ProductId; \n Predicate: #{predicate} \n\n GET query: \n #{query} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        customResponse = {}
        customResponse[productExternalIdMapping] = id
        customResponse.body = body
        deferred.resolve customResponse
  deferred.promise

###
# Queries inventories by SKU.
#
# @param {String} sku SKU value
# @return {Object} If success returns promise with response body otherwise rejects with error message
###
exports.queryInventoriesBySku = (rest, sku) ->
  deferred = Q.defer()
  predicate = "sku=#{sku}"
  query = "/inventory?where=#{encodeURIComponent(predicate)}"
  rest.GET query, (error, response, body) ->
    if error
      deferred.reject error
    else
      if response.statusCode isnt 200
        message = "Error on query inventories by sku; \n Predicate: #{predicate} \n\n GET query: \n #{query} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        if body.results[0]
          deferred.resolve body.results[0]
        else
          deferred.resolve sku
  deferred.promise

###
# Creates asynchronously inventory in Sphere.
#
# @param {Object} payload Create inventory request as JSON
# @return {Object} If success returns promise with success message otherwise rejects with error message
###
exports.createInventory = (rest, payload) ->
  deferred = Q.defer()
  rest.POST '/inventory', payload, (error, response, body) ->
    if error
      deferred.reject "HTTP error on new inventory creation; Error: #{error}; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
    else
      if response.statusCode isnt 201
        message = "Error on new inventory creation; Request body: \n #{utils.pretty payload} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        message = 'New inventory created.'
        deferred.resolve message
  deferred.promise

###
# Updates asynchronously inventory in Sphere.
#
# @param {Object} payload
# @return {Object} If success returns promise with success message otherwise rejects with error message
###
exports.updateInventory = (sync, new_obj, old_obj) ->
  deferred = Q.defer()
  sync.buildActions(new_obj, old_obj).update (error, response, body) ->
    if error
      deferred.reject "HTTP error on inventory update; Error: #{error}; \nNew object: \n#{utils.pretty new_obj} \nOld object: \n#{utils.pretty old_obj} \n\nResponse body: '#{utils.pretty body}'"
    else
      if response.statusCode is 200
        deferred.resolve 200
      else if response.statusCode is 304
        # Inventory entry update not neccessary
        deferred.resolve 304
      else
        message = "Error on inventory update; New object: \n#{utils.pretty new_obj} \nOld object: \n#{utils.pretty old_obj} \n\nResponse body: '#{utils.pretty body}'"
        deferred.reject message
  deferred.promise

exports.queryOrders = (rest, query) ->
  deferred = Q.defer()
  query = encodeURIComponent query
  rest.GET "/orders?limit=0&where=#{query}", (error, response, body) ->
    if error
      deferred.reject "Error on querying orders: " + error
    else if response.statusCode isnt 200
      deferred.reject "Problem on querying orders (status: #{response.statusCode}): " + body
    else
      deferred.resolve body.results
  deferred.promise

exports.updateOrder = (rest, id, data) ->
  deferred = Q.defer()
  rest.POST "/orders/#{id}", data, (error, response, body) ->
    if error
      deferred.reject "HTTP error on order update; Error: #{error}; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
    else
      if response.statusCode isnt 200
        message = "Error on order update (status: #{response.statusCode}); Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        message = "Order with id: '#{id}' updated."
        deferred.resolve message
  deferred.promise