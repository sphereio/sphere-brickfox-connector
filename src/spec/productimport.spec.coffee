Q = require 'q'
_ = require('underscore')._
Config = require '../config'
ProductImport = require('../lib/import/productimport')

describe 'ProductImport', ->
  beforeEach ->
    @importer = new ProductImport _.extend Config, source: '/foo'

  afterEach ->
    @importer = null

  it 'should initialize', ->
    expect(@importer).toBeDefined()
    expect(@importer._options.source).toBe '/foo'

  it 'should throw error if source path is not given', ->
    expect(-> new ProductImport).toThrow new Error 'XML source path is required'

  it 'should execute', (done) ->
    createMock = ->
      d = Q.defer()
      d.resolve 'Resolved'
      d.promise

    spyOn(@importer, '_readFile').andReturn createMock()
    spyOn(@importer, '_parseXml').andReturn createMock()
    spyOn(@importer, '_getProductTypes').andReturn createMock()
    spyOn(@importer, '_buildProductsData').andReturn [{foo: 'bar'}]
    spyOn(@importer, '_createProduct').andReturn createMock()

    @importer.execute (result) =>
      expect(result).toBe true
      expect(@importer._readFile).toHaveBeenCalledWith '/foo'
      expect(@importer._parseXml).toHaveBeenCalledWith 'Resolved'
      expect(@importer._getProductTypes).toHaveBeenCalled()
      expect(@importer._buildProductsData).toHaveBeenCalled()
      expect(@importer._createProduct).toHaveBeenCalledWith {foo: 'bar'}
      done()

  it 'should fetch product types', (done) ->
    spyOn(@importer.rest, 'GET').andCallFake (options, callback) -> callback(null, {statusCode: 200}, {foo: 'bar'})
    @importer._getProductTypes()
    .then (result) =>
      expect(result).toEqual foo: 'bar'
      expect(@importer.rest.GET).toHaveBeenCalledWith '/product-types', jasmine.any(Function)
      done()
    .fail (error) ->
      console.log error
      expect(error).not.toBeDefined()
