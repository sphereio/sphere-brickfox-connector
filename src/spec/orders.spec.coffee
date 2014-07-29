Q = require 'q'
_ = require 'lodash-node'
{ExtendedLogger} = require 'sphere-node-utils'
Config = require '../config.json'
Mappings = require '../examples/mapping.json'
Orders = require('../lib/export/orders')
package_json = require '../package.json'
exampleorders = require './exampleorders'
nutil = require 'util'

describe 'Orders', ->

  logger = new ExtendedLogger
    additionalFields:
      project_key: 'testProjectKey'
      operation_type: 'orders-export'
    logConfig:
      name: "#{package_json.name}-#{package_json.version}"
      streams: [
        {level: 'info', stream: process.stderr}
        {level: 'info', path: "./sphere-brickfox-connector.log"}
      ]

  beforeEach ->
    @target = './Orders.xml'
    @orderExportChannel = {id: "foo"}
    @exporter = new Orders _.extend _.clone(Config),
      logger: logger
      appLogger: logger
      target: @target
      config:
        project_key: 'testProjectKey'
        client_id: 'testClientId'
        client_secret: 'testSecret'

  afterEach ->
    @exporter = null

  it 'should initialize', ->
    expect(@exporter).toBeDefined()
    expect(@exporter._options.target).toBe @target

  it 'should return unsynced orders', ->
    orders = [
      {id: 'a', syncInfo: [{channel: {typeId: 'channel', id: 'bar'}}]}
      {id: 'b'}
      {id: 'c', syncInfo: [{channel: {typeId: 'channel', id: @orderExportChannel.id}}]}
      {id: 'd', syncInfo: [{channel: {typeId: 'channel', id: 'bar'}},{channel: {typeId: 'channel', id: @orderExportChannel.id}}]}
      {id: 'e', syncInfo: [{channel: {typeId: 'channel', id: 'bar'}},{channel: {typeId: 'channel', id: 'bar2'}}]}
    ]
    unsyncedOrders = @exporter._filterByUnsyncedOrders(orders, @orderExportChannel)

    # a, b, e orders should be sync-ed
    expect(_.size(unsyncedOrders)).toEqual 3

  xit 'should export new order as XML', (done) ->
    createOrdersResultMock = ->
      d = Q.defer()
      d.resolve {"results": exampleorders.orders}
      d.promise

    createChannelMock = ->
      d = Q.defer()
      d.resolve @orderExportChannel
      d.promise

    createWriteFileMock = ->
      d = Q.defer()
      d.resolve 'CREATED'
      d.promise

    spyOn(@exporter.client.channels, 'ensure').andReturn createChannelMock()
    spyOn(@exporter, '_queryOrders').andReturn createOrdersResultMock()
    spyOn(@exporter, '_writeFile').andReturn createWriteFileMock()

    @exporter.execute (Mappings, @target) =>
      expect(@exporter._validateXML).toHaveBeenCalled()
      expect(@exporter._writeFile).toHaveBeenCalled()
      expect(@exporter._buildOrderSyncInfoUpdates).toHaveBeenCalled()
