Q = require 'q'
_ = require 'underscore'
_s = require 'underscore.string'
{Rest} = require 'sphere-node-connect'
SphereClient = require 'sphere-node-client'
{_u} = require 'sphere-node-utils'
api = require '../sphere'
utils = require '../utils'



###
Imports Brickfox order status updates into SPHERE.IO.
###
class OrderStatusImport

  constructor: (@_options = {}) ->
    @rest = new Rest @_options
    @logger = @_options.appLogger
    @client = new SphereClient @_options
    @client.setMaxParallel(100)
    @allOrdersCounter = 0
    @allCanceledCounter = 0
    @allShippedCounter = 0
    @allReturnedCounter = 0
    @canceledCounter = 0
    @returnedCounter = 0
    @shippedCounter = 0

  ###
  # Reads given order status import XML file and creates deliveries, parcels and sets line item state
  # Detailed steps:
  # 1) Load order status import data
  #
  # 2) Fetch orders for which status will be changed
  #
  # 3) Build line item status changes
  # 3.1) Send line item status changes
  #
  # 4) Build deliveries
  # 4.1) Send deliveries
  #
  # 5) Build parcels
  # 5.1) Send parcels
  #
  # @param {function} callback The callback function to be invoked when the method finished its work.
  # @return Result of the given callback
  ###
  execute: (callback) ->
    @startTime = new Date().getTime()
    @logger.info '[OrderStatus] OrderStatusImport execution started.'

    Q.spread [
      @_loadMappings @_options.mapping
      @_loadOrderStatusXML @_options.status
      ],
      (mappingsJson, statusXML) =>
        @mappings = JSON.parse mappingsJson
        @statusOrders = statusXML.Orders?.Order
        @logger.info "[OrderStatus] Total order statuses to process: '#{_.size(@statusOrders)}'"
        utils.batch(_.map(@statusOrders, (order) => api.queryOrders(@rest, "orderNumber=\"#{order.OrderId[0]}\"", 'lineItems[*].state[*].state'))) if @statusOrders
    .then (fetchedOrders) =>
      @logger.info "[OrderStatus] Fetched SPHERE.IO orders: '#{_.size(fetchedOrders)}'"
      @_fetchOrCreateStates(@_options, @mappings)
      .then (fetchedStatesResult) =>
        fetchedStates = fetchedStatesResult.body.results
        @_processOrderStatus(@statusOrders, fetchedOrders, @mappings, fetchedStates)
    .then (priceUpdatesResult) =>
      @_processResult(callback, true)
    .fail (error) =>
      @logger.error "Error on execute method; #{error}"
      @logger.error "Error stack: #{error.stack}" if error.stack
      @_processResult(callback, false)

  _processResult: (callback, isSuccess) ->
    endTime = new Date().getTime()
    result = if isSuccess then 'SUCCESS' else 'ERROR'
    @logger.info """[OrderStatus] OrderStatusImport finished with result: #{result}.
                    [OrderStatus] Total orders processed: #{@allOrdersCounter or 0}
                    [OrderStatus] Total canceled: #{@allCanceledCounter or 0}
                    [OrderStatus] Total shipped: #{@allShippedCounter or 0}
                    [OrderStatus] Total returned: #{@allReturnedCounter or 0}
                    [OrderStatus] Processing time: #{(endTime - @startTime) / 1000} seconds."""
    callback isSuccess

  _loadMappings: (path) ->
    utils.readFile(path)

  _loadOrderStatusXML: (path) ->
    utils.xmlToJson(path)

  _fetchOrCreateStates: (options, mappings) ->
    if options.createstates and _.size(mappings.orderStates?.states) > 0
      api.ensureStates(@rest, mappings.orderStates.states)
      .then (result) =>
        @client.states.perPage(0).fetch()
    else
      @client.states.perPage(0).fetch()

  _processOrderStatus: (statusOrders, fetchedOrders, mappings, fetchedStates) ->
    index = 0
    Q.all _.map statusOrders, (statusOrder) =>
      shippingTrackingId = statusOrder.ShippingTrackingId?[0]
      # by convention we assume that fetched orders from SPHERE.IO are returned in the same sequence as requested
      fetchedOrder = fetchedOrders[index].results[0]
      index++
      @allOrdersCounter++
      # check if we got the right order from SPHERE.IO
      @_validateOrder fetchedOrder, statusOrder.OrderId[0]
      deliveryItems = []
      transitionActions = []

      _.each statusOrder.OrderLines[0].OrderLine, (statusLine) =>
        orderLineStatusId = statusLine.OrderLineId[0]
        orderLineStatus = statusLine.OrderLineStatus[0]
        quantityCancelled = _s.toNumber(statusLine.QuantityCancelled[0])
        quantityShipped = _s.toNumber(statusLine.QuantityShipped[0])
        quantityReturned = _s.toNumber(statusLine.QuantityReturned[0])

        fetchedLine = @_getOrderLineMatch(fetchedOrder, orderLineStatusId)
        itemDeliveredQty = @_getDeliveredQtyForLineItemId(fetchedOrder, orderLineStatusId)

        if fetchedLine
          if quantityCancelled > 0
            # change line item state
            transitionActions = transitionActions.concat @_createLineItemStateTransitionActions(mappings, fetchedOrder, fetchedLine, orderLineStatus, quantityCancelled, fetchedStates)
            @canceledCounter = @canceledCounter + quantityCancelled

          if quantityShipped > 0 and fetchedLine.quantity >= (itemDeliveredQty + quantityShipped)
            if not shippingTrackingId
              throw new Error "Can not create delivery as 'ShippingTrackingId' is missing for orderNumber: '#{fetchedOrder.orderNumber}'"
            # add delivery / parcel
            deliveryItems.push {id: fetchedLine.id, quantity: _s.toNumber(quantityShipped)}
            # change line item state
            transitionActions = transitionActions.concat @_createLineItemStateTransitionActions(mappings, fetchedOrder, fetchedLine, orderLineStatus, quantityShipped, fetchedStates)
            @shippedCounter = @shippedCounter + quantityShipped

          if quantityReturned > 0
            # change line item state
            transitionActions = transitionActions.concat @_createLineItemStateTransitionActions(mappings, fetchedOrder, fetchedLine, orderLineStatus, quantityReturned, fetchedStates)
            @returnedCounter = @returnedCounter + quantityReturned
        else
          throw new Error "Can not process brickfox lineItem status with id: '#{orderLineStatusId}' as item could not be found in SPHERE.IO order with id: '#{fetchedOrder.id}'"

      if _.size(transitionActions) > 0
        @logger.info "About to change order state; orderNumber: '#{fetchedOrder.orderNumber}', canceled: '#{@canceledCounter}', returned: '#{@returnedCounter}', shipped: '#{@shippedCounter}'"
        @allCanceledCounter = @allCanceledCounter + @canceledCounter
        @allShippedCounter = @allShippedCounter + @shippedCounter
        @allReturnedCounter = @allReturnedCounter + @returnedCounter
        api.transitionLineItemStates(@rest, fetchedOrder, transitionActions)
        .then (transitionStatesResult) =>
          if _.size(deliveryItems) > 0
            api.addDelivery(@rest, transitionStatesResult, deliveryItems)
            .then (addDeliveryResult) =>
              deliveries = addDeliveryResult.shippingInfo.deliveries
              delivery = @_getMostRecentDelivery deliveries
              api.addParcel(@rest, addDeliveryResult, delivery.id, {trackingId: shippingTrackingId})
              .then (addParcelResult) ->
      else
        @logger.info "No order state change for orderNumber: '#{fetchedOrder.orderNumber}' required."



  _createLineItemStateTransitionActions: (mappings, fetchedOrder, fetchedLine, orderLineStatus, quantity, fetchedStates, date) ->
    actions = []
    lineItemId = fetchedLine.id
    lineItemStates = fetchedLine.state
    filteredByQty = _.filter lineItemStates, (s) -> s.quantity >= quantity
    size = _.size(filteredByQty)
    if not size > 0
      throw new Error "Could not find state with required quantity: '#{quantity}'; Brickfox state: '#{orderLineStatus}', lineItem id: '#{lineItemId}', order id: '#{fetchedOrder.id}'"

    transitions = mappings.orderStates.mapping[orderLineStatus]
    if _.size(transitions) > 0
      _.map transitions, (t) =>
        if t.from isnt t.to
          action =
            action: if fetchedLine.custom then 'transitionCustomLineItemState' else 'transitionLineItemState'
            lineItemId: lineItemId
            quantity: _s.toNumber(quantity)
            fromState: {typeId: 'state', id: @_stateByKey(t.from, fetchedStates).id}
            toState: {typeId: 'state', id: @_stateByKey(t.to, fetchedStates).id}

          if date
            action.actualTransitionDate = date
          actions.push action
    actions

  _stateByKey: (key, states) ->
    state = _.find states, (s) -> s.key is key
    if not state
      throw new Error "No state for key: '#{key}' found."
    state

  _getMostRecentDelivery: (deliveries) ->
    # we are interested in deliveries without parcels only
    filtered = _.filter deliveries, (d) -> _.size(d.parcels) is 0
    #console.log "ALL delivery candidates: " + _u.prettify(filtered)
    if _.size(filtered) > 0
      # sort deliveries ascending by date
      sorted = filtered.sort (a, b) ->
        if (a.createdAt > b.createdAt) then return 1
        if (b.createdAt < a.createdAt) then return -1
        return 0
      #console.log "MOST RECENT delivery: " + _u.prettify(_.last(sorted))
      _.last sorted

  _getDeliveredQtyForLineItemId: (fetchedOrder, orderLineStatusId) ->
    deliveries = fetchedOrder.shippingInfo?.deliveries
    quantity = 0
    if _.size(deliveries) > 0
      _.each deliveries, (delivery) ->
        # get total amount of all already delivered quantities for given item id
        quantity = quantity + _.reduce(delivery.items,
          (memo, item) ->
            if orderLineStatusId is item.id
              memo + item.quantity
            else
              memo + 0
        , 0)
    quantity

  _getOrderLineMatch: (fetchedOrder, orderLineStatusId) ->
    fetchedLine = _.find(fetchedOrder.lineItems, (item) -> item.id is orderLineStatusId)
    if not fetchedLine
      fetchedLine = _.find(fetchedOrder.customLineItems, (item) -> item.id is orderLineStatusId)
      fetchedLine.custom = true if fetchedLine
    fetchedLine

  _validateOrder: (fetchedOrder, statusOrderId) ->
    if not fetchedOrder
      throw new Error "No order with id '#{statusOrderId}' in SPHERE.IO found."
    if fetchedOrder.orderNumber isnt statusOrderId
      throw new Error "Order status sync aborted as fetched order id: '#{fetchedOrder.id}' is not equal to '#{statusOrderId}'"

module.exports = OrderStatusImport
