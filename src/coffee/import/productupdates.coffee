Q = require 'q'
_ = require 'lodash-node'
_s = require 'underscore.string'
{InventorySync} = require 'sphere-node-sync'
SphereClient = require 'sphere-node-client'
{Rest} = require 'sphere-node-connect'
{_u} = require 'sphere-node-utils'
api = require '../../lib/sphere'
utils = require '../../lib/utils'
Products = require '../import/products'

###
Imports Brickfox product stock and price updates into Sphere.
###
class ProductUpdates

  constructor: (@_options = {}) ->
    @inventorySync = new InventorySync @_options
    @rest = new Rest @_options
    @client = new SphereClient @_options
    @client.setMaxParallel(100)
    @productsImport = new Products @_options
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
    @logger.info "[ProductsUpdate] Product updates: #{_.size productIds}"
    utils.batch(_.map(productIds, (id) => api.queryProductsByExternProductId(@rest, id, @productExternalIdMapping)))
    .then (fetchedProducts) =>
      priceUpdates = @_buildPriceUpdates(fetchedProducts, @newVariants, @productExternalIdMapping) if fetchedProducts
      @logger.info "[ProductsUpdate] Product price updates: #{_.size priceUpdates}"
      Q.all(_.map(priceUpdates, (p) => @client.products.byId(p.id).update(p.payload))) if priceUpdates
    .then (priceUpdatesResult) =>
      @priceUpdatedCount = _.size(priceUpdatesResult)
      skus = _.keys(@newVariants)
      @logger.info "[ProductsUpdate] Inventories to fetch: #{_.size skus}"
      @createInventoryForSkus = []
      @updateInventoryItems = []
      if _.size(skus) > 0
        Q.all _.map skus, (sku) =>
          @client.inventoryEntries.where("sku=#{sku}").all().fetch()
          .then (fetchedInventoryResult) =>
            inventory = fetchedInventoryResult.body.results[0]
            if inventory
              @updateInventoryItems.push(inventory)
            else
              @createInventoryForSkus.push(sku)
    .then (fetchedInventories) =>
      inventoryUpdates = @_buildInventoryUpdates(@updateInventoryItems, @newVariants) if _.size(@updateInventoryItems) > 0
      if inventoryUpdates
        @logger.info "[ProductsUpdate] Inventories to update: #{_.size inventoryUpdates}"
        Q.all(_.map(inventoryUpdates, (i) => @inventorySync.buildActions(i.newObj, i.oldObj).update()))
    .then (updateInventoryResult) =>
      @inventoriesUpdated = _.size(_.filter updateInventoryResult, (r) -> r.statusCode is 200)
      @inventoriesUpdateSkipped = _.size(updateInventoryResult) - @inventoriesUpdated
      inventoryCreates = @_buildInventoryCreates(@createInventoryForSkus, @newVariants) if _.size(@createInventoryForSkus) > 0
      if inventoryCreates
        @logger.info "[ProductsUpdate] Inventories to create: #{_.size inventoryCreates}"
        Q.all(_.map(inventoryCreates, (i) => @client.inventoryEntries.save(i))) if inventoryCreates
    .then (createInventoryResult) =>
      @inventoriesCreated = _.size(createInventoryResult)
      @success = true

  outputSummary: ->
    endTime = new Date().getTime()
    result = if @success then 'SUCCESS' else 'ERROR'
    @logger.info """[ProductsUpdate] Import result: #{result}.
                    [ProductsUpdate] Price updated for #{@priceUpdatedCount} out of #{@toBeImported} products.
                    [ProductsUpdate] Inventories created: #{@inventoriesCreated}
                    [ProductsUpdate] Inventories updated: #{@inventoriesUpdated}
                    [ProductsUpdate] Inventories update skipped: #{@inventoriesUpdateSkipped}
                    [ProductsUpdate] Processing time: #{(endTime - @startTime) / 1000} seconds."""

  _processProductUpdatesData: (data, mappings) =>
    extendedMappings = _.extend _.clone(mappings),
      # extend mapping to ensure that stock information will be processed and included into variant information too
      Stock:
        target: "variant"
        type: "text"
        to: "tempstock"
    result = @productsImport.buildProducts(data.Products?.ProductUpdate, null, null, extendedMappings)

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

  _buildPriceUpdates: (oldProducts, newVariants, productExternalIdMapping) =>
    updates = []
    _.each oldProducts, (p) =>
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
      variantId = product.masterVariant.id

      if _.size(product.masterVariant.prices) > 0
        _.each product.masterVariant.prices, (price) =>
          # remove old price for master variant
          actions.push utils.buildRemovePriceAction(price, variantId)
          # create new price for master variant
          actions = actions.concat @_buildAddPriceActions(variantId, newVariants, productExternalIdMapping, externId, product.masterVariant.sku)
      else
        # no old prices found
        actions = actions.concat @_buildAddPriceActions(variantId, newVariants, productExternalIdMapping, externId, product.masterVariant.sku)

      _.each product.variants, (v) =>
        variantId = v.id
        if _.size(product.masterVariant.prices) > 0
          _.each v.prices, (price) =>
            # remove old price for variant
            actions.push utils.buildRemovePriceAction(price, variantId)
            # create new price for variant
            actions = actions.concat @_buildAddPriceActions(variantId, newVariants, productExternalIdMapping, externId, v.sku)
        else
          # no old prices found
          actions = actions.concat @_buildAddPriceActions(variantId, newVariants, productExternalIdMapping, externId, v.sku)

      # this will sort the actions ranked in asc order (first 'remove' then 'add')
      actions = _.sortBy actions, (a) -> a.action is 'addPrice'

      wrapper =
        id: product.id
        payload:
          version: product.version
          actions: actions

      updates.push wrapper
    updates

  _buildAddPriceActions: (variantId, newVariants, productExternalIdMapping, externId, sku) ->
    actions = []
    newVariant = newVariants[sku]
    throw new Error "Import data does not define price for existing product with '#{productExternalIdMapping}' = '#{externId}' and SKU = '#{sku}'" if not newVariant
    _.each newVariant.prices, (newPrice) ->
      actions.push utils.buildAddPriceAction(newPrice, variantId)

    actions

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

module.exports = ProductUpdates
