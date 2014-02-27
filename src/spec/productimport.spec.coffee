Q = require 'q'
_ = require('underscore')._
Config = require '../config'
ProductImport = require('../lib/import/productimport')
{ProductImportLogger} = require '../lib/loggers'

describe 'ProductImport', ->

  beforeEach ->
    @importer = new ProductImport _.extend _.clone(Config),
      logger: new ProductImportLogger
      appLogger: new ProductImportLogger
      source: '/sourcepath'
      mapping: '/mappingpath'

  afterEach ->
    @importer = null

  it 'should initialize', ->
    expect(@importer).toBeDefined()
    expect(@importer._options.source).toBe '/sourcepath'
    expect(@importer._options.mapping).toBe '/mappingpath'

  it 'should throw error if source path is not given', ->
    expect(-> new ProductImport).toThrow new Error 'XML source path is required'

  it 'should throw error if mapping path is not given', ->
    options = _.extend _.clone(Config), source: '/sourcepath'
    expect(-> new ProductImport options).toThrow new Error 'Product import attributes mapping (Brickfox -> SPHERE) file path is required'

  it 'should execute', (done) ->
    createMock = ->
      d = Q.defer()
      d.resolve 'Resolved'
      d.promise

    productTypesJson = """
    {
        "offset": 0,
        "count": 1,
        "total": 1,
        "results": [
            {
                "id": "7c6f40db-45k9-4m7a-ax35-f39d1140e775",
                "version": 2,
                "name": "BrickfoxType",
                "description": "Example brickfox type",
                "classifier": "Complex",
                "attributes": [
                    {
                        "type": {
                            "name": "text"
                        },
                        "name": "VariationId",
                        "label": {
                            "de": "VariationId",
                            "en": "VariationId"
                        },
                        "isRequired": false,
                        "inputHint": "SingleLine",
                        "displayGroup": "Other",
                        "isSearchable": true,
                        "attributeConstraint": "None"
                    }
                ],
                "createdAt": "2014-02-17T08:26:59.280Z",
                "lastModifiedAt": "2014-02-17T08:59:04.238Z"
            }
        ]
    }
    """

    createProductTypesMock = ->
      d = Q.defer()
      d.resolve JSON.parse(productTypesJson)
      d.promise

    spyOn(@importer, '_readFile').andReturn createMock()
    spyOn(@importer, '_parseXml').andReturn createMock()
    spyOn(@importer, '_fetchProductTypes').andReturn createProductTypesMock()
    spyOn(@importer, '_buildProductsData').andReturn [{foo: 'bar'}]
    spyOn(@importer, '_createProduct').andReturn createMock()

    @importer.execute (result) =>
      expect(@importer._readFile).toHaveBeenCalledWith '/sourcepath'
      expect(@importer._readFile).toHaveBeenCalledWith '/mappingpath'
      expect(@importer._parseXml).toHaveBeenCalledWith 'Resolved'
      expect(@importer._fetchProductTypes).toHaveBeenCalled()
      expect(@importer._buildProductsData).toHaveBeenCalled()
      expect(@importer._createProduct).toHaveBeenCalledWith {foo: 'bar'}
      expect(result).toBe true
      done()

  it 'should fetch product types', (done) ->
    spyOn(@importer.rest, 'GET').andCallFake (options, callback) -> callback(null, {statusCode: 200}, {foo: 'bar'})
    @importer._fetchProductTypes()
    .then (result) =>
      expect(result).toEqual foo: 'bar'
      expect(@importer.rest.GET).toHaveBeenCalledWith '/product-types', jasmine.any(Function)
      done()
    .fail (error) ->
      console.log error
      expect(error).not.toBeDefined()
