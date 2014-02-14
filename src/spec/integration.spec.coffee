# TODO
Config = require '../config'
ProductImport = require('../lib/import/productimport')
Q = require('q')

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 10000

xdescribe '#execute', ->
  beforeEach (done) ->
    @importer = new ProductImport Config
    done()

  it 'Nothing to do', (done) ->
    @importer.execute (success) ->
      expect(success).toBe true
      done()