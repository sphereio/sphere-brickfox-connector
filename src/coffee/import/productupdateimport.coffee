fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
utils = require '../../lib/utils'
{InventorySync} = require('sphere-node-sync')
{Rest} = require('sphere-node-connect')
ProductImport = require("../import/productimport")

###
Imports Brickfox product stock and price updates into Sphere.
###
class ProductUpdateImport

  constructor: (@_options = {}) ->
    @inventorySync = new InventorySync @_options
    @rest = new Rest @_options
    @productImport = new ProductImport @_options
    @logger = @_options.appLogger

  ###
  # Reads given product import XML file and creates/updates/deletes product prices and stock / inventories
  # Detailed steps:
  # 1) Process import data
  #
  # 2) Fetch products to update
  #
  # 3) Build product update actions for prices
  # 3.1) Send product update actions for prices
  #
  # 4) Fetch inventories for variant to be updated
  #
  # 5) Build inventory creates
  # 5.1) Build inventory updates
  # 5.2) Send new inventory creates and updates
  #
  # @param {function} callback The callback function to be invoked when the method finished its work.
  # @return Result of the given callback
  ###
  execute: (callback) ->
    @startTime = new Date().getTime()
    @logger.info '[ProductsUpdate] ProductUpdateImport execution started.'

    Q.spread [
      @_loadMappings @_options.mapping
      @_loadProductsXML @_options.products
      ],
      (mappingsJson, productsXML) =>
        mappings = JSON.parse mappingsJson
        utils.assertProductIdMappingIsDefined mappings.product
        utils.assertVariationIdMappingIsDefined mappings.product
        utils.assertSkuMappingIsDefined mappings.product
        @toBeImported = _.size(productsXML.Products?.ProductUpdate)
        newProducts = @_processProductUpdatesData(productsXML, mappings.product)
        @productExternalIdMapping = mappings.product.ProductId.to
        productIds = @_getProductExternalIDs(newProducts, @productExternalIdMapping) if newProducts
        @newVariants = @_transformToVariantsBySku(newProducts)
        @logger.info "[ProductsUpdate] Product updates count: #{_.size productIds}"
        utils.batch(_.map(productIds, (id) => @_queryProductsByExternProductId(id, @productExternalIdMapping))) if productIds
    .then (fetchedProducts) =>
      @logger.info "[ProductsUpdate] Fetched products to update count: #{_.size fetchedProducts}"
      priceUpdates = @_buildPriceUpdates(fetchedProducts, @newVariants, @productExternalIdMapping) if fetchedProducts
      @logger.info "[ProductsUpdate] Product price updates count: #{_.size priceUpdates}"
      utils.batch(_.map(priceUpdates, (p) => @productImport.updateProduct p)) if priceUpdates
    .then (priceUpdatesResult) =>
      @priceUpdatedCount = _.size priceUpdatesResult
      skus = _.keys(@newVariants)
      @logger.info "[ProductsUpdate] Inventories to fetch: #{_.size skus}"
      utils.batch(_.map(skus, (sku) => @_queryInventoriesBySku sku)) if skus
    .then (fetchedInventories) =>
      @logger.info "[ProductsUpdate] Fetched inventories count: #{_.size fetchedInventories}"
      createInventoryForSkus = []
      updateInventoryItems = []
      _.each fetchedInventories, (i) -> if _.isObject(i) then updateInventoryItems.push(i) else createInventoryForSkus.push(i)
      inventoryCreates = @_buildInventoryCreates(createInventoryForSkus, @newVariants) if _.size(createInventoryForSkus) > 0
      inventoryUpdates = @_buildInventoryUpdates(updateInventoryItems, @newVariants) if _.size(updateInventoryItems) > 0
      promises = []
      promises.push utils.batch(_.map(inventoryUpdates, (inventory) => @_updateInventory(inventory.newObj, inventory.oldObj))) if inventoryUpdates
      promises.push utils.batch(_.map(inventoryCreates, (inventory) => @_createInventory inventory)) if inventoryCreates
      promises
    .spread (updateInventoryResult, createInventoryResult) =>
      @inventoriesCreated = _.size(createInventoryResult)
      @inventoriesUpdated = _.size(_.filter updateInventoryResult, (r) -> r is 200)
      @_processResult(callback, true)
    .fail (error) =>
      @logger.error "Error on execute method; #{error}"
      @logger.error "Error stack: #{error.stack}" if error.stack
      @_processResult(callback, false)

  _processResult: (callback, isSuccess) ->
    endTime = new Date().getTime()
    result = if isSuccess then 'SUCCESS' else 'ERROR'
    @logger.info """[ProductsUpdate] ProductUpdateImport finished with result: #{result}.
                    [ProductsUpdate] Price updated for #{@priceUpdatedCount} out of #{@toBeImported} products.
                    [ProductsUpdate] Inventories created: '#{@inventoriesCreated}'
                    [ProductsUpdate] Inventories updated: '#{@inventoriesUpdated}'
                    [ProductsUpdate] Processing time: #{(endTime - @startTime) / 1000} seconds."""
    callback isSuccess

  _loadMappings: (path) ->
    utils.readFile(path)

  _loadProductsXML: (path) ->
    utils.xmlToJson(path)

  _processProductUpdatesData: (data, mappings) =>
    extendedMappings = _.extend _.clone(mappings),
      # extend mapping to ensure that stock information will be processed and included into variant information too
      Stock:
        target: "variant"
        type: "text"
        to: "tempstock"
    products = @productImport.buildProducts(data.Products?.ProductUpdate, null, null, extendedMappings)

    if(_.size products) > 0
      products
    else
      null

  _transformToVariantsBySku: (products) ->
    map = {}
    _.each products, (p) =>
      @_addUniqueMapEntry(map, p.masterVariant.sku, p.masterVariant)
      _.each p.variants, (v) =>
        @_addUniqueMapEntry(map, v.sku, v)
    map

  _addUniqueMapEntry: (map, id, object) ->
    if _.has(map, id)
      throw new Error "Error on map creation. Map already contains an entry with unique id: '#{id}'. Existing value: \n #{map[id]} \n\n New value: #{object}"
    else
      map[id] = object

  _getProductExternalIDs: (products, productExternalIdMapping) ->
    productIDs = []
    _.each products, (p) ->
      _.each p.masterVariant.attributes, (att) ->
        if att.name is productExternalIdMapping
          productIDs.push att.value
    productIDs

  ###
  # Queries asynchronously for products with given Brickfox product reference id.
  #
  # @param {String} id External product id attribute value
  # @param {String} productExternalIdMapping External product id attribute name
  # @return {Object} If success returns promise with response body otherwise rejects with error message
  ###
  _queryProductsByExternProductId: (id, productExternalIdMapping) ->
    deferred = Q.defer()
    predicate = "masterVariant(attributes(name=\"#{productExternalIdMapping}\" and value=#{id}))"
    query = "/product-projections?where=#{encodeURIComponent(predicate)}&staged=true"
    @rest.GET query, (error, response, body) ->
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
  _queryInventoriesBySku: (sku) ->
    deferred = Q.defer()
    predicate = "sku=#{sku}"
    query = "/inventory?where=#{encodeURIComponent(predicate)}"
    @rest.GET query, (error, response, body) ->
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
  _createInventory: (payload) ->
    deferred = Q.defer()
    @rest.POST '/inventory', payload, (error, response, body) ->
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
  _updateInventory: (new_obj, old_obj) ->
    deferred = Q.defer()
    @inventorySync.buildActions(new_obj, old_obj).update (error, response, body) ->
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


  _buildPriceUpdates: (oldProducts, newVariants, productExternalIdMapping) ->
    updates = []
    _.each oldProducts, (p) ->
      actions = []
      results = _.size(p.body.results)
      externId = p[productExternalIdMapping]

      if results > 1
        throw new Error "Make sure '#{productExternalIdMapping}' product type attribute is unique accross all products in SPHERE. #{results} products with same value: '#{externId}' found."

      product = p.body.results[0]

      variantId = product.masterVariant.id
      _.each product.masterVariant.prices, (price) ->
        # remove old price for master variant
        action = utils.buildRemovePriceAction(price, variantId)
        actions.push action
        # create new price for master variant
        newVariant = newVariants[product.masterVariant.sku]
        _.each newVariant.prices, (newPrice) ->
          action = utils.buildAddPriceAction(newPrice, variantId)
          actions.push action

      _.each product.variants, (v) ->
        variantId = v.id
        _.each v.prices, (price) ->
          # remove old price for variant
          action = utils.buildRemovePriceAction(price, variantId)
          actions.push action
          # create new price for variant
          newVariant = newVariants[v.sku]
          _.each newVariant.prices, (newPrice) ->
            action = utils.buildAddPriceAction(newPrice, variantId)
            actions.push action

      # this will sort the actions ranked in asc order (first 'remove' then 'add')
      actions = _.sortBy actions, (a) -> a.action is 'addPrice'

      wrapper =
        id: product.id
        payload:
          version: product.version
          actions: actions
      updates.push wrapper
    updates

  _buildInventoryCreates: (skus, newVariants) ->
    creates = []
    _.each skus, (sku) ->
      variant = newVariants[sku]
      stock = variant.tempstock
      inventory =
        sku: sku
        quantityOnStock: parseInt(stock, 10)
      creates.push inventory

    count = _.size(creates)
    if count > 0
      creates
    else
      null

  _buildInventoryUpdates: (oldInventories, newVariants) ->
    updates = []
    _.each oldInventories, (old) ->
      variant = newVariants[old.sku]
      stock = variant.tempstock
      pair =
        newObj:
          quantityOnStock: parseInt(stock, 10)
        oldObj: old

      updates.push pair

    count = _.size(updates)
    if count > 0
      updates
    else
      null

module.exports = ProductUpdateImport
