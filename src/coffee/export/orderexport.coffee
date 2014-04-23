Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
builder = require 'xmlbuilder'
libxmljs = require 'libxmljs'
{Rest, SphereClient} = require 'sphere-node-connect'
SphereClient = require 'sphere-node-client'
{_u} = require 'sphere-node-utils'
api = require '../../lib/sphere'
utils = require '../../lib/utils'

###
Exports SPHERE orders as XML (in compliance with Brickfox order import XSD)
###
class OrderExport

  constructor: (@_options = {}) ->
    @rest = new Rest @_options
    @client = new SphereClient @_options
    @logger = @_options.appLogger
    @ordersExported = 0
    @success = false

  ###
  # Loads orders from SPHERE with status:
  # Detailed steps:
  # 1) Fetch unsynced / not exported orders from Sphere
  #
  # 2) Write orders to XML file.
  #
  # 3) Update SPHERE orders with sync information
  ###
  execute: (mappings, targetPath) ->
    @startTime = new Date().getTime()
    orderQuery = @_buildOrderQuery @_options.numberOfDays

    Q.spread [
      api.queryOrders(@rest, orderQuery)
      @_loadOrdersXsd './examples/xsd/orders.xsd'
    ], (fetchedOrders, ordersXsd) =>
      utils.assertProductIdMappingIsDefined mappings.productImport.mapping
      utils.assertVariationIdMappingIsDefined mappings.productImport.mapping
      utils.assertSkuMappingIsDefined mappings.productImport.mapping
      if fetchedOrders
        @client.channels.ensure(mappings.orderExport.channel.key, mappings.orderExport.channel.role)
        .then (createOrGetChannelResult) =>
          @channel = createOrGetChannelResult.body
          # TODO refactor as soon as collection query in SPHERE.IO is fixed
          @unsyncedOrders = @_filterByUnsyncedOrders(fetchedOrders.results, @channel)
          if _.size(@unsyncedOrders) > 0
            @logger.info "[OrderExport] Orders to export count: '#{_.size @unsyncedOrders}'"
            xmlOrders = @_ordersToXML(@unsyncedOrders, mappings.productImport.mapping)
            content = xmlOrders.end(pretty: true, indent: '  ', newline: "\n")
            @_validateXML(content, ordersXsd)
            @fileName = @_getFileName(targetPath)
            @_writeFile(@fileName, content)
          else
            @logger.info "[OrderExport] No unexported orders found."
            Q()
    .then (writeFileResult) =>
      if writeFileResult is 'CREATED'
        @logger.info "[OrderExport] Successfully created XML file: '#{@fileName}'"
        syncInfoUpdates = @_buildOrderSyncInfoUpdates(@unsyncedOrders, @channel)
        Q(syncInfoUpdates)
      else
        # nothing to export
        @success = true
        Q()

  outputSummary: ->
    endTime = new Date().getTime()
    result = if @success then 'SUCCESS' else 'ERROR'
    @logger.info """[OrderExport] Finished with result: #{result}.
                    [OrderExport] Orders exported: #{@ordersExported}
                    [OrderExport] Processing time: #{(endTime - @startTime) / 1000} seconds."""

  doPostProcessing: (syncInfoUpdates) ->
    Q.all(_.map(syncInfoUpdates, (o) => @client.orders.byId(o.id).save(o.payload)))
    .then (result) =>
      resultSize = _.size(result)
      @logger.info "[OrderExport] Updated order SyncInfo count: '#{resultSize}'" if resultSize > 0
      @ordersExported = resultSize
      @success = true
      Q(result)

  _getFileName: (path) ->
    if _s.endsWith(path, '.xml')
      return path
    else
      timeStamp = new Date().getTime()
      if _s.endsWith(path, '/')
        return "#{path}Orders-#{timeStamp}.xml"
      else
        return "#{path}/Orders-#{timeStamp}.xml"

  _loadOrdersXsd: (path) ->
    utils.readFile(path)

  _writeFile: (path, content) ->
    utils.writeFile(path, content)

  _buildOrderQuery: (numberOfDays) ->
    # TODO refactor as soon as collection query in SPHERE.IO is fixed.
    # Then we should query for orders which are open and does not have sync info with code 'xyz'.
    date = new Date()
    numberOfDays = 7 if not numberOfDays
    date.setDate(date.getDate() - numberOfDays)
    query = "createdAt > \"#{date.toISOString().substring(0,10)}T00:00:00.000Z\""

  _buildOrderSyncInfoUpdates: (unsyncedOrders, channel) ->
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
              id: channel.id
            externalId: o.id
          ]
      updates.push wrapper

    if _.size(updates) > 0
      updates
    else
      null

  ###
  Returns only orders which haven't been synchronized using the given channel.
  @param {Array} orders List of order resources.
  @param {Object} channel SyncInfo channel.
  @return {Array} List of orders without given channel.
  ###
  _filterByUnsyncedOrders: (orders, channel) ->
    _.filter orders, (order) ->
      _.size(order.syncInfo) is 0 or _.find order.syncInfo, (syncInfo) -> syncInfo.channel.id isnt channel.id

  _ordersToXML: (orders, mappings) ->
    root = builder.create('Orders', { 'version': '1.0', 'encoding': 'UTF-8'})
    root.att('count', orders.length)
    _.each orders, (order, index, list) =>
      orderXML = root.ele("Order", {num: index + 1})
      @_orderToXML(order, orderXML, mappings)
    root

  _orderToXML: (order, orderXML, mappings) =>
    @logger.info "[OrderExport] Processing order with orderNumber: '#{order.orderNumber}', id: '#{order.id}'"
    orderXML.e('OrderId').t(order.orderNumber)
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
