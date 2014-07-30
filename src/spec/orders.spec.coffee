Q = require 'q'
_ = require 'lodash-node'
{ExtendedLogger} = require 'sphere-node-utils'
Config = require '../config.json'
Mappings = require '../examples/mapping.json'
Orders = require('../lib/export/orders')
package_json = require '../package.json'
exampleOrders = require '../models/orders.json'
exampleChannel = require '../models/channel.json'


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
    @orderExportChannel = exampleChannel.body
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
    unsyncedOrders = @exporter._filterByUnsyncedOrders(orders, @orderExportChannel.id)

    expect(_.size(unsyncedOrders)).toEqual 3
    expect(unsyncedOrders[0].id).toBe 'a'
    expect(unsyncedOrders[1].id).toBe 'b'
    expect(unsyncedOrders[2].id).toBe 'e'

  it 'should export new order as XML', (done) ->
    spyOn(@exporter.client.channels, 'ensure').andCallFake (key, role) -> Q(exampleChannel)
    spyOn(@exporter, '_queryOrders').andReturn Q({"results": exampleOrders})
    spyOn(@exporter, '_writeFile').andReturn Q('CREATED')
    spyOn(@exporter, '_validateXML')
    spyOn(@exporter, '_buildOrderSyncInfoUpdates')

    @exporter.execute(Mappings, @target)
    .then (result) =>
      expect(@exporter._validateXML).toHaveBeenCalled()
      expect(@exporter._validateXML.mostRecentCall.args[0]).toContain('Orders count="2"')
      expect(@exporter._writeFile).toHaveBeenCalled()
      expect(@exporter._buildOrderSyncInfoUpdates).toHaveBeenCalled()
      done()
    .fail (error) ->
      done(error)
