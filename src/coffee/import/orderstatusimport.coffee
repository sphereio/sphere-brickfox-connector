Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
{Rest} = require('sphere-node-connect')
api = require '../sphere'
utils = require '../utils'

# TODO: work in progress / refactor

###
Imports Brickfox order status updates into SPHERE.IO.
###
class OrderStatusImport

  constructor: (@_options = {}) ->
    @rest = new Rest @_options
    @logger = @_options.appLogger

  ###
  # Reads given order status import XML file and creates deliveries, parcels and sets line item status
  # Detailed steps:
  # 1) Load order status import data
  #
  # 2) Fetch orders for which status will be changed
  #
  # 3) Build deliveries
  # 3.1) Send deliveries
  #
  # 4) Build parcels
  # 4.1) Send parcels
  #
  # 5) Build line item status changes
  # 5.1) Send line item status changes
  #
  # @param {function} callback The callback function to be invoked when the method finished its work.
  # @return Result of the given callback
  ###
  execute: (callback) ->
    @startTime = new Date().getTime()
    @logger.info '[OrderStatus] OrderStatusImport execution started.'
    @stateDefs = [
      {key: "Initial", transitions: ["A"]}
      {key: "A", transitions: ["B"]}
      {key: "B", transitions: ["C", "D"]}
      {key: "C", transitions: ["D"]}
      {key: "D", transitions: ["E"]}
      {key: "E", transitions: ["A"]}
    ]

    Q.spread [
      @_loadMappings @_options.mapping
      @_loadOrderStatusXML @_options.status
      ],
      (mappingsJson, statusXML) =>
        @mappings = JSON.parse mappingsJson
        @statusOrders = statusXML.Orders?.Order
        @ordersToProcess = _.size(@statusOrders)
        @logger.info "[OrderStatus] Order statuses: '#{@ordersToProcess}'"
        utils.batch(_.map(@statusOrders, (order) => api.queryOrders(@rest, "id=\"#{order.OrderId[0]}\"", "lineItems[*].state[*].state"))) if @statusOrders
    .then (fetchedOrders) =>
      #@logger.info utils.pretty fetchedOrders
      @logger.info "[OrderStatus] Fetched orders: '#{_.size(fetchedOrders)}'"
      @_processDeliveries(@statusOrders, fetchedOrders, @mappings)
      ###Q.all [
        api.ensureStates(@rest, [{key: "Initial"}])
        api.ensureStates(@rest, @stateDefs)
       ]###
    .then (priceUpdatesResult) =>
      #@priceUpdatedCount = _.size priceUpdatesResult
      #skus = _.keys(@newVariants)
      @logger.info "[OrderStatus] 3"
      #utils.batch(_.map(skus, (sku) => api.queryInventoriesBySku(@rest, sku))) if skus
    .then (fetchedInventories) =>
      @logger.info "[OrderStatus] 4"
    .then (createInventoryResult) =>
      @ordersProcessed = @ordersToProcess
      @_processResult(callback, true)
    .fail (error) =>
      @logger.error "Error on execute method; #{error}"
      @logger.error "Error stack: #{error.stack}" if error.stack
      @_processResult(callback, false)

  _processResult: (callback, isSuccess) ->
    endTime = new Date().getTime()
    result = if isSuccess then 'SUCCESS' else 'ERROR'
    @logger.info """[OrderStatus] OrderStatusImport finished with result: #{result}.
                    [OrderStatus] Orders processed: #{@ordersProcessed or 0}
                    [OrderStatus] LineItem status changed: #{@lineItemCounter or 0}
                    [OrderStatus] Deliveries created: #{@deliveriesCounter or 0}
                    [OrderStatus] Parcels created: #{@parcelsCounter or 0}
                    [OrderStatus] Processing time: #{(endTime - @startTime) / 1000} seconds."""
    callback isSuccess

  _loadMappings: (path) ->
    utils.readFile(path)

  _loadOrderStatusXML: (path) ->
    utils.xmlToJson(path)

  _processDeliveries: (statusOrders, fetchedOrders, mappings) ->
    _.each statusOrders, (statusOrder, index, list) =>
      # by convention we assume that fetched orders from SPHERE.IO are returned in the same sequence as requested
      fetchedOrder = fetchedOrders[index].results[0]
      # check if order exists in SPHERE.IO
      @_validateOrder fetchedOrder, statusOrder.OrderId[0]
      # get ordered quantity of all normal items
      #lineItemsQty = _.reduce(fetchedOrder.lineItems, ((memo, item) -> memo + item.quantity), 0)
      # get ordered quantity of all custom items
      #customLineItemsQty = _.reduce(fetchedOrder.customLineItems, ((memo, item) -> memo + item.quantity), 0)
      #orderItemsQty = lineItemsQty + customLineItemsQty
      #console.log "orderItemsQty: " + orderItemsQty
      deliveries = fetchedOrder.shippingInfo?.deliveries
      deliveredQty = 0
      if _.size(deliveries) > 0
        _.each deliveries, (delivery) ->
          # get total amount of all already delivered quantities
          deliveredQty = deliveredQty + _.reduce(delivery.items, ((memo, item) -> memo + item.quantity), 0)

      _.each statusOrder.OrderLines[0].OrderLine, (statusLine) =>
        orderLineStatus = statusLine.OrderLineStatus[0]
        quantityOrdered = statusLine.QuantityOrdered[0]
        quantityCancelled = statusLine.QuantityCancelled[0]
        quantityShipped = statusLine.QuantityShipped[0]
        quantityReturned = statusLine.QuantityReturned[0]

        fetchedLine = @_getOrderLineMatch(fetchedOrder, statusLine.OrderLineId[0])
        itemDeliveredQty = @_getDeliveredQtyForItemId(fetchedOrder, statusLine.OrderLineId[0])

        if fetchedLine
          console.log "itemDeliveredQty: " + itemDeliveredQty
          if quantityCancelled > 0
            console.log "change to 'canceled' line item state for item: '#{statusLine.OrderLineId[0]}'"
            #TODO - change line item state
          if quantityShipped > 0 and itemDeliveredQty <= fetchedLine.quantity
            console.log "create delivery, parcel and change line item state for item: '#{statusLine.OrderLineId[0]}'"
            #create delivery
            #create parcel
            #change line item state
          if quantityReturned > 0
            console.log "change to 'returned' line item state for item: '#{statusLine.OrderLineId[0]}'"
            #TODO - change line item state

          #console.log "BIBA: " + utils.pretty fetchedLine.quantity
          #console.log "OrderLineId: " + statusLine.OrderLineId[0] + ", OrderLineStatus: " + statusLine.OrderLineStatus[0] + ", fetchedLine: " + fetchedLine.id
          if deliveredQty > 0
            console.log "deliveredQty: " + deliveredQty
          else
            console.log "No deliveries for order with id: #{fetchedOrder.id}"
        else
          @logger.error "Can not process status of lineItem with id: '#{statusLine.OrderLineId[0]}' as SPHERE.IO order with id: '#{fetchedOrder.id}' does not have such item!"

  _getDeliveredQtyForItemId: (fetchedOrder, statusOrderLineId) ->
    deliveries = fetchedOrder.shippingInfo?.deliveries
    quantity = 0
    if _.size(deliveries) > 0
      _.each deliveries, (delivery) ->
        # get total amount of all already delivered quantities for given item id
        quantity = quantity + _.reduce(delivery.items,
          (memo, item) ->
            if statusOrderLineId is item.id
              memo + item.quantity
            else
              memo + 0
        , 0)
    quantity

  _getOrderLineMatch: (fetchedOrder, statusOrderLineId) ->
    fetchedLine = _.find(fetchedOrder.lineItems, (item) -> item.id is statusOrderLineId)
    if not fetchedLine
      fetchedLine = _.find(fetchedOrder.customLineItems, (item) -> item.id is statusOrderLineId)
    fetchedLine

  _validateOrder: (fetchedOrder, statusId) ->
    if not fetchedOrder
      throw new Error "No order with id '#{statusId}' in SPHERE.IO found."
    if fetchedOrder.id isnt statusId
      throw new Error "Order status sync aborted as fetched order id: '#{fetchedOrder.id}' is not equal to '#{statusId}'"

  _addDelivery: (order, deliveryItems) ->
    action =
      action: 'addDelivery'
      items: deliveryItems

    json =
      version: order.version
      actions: [action]

    api.post @rest, "/orders/#{order.id}", json

  _addParcel: (order, deliveryId, measurements, trackingData) ->
    action =
      action: 'addParcelToDelivery'
      deliveryId: deliveryId

    action.measurements = measurements if measurements?
    action.trackingData = trackingData if trackingData?

    json =
      version: order.version
      actions: [action]

    api.post @rest, "/orders/#{order.id}", json

module.exports = OrderStatusImport
