Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
{InventorySync} = require 'sphere-node-sync'
{Rest} = require 'sphere-node-connect'
{_u} = require 'sphere-node-utils'
api = require '../../lib/sphere'
utils = require '../../lib/utils'
ProductImport = require '../import/productimport'

###
Imports Brickfox product stock and price updates into Sphere.
###
class ProductUpdateImport

  constructor: (@_options = {}) ->
    @inventorySync = new InventorySync @_options
    @rest = new Rest @_options
    @productImport = new ProductImport @_options
    @logger = @_options.appLogger
    @toBeImported = 0
    @priceUpdatedCount = 0
    @inventoriesCreated = 0
    @inventoriesUpdated = 0
    @success = false

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
  ###
  execute: (productsXML, mappings) ->
    @startTime = new Date().getTime()
    utils.assertProductIdMappingIsDefined mappings.productImport.mapping
    utils.assertVariationIdMappingIsDefined mappings.productImport.mapping
    utils.assertSkuMappingIsDefined mappings.productImport.mapping
    @toBeImported = _.size(productsXML.Products?.ProductUpdate)
    newProducts = @_processProductUpdatesData(productsXML, mappings.productImport.mapping)
    @productExternalIdMapping = mappings.productImport.mapping.ProductId.to
    productIds = @_getProductExternalIDs(newProducts, @productExternalIdMapping) if newProducts
    @newVariants = @_transformToVariantsBySku(newProducts)
    @logger.info "[ProductsUpdate] Product updates count: #{_.size productIds}"
    utils.batch(_.map(productIds, (id) => api.queryProductsByExternProductId(@rest, id, @productExternalIdMapping)))
    .then (fetchedProducts) =>
      priceUpdates = @_buildPriceUpdates(fetchedProducts, @newVariants, @productExternalIdMapping) if fetchedProducts
      @logger.info "[ProductsUpdate] Product price updates count: #{_.size priceUpdates}"
      utils.batch(_.map(priceUpdates, (p) => api.updateProduct(@rest, p))) if priceUpdates
    .then (priceUpdatesResult) =>
      @priceUpdatedCount = _.size(priceUpdatesResult)
      skus = _.keys(@newVariants)
      @logger.info "[ProductsUpdate] Inventories to fetch: #{_.size skus}"
      utils.batch(_.map(skus, (sku) => api.queryInventoriesBySku(@rest, sku))) if skus
    .then (fetchedInventories) =>
      @logger.info "[ProductsUpdate] Fetched inventories count: #{_.size fetchedInventories}"
      createInventoryForSkus = []
      updateInventoryItems = []
      _.each fetchedInventories, (i) -> if _.isObject(i) then updateInventoryItems.push(i) else createInventoryForSkus.push(i)
      inventoryCreates = @_buildInventoryCreates(createInventoryForSkus, @newVariants) if _.size(createInventoryForSkus) > 0
      inventoryUpdates = @_buildInventoryUpdates(updateInventoryItems, @newVariants) if _.size(updateInventoryItems) > 0
      promises = []
      promises.push utils.batch(_.map(inventoryUpdates, (inventory) => api.updateInventory(@inventorySync, inventory.newObj, inventory.oldObj))) if inventoryUpdates
      promises.push utils.batch(_.map(inventoryCreates, (inventory) => api.createInventory(@rest, inventory))) if inventoryCreates
      promises
    .spread (updateInventoryResult, createInventoryResult) =>
      @inventoriesCreated = _.size(createInventoryResult)
      # filter out responses where inventory was not updated (i.e.: value did not change)
      @inventoriesUpdated = _.size(_.filter updateInventoryResult, (r) -> r is 200)
      @success = true

  outputSummary: ->
    endTime = new Date().getTime()
    result = if @success then 'SUCCESS' else 'ERROR'
    @logger.info """[ProductsUpdate] Import result: #{result}.
                    [ProductsUpdate] Price updated for #{@priceUpdatedCount} out of #{@toBeImported} products.
                    [ProductsUpdate] Inventories created: #{@inventoriesCreated}
                    [ProductsUpdate] Inventories updated: #{@inventoriesUpdated}
                    [ProductsUpdate] Processing time: #{(endTime - @startTime) / 1000} seconds."""

  _processProductUpdatesData: (data, mappings) =>
    extendedMappings = _.extend _.clone(mappings),
      # extend mapping to ensure that stock information will be processed and included into variant information too
      Stock:
        target: "variant"
        type: "text"
        to: "tempstock"
    result = @productImport.buildProducts(data.Products?.ProductUpdate, null, null, extendedMappings)

    if(_.size result.updates) > 0
      result.updates
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
      throw new Error "Error on map creation. Map already contains an entry with unique id: '#{id}'. Existing value: \n #{_u.prettify(map[id])} \n\n New value: #{_u.prettify(object)}"
    else
      map[id] = object

  _getProductExternalIDs: (products, productExternalIdMapping) ->
    productIDs = []
    _.each products, (p) ->
      _.each p.masterVariant.attributes, (att) ->
        if att.name is productExternalIdMapping
          productIDs.push att.value
    productIDs

  _buildPriceUpdates: (oldProducts, newVariants, productExternalIdMapping) ->
    updates = []
    _.each oldProducts, (p) ->
      actions = []
      results = _.size(p.body.results)
      externId = p[productExternalIdMapping]

      if results is 0
        missing =
          _.chain(oldProducts)
          .filter((p) -> _.size(p.body.results) is 0)
          .map((p) -> p[productExternalIdMapping]).value()
        throw new Error "#{_.size missing} products to update not found in SPHERE.IO by attribute '#{productExternalIdMapping}' with values: #{_u.prettify missing}"

      if results > 1
        throw new Error "Make sure '#{productExternalIdMapping}' product type attribute is unique accross all products in SPHERE. #{results} products with same value: '#{externId}' found."

      product = p.body.results[0]
      console.log 'kuku: ' + _u.prettify oldProducts
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
