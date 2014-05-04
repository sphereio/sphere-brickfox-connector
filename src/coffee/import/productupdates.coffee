Q = require 'q'
_ = require 'lodash-node'
_s = require 'underscore.string'
{ProductSync, InventorySync} = require 'sphere-node-sync'
SphereClient = require 'sphere-node-client'
{_u} = require 'sphere-node-utils'
api = require '../../lib/sphere'
utils = require '../../lib/utils'
Products = require '../import/products'

###
Imports Brickfox product stock and price updates into Sphere.
###
class ProductUpdates

  constructor: (@_options = {}) ->
    @productSync = new ProductSync @_options
    @inventorySync = new InventorySync @_options
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
    @newProducts = @_processProductUpdatesData(productsXML, mappings.productImport.mapping)
    @productExternalIdMapping = mappings.productImport.mapping.ProductId.to
    productIds = @_getProductExternalIDs(@newProducts, @productExternalIdMapping) if @newProducts
    @newVariants = @_transformToVariantsBySku(@newProducts)
    @logger.info "[ProductsUpdate] Product updates: #{_.size productIds}"
    Q.all(_.map(productIds, (id) => @client.productProjections.where("masterVariant(attributes(name=\"#{@productExternalIdMapping}\" and value=#{id}))").staged().fetch()))
    .then (fetchedProducts) =>
      priceUpdates = @_buildPriceUpdates(fetchedProducts, @newProducts, @productExternalIdMapping)
      @priceUpdatedCount = _.size(priceUpdates)
      @logger.info "[ProductsUpdate] Product price updates: #{@priceUpdatedCount}"
      Q.all(_.map(priceUpdates, (p) => @client.products.byId(p.id).update(p.payload))) if _.size(priceUpdates) > 0
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
                    [ProductsUpdate] Products(s) processed: #{@toBeImported}
                    [ProductsUpdate] Price(s) updated: #{@priceUpdatedCount}
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
      productId = null
      att = _.find p.masterVariant.attributes, (a) -> a.name is productExternalIdMapping
      if att
        productIDs.push att.value
      else
        throw new Error "Product price/stock update data does not contain required attribute: 'productExternalIdMapping'; Product update data: \n #{p}"
    productIDs

  _validateProductExists: (oldProduct, newProduct, productExternalIdMapping) ->
    if not oldProduct
      att = _.find newProduct.masterVariant.attributes, (a) -> a.name is productExternalIdMapping
      throw new Error "Products to update not found in SPHERE.IO by attribute name: '#{productExternalIdMapping}' and value: '#{att.value}'"

  _buildPriceUpdates: (oldProducts, newProducts, productExternalIdMapping) =>
    updates = []
    # we are interested in price changes only
    options = [{type: 'prices', group: 'white'}]

    _.each oldProducts, (val, index, list) =>
      oldProduct = val?.body?.results[0]
      newProduct = newProducts[index]
      @_validateProductExists(oldProduct, newProduct, productExternalIdMapping)
      update = @productSync.config(options).buildActions(newProduct, oldProduct).get()
      if update
        wrapper =
          id: oldProduct.id
          payload: update

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

module.exports = ProductUpdates
