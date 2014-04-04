Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
builder = require 'xmlbuilder'
libxmljs = require 'libxmljs'
{Rest} = require('sphere-node-connect')
api = require '../../lib/sphere'
utils = require '../../lib/utils'

###
Exports SPHERE orders as XML (in compliance with Brickfox order import XSD)
###
class OrderExport

  constructor: (@_options = {}) ->
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
    orderQuery = @_buildOrderQuery numberOfDays

    Q.spread [
      @_loadMappings @_options.mapping
      api.queryOrders(@rest, orderQuery)
      @_loadOrdersXsd './examples/xsd/orders.xsd'
      ],
      (mappingsJson, fetchedOrders, ordersXsd) =>
        mappings = JSON.parse mappingsJson
        utils.assertProductIdMappingIsDefined mappings.product
        utils.assertVariationIdMappingIsDefined mappings.product
        utils.assertSkuMappingIsDefined mappings.product
        if fetchedOrders
          # TODO refactor as soon as collection query in SPHERE.IO is fixed
          @unsyncedOrders = _.filter fetchedOrders, (o) -> _.size(o.syncInfo) is 0
        if _.size(@unsyncedOrders) > 0
          @logger.info "[OrderExport] Orders to export count: '#{_.size @unsyncedOrders}'"
          xmlOrders = @_ordersToXML(@unsyncedOrders, mappings.product)
          content = xmlOrders.end(pretty: true, indent: '  ', newline: "\n")
          @_validateXML(content, ordersXsd)
          @fileName = @_getFileName(@_options.output)
          @_writeFile(@fileName, content)
        else
          @logger.info "[OrderExport] No unexported orders found."
    .then (writeXMLResult) =>
      if writeXMLResult is 'OK'
        @logger.info "[OrderExport] Successfully created XML file: '#{@fileName}'"
        orderUpdates = @_buildOrderSyncInfoUpdates(@unsyncedOrders, @_options.channelid) if _.size(@unsyncedOrders) > 0
        # update order sync info
        utils.batch(_.map(orderUpdates, (o) => api.updateOrder(@rest, o.id, o.payload))) if orderUpdates
    .then (result) =>
      @logger.info "[OrderExport] Updated order SyncInfo count: '#{_.size result}'" if _.size(result) > 0
      @_processResult(callback, true)
    .fail (error) =>
      @logger.error "Error on execute method; #{error}"
      @logger.error "Error stack: #{error.stack}" if error.stack
      @_processResult(callback, false)

  _getFileName: (path) ->
    if _s.endsWith(path, '.xml')
      return path
    else
      timeStamp = new Date().getTime()
      return "#{path}Orders-#{timeStamp}.xml"

  _processResult: (callback, isSuccess) ->
    endTime = new Date().getTime()
    result = if isSuccess then 'SUCCESS' else 'ERROR'
    @logger.info """[OrderExport] Finished with result: #{result}.
                    [OrderExport] Processing time: #{(endTime - @startTime) / 1000} seconds."""
    callback isSuccess

  _loadMappings: (path) ->
    utils.readFile(path)

  _loadOrdersXsd: (path) ->
    utils.readFile(path)

  _writeFile: (path, content) ->
    utils.writeFile(path, content)

  _buildOrderQuery: (numberOfDays) ->
    # TODO refactor as soon as collection query in SPHERE.IO is fixed. Getting all orders without syncInfo should be enough
    # i.e.: 'where=syncInfo is empty'
    date = new Date()
    numberOfDays = 7 if numberOfDays is undefined
    date.setDate(date.getDate() - numberOfDays)
    d = "#{date.toISOString().substring(0,10)}T00:00:00.000Z"
    query = "createdAt > \"#{d}\""

  _buildOrderSyncInfoUpdates: (unsyncedOrders, channelId) ->
    updates = []

    _.each unsyncedOrders, (o) ->
      wrapper =
        id: o.id
        payload:
          version: o.version
          actions: [
            action: 'updateSyncInfo'
            channel:
              typeId: 'channel'
              id: channelId
            externalId: o.id
          ]
      updates.push wrapper

    if _.size(updates) > 0
      updates
    else
      null

  _ordersToXML: (orders, mappings) ->
    root = builder.create('Orders', { 'version': '1.0', 'encoding': 'UTF-8'})
    root.att('count', orders.length)
    _.each orders, (order, index, list) =>
      orderXML = root.ele("Order", {num: index + 1})
      @_orderToXML(order, orderXML, mappings)
    root

  _orderToXML: (order, orderXML, mappings) =>
    @logger.debug "[OrderExport] Processing order with id: '#{order.id}'"
    # TODO use orderNumber for export and for order status synchronization (not order UUID)
    orderXML.e('OrderId').t(order.id)
    orderXML.e('OrderDate').t(order.createdAt)
    #<xs:element ref="OrderStatus" minOccurs="0"/>
    #<xs:element ref="PaymentStatus" minOccurs="0"/>
    #<xs:element ref="CustomerId" minOccurs="0"/>
    #<xs:element ref="TotalAmountProducts" minOccurs="0"/>
    orderXML.e('TotalAmountProductsNetto').t(@_toAmount(order.taxedPrice.totalNet.centAmount))
    orderXML.e('TotalAmountVat').t(@_toAmount(order.taxedPrice.taxPortions[0].amount.centAmount))
    shippingInfo = order.shippingInfo
    throw new Error "Can not export order as it does not contain shipping info; order id: '#{order.id}'" if not shippingInfo
    shippingCost = @_toAmount(shippingInfo.price.centAmount)
    orderXML.e('ShippingCost').t(shippingCost)
    #<xs:element ref="PaymentCost" minOccurs="0"/>
    orderXML.e('TotalAmount').t(@_toAmount(order.taxedPrice.totalGross.centAmount))
    #<xs:element ref="Comment" minOccurs="0"/>
    #<xs:element ref="CostsChangings" minOccurs="0"/>
    # TODO use real data for PaymentMethod
    orderXML.e('PaymentMethod').t('test')
    pmValues = orderXML.ele("PaymentMethodValues")
    # TODO use real data for PaymentMethodValue
    pmValue = pmValues.ele("PaymentMethodValue", {key: 'testKey', value: 'testValue'})
    orderXML.e('ShippingMethod').t(shippingInfo.shippingMethodName)
    billingAddress = if order.billingAddress then order.billingAddress else order.shippingAddress
    @_addressToXML(billingAddress, orderXML, 'BillingParty')
    @_addressToXML(order.shippingAddress, orderXML, 'DeliveryParty')
    #<xs:element ref="Coupons" minOccurs="0"/>

    lineItemsXML = orderXML.ele("OrderLines", {'count': order.lineItems.length})
    _.each order.lineItems, (lineItem, index, list) =>
      lineItemXML = lineItemsXML.ele("OrderLine", {num: index + 1})
      @_lineItemToXML(lineItem, lineItemXML, mappings)

  _lineItemToXML: (lineItem, lineItemXML, mappings) =>
    lineItemXML.e('OrderLineId').t(lineItem.id)
    productId = utils.getVariantAttValue(mappings, 'ProductId', lineItem.variant)
    variationId = utils.getVariantAttValue(mappings, 'VariationId', lineItem.variant)
    lineItemXML.e('ProductId').t(productId)
    name = _.values(lineItem.name)[0]
    lineItemXML.e('ProductName').t(name)
    lineItemXML.e('ItemNumber').t(lineItem.variant.sku)
    lineItemXML.e('VariationId').t(variationId)
    lineItemXML.e('QuantityOrdered').t(lineItem.quantity)
    lineItemXML.e('ProductsPriceTotal').t(@_toAmount(lineItem.price.value.centAmount))
    lineItemXML.e('ProductsPrice').t(@_toProductPriceFromTotal(lineItem.price.value.centAmount, lineItem.quantity))
    lineItemXML.e('TaxRate').t(@_toTax(lineItem.taxRate.amount))

  _toAmount: (centAmount) ->
    amount = _s.numberFormat(_s.toNumber(centAmount / 100), 2)

  _toTax: (rate) ->
    rate = _s.numberFormat(_s.toNumber(rate * 100), 2)

  _toProductPriceFromTotal: (centAmount, quantity) ->
    amount = _s.numberFormat(_s.toNumber(centAmount / quantity / 100), 2)

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

  _validateXML: (xml, xsd) ->
    xmlDoc = libxmljs.parseXmlString xml
    xsdDoc = libxmljs.parseXmlString xsd
    result = xmlDoc.validate(xsdDoc)
    throw new Error "XML validation against XSD schema failed. XML content: \n #{xml}" if not result

module.exports = OrderExport
