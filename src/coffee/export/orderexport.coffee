fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
builder = require 'xmlbuilder'
utils = require '../../lib/utils'
{Rest} = require('sphere-node-connect')

###
Exports SPHERE orders as XML (in compliance with Brickfox order import XSD)
###
class OrderExport

  constructor: (@_options = {}) ->
    throw new Error "XML file 'output' path argument to write orders is required" unless @_options.output
    throw new Error 'Product import attributes mapping (Brickfox -> SPHERE) file path argument is required' unless @_options.mapping
    throw new Error 'OrderExport SyncInfo channel id argument is required.' unless @_options.channelid
    @rest = new Rest @_options
    @logger = @_options.appLogger

  ###
  # Loads orders from SPHERE with status:
  # Detailed steps:
  # 1) Fetch unsynced / not exported orders from Sphere
  #
  # 2) Write orders to XML file.
  #
  # 3) Update SPHERE orders with sync information
  #
  # @param {function} callback The callback function to be invoked when the method finished its work.
  # @return Result of the given callback
  ###
  execute: (callback) =>
    @startTime = new Date().getTime()
    @logger.info '[OrderExport] OrderExport execution started...'
    numberOfDays = @_options.numberOfDays

    Q.spread [
      @_loadMappings @_options.mapping
      @_getUnSyncedOrders(numberOfDays)
      ],
      (mappingsJson, fetchedOrders) =>
        @mappings = JSON.parse mappingsJson
        utils.assertProductIdMappingIsDefined @mappings
        utils.assertVariationIdMappingIsDefined @mappings
        utils.assertSkuMappingIsDefined @mappings
        @fetchedOrders = fetchedOrders
        if _.size(@fetchedOrders) > 0
          @logger.info "[OrderExport] Orders to export count: '#{_.size @fetchedOrders}'"
          xmlOrders = @_ordersToXML(@fetchedOrders)
          content = xmlOrders.end(pretty: true, indent: '  ', newline: "\n")
          @_writeFile(@_options.output, content)
        else
          @logger.info "[OrderExport] No unexported orders found."
    .then (writeXMLResult) =>
      if writeXMLResult is 'OK'
        @logger.info "[OrderExport] Write file '#{@_options.output}' finished."
      utils.batch(_.map(@fetchedOrders, (o) => @_addSyncInfo(o.id, o.version, @_options.channelid, o.id)), 100) if _.size(@fetchedOrders) > 0
    .fail (error) =>
      @logger.error "Error on execute method; #{error}"
      @logger.error "Error stack: #{error.stack}" if error.stack
      @_processResult(callback, false)
    .done (result) =>
      @logger.info "[OrderExport] Updated SyncInfo for '#{_.size result}' orders." if _.size(result) > 0
      @_processResult(callback, true)

  _processResult: (callback, isSuccess) ->
    endTime = new Date().getTime()
    result = if isSuccess then 'SUCCESS' else 'ERROR'
    @logger.info """[OrderExport] Finished with result: #{result}.
                    [OrderExport] Processing time: #{(endTime - @startTime) / 1000} seconds."""
    callback isSuccess

  _loadMappings: (path) ->
    utils.readFile(path)

  _writeFile: (path, content) ->
    utils.writeFile(path, content)

  _getUnSyncedOrders: (numberOfDays) ->
    deferred = Q.defer()
    date = new Date()
    numberOfDays = 7 if numberOfDays is undefined
    date.setDate(date.getDate() - numberOfDays)
    d = "#{date.toISOString().substring(0,10)}T00:00:00.000Z"
    query = encodeURIComponent "createdAt > \"#{d}\""
    @rest.GET "/orders?limit=0&where=#{query}", (error, response, body) ->
      if error
        deferred.reject "Error on fetching orders: " + error
      else if response.statusCode isnt 200
        deferred.reject "Problem on fetching orders (status: #{response.statusCode}): " + body
      else
        orders = body.results
        unsyncedOrders = _.filter orders, (o) -> _.size(o.syncInfo) is 0
        deferred.resolve unsyncedOrders
    deferred.promise

  _addSyncInfo: (orderId, orderVersion, channelId, externalId) ->
    deferred = Q.defer()
    data =
      version: orderVersion
      actions: [
        action: 'updateSyncInfo'
        channel:
          typeId: 'channel'
          id: channelId
        externalId: externalId
      ]
    @rest.POST "/orders/#{orderId}", data, (error, response, body) ->
      if error
        deferred.reject "Error on setting sync info: " + error
      else if response.statusCode isnt 200
        deferred.reject "Problem on setting sync info (status: #{response.statusCode}): " + body
      else
        deferred.resolve "Order sync info successfully stored."
    deferred.promise

  _ordersToXML: (orders) ->
    root = builder.create('Orders', { 'version': '1.0', 'encoding': 'UTF-8'})
    root.att('count', orders.length)
    _.each orders, (order, index, list) =>
      orderXML = root.ele("Order", {num: index + 1})
      @_orderToXML(order, orderXML)
    root

  _orderToXML: (order, orderXML) =>
    @logger.debug "[OrderExport] Processing order with id: '#{order.id}'"
    orderXML.e('OrderId').t(order.id)
    orderXML.e('OrderDate').t(order.createdAt)
    orderXML.e('TotalAmountProductsNetto').t(@_toAmount(order.taxedPrice.totalNet.centAmount))
    orderXML.e('TotalAmountVat').t(@_toAmount(order.taxedPrice.taxPortions[0].amount.centAmount))
    orderXML.e('TotalAmount').t(@_toAmount(order.taxedPrice.totalGross.centAmount))

    if order.shippingInfo
      shippingCost = @_toAmount(shippingInfo.price.centAmount)
      orderXML.e('ShippingCost').t(shippingCost)
      orderXML.e('ShippingMethod').t(shippingInfo.shippingMethodName)

    @_addressToXML(order.shippingAddress, orderXML, 'DeliveryParty')
    @_addressToXML(order.billingAddress, orderXML, 'BillingParty') if order.billingAddress

    lineItemsXML = orderXML.ele("OrderLines", {'count': order.lineItems.length})
    _.each order.lineItems, (lineItem, index, list) =>
      lineItemXML = lineItemsXML.ele("OrderLine", {num: index + 1})
      @_lineItemToXML(lineItem, lineItemXML)

  _lineItemToXML: (lineItem, lineItemXML) =>
    lineItemXML.e('OrderLineId').t(lineItem.id)
    productId = utils.getVariantAttValue(@mappings, 'ProductId', lineItem.variant)
    variationId = utils.getVariantAttValue(@mappings, 'VariationId', lineItem.variant)
    lineItemXML.e('ProductId').t(productId)
    lineItemXML.e('ItemNumber').t(lineItem.variant.sku)
    lineItemXML.e('VariationId').t(variationId)
    name = _.values(lineItem.name)[0]
    lineItemXML.e('ProductName').t(name)
    lineItemXML.e('QuantityOrdered').t(lineItem.quantity)
    lineItemXML.e('ProductsPriceTotal').t(@_toAmount(lineItem.price.value.centAmount))
    lineItemXML.e('TaxRate').t(@_toTax(lineItem.taxRate.amount))

  _toAmount: (centAmount) ->
    amount = _s.numberFormat(_s.toNumber(centAmount / 100), 2)

  _toTax: (rate) ->
    rate = _s.numberFormat(_s.toNumber(rate * 100), 2)

  _addressToXML: (address, xml, name) ->
    el = xml.ele(name)
    el.e('Title').t(address.title) if address.title
    el.e('Company').t(address.company) if address.company
    el.e('FirstName').t(address.firstName) if address.firstName
    el.e('LastName').t(address.lastName) if address.lastName
    el.e('Address').t(address.streetName) if address.streetName
    el.e('Number').t(address.streetNumber) if address.streetNumber
    el.e('AddressAdd').t(address.additionalStreetInfo) if address.additionalStreetInfo
    el.e('PostalCode').t(address.postalCode) if address.postalCode
    el.e('City').t(address.city) if address.city
    el.e('Country').t(address.country) if address.country
    el.e('PhonePrivate').t(address.phone) if address.phone
    el.e('EmailAddress').t(address.email) if address.email


module.exports = OrderExport
