# TODO
Config = require '../config'
Products = require('../lib/import/products')
Q = require('q')

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 10000

xdescribe '#execute', ->
  beforeEach (done) ->
    @importer = new Products Config
    done()

  it 'Nothing to do', (done) ->
    @importer.execute (success) ->
      expect(success).toBe true
      done()