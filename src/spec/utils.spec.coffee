xml2js = require 'xml2js'
utils = require '../lib/utils.js'

describe "#parseXML", ->
  it "parses XML content to JSON", (done) ->
    xml = "<root><row><id>1</id></row><row><id>2</id></row></root>"
    utils.parseXML xml
    .then (result) ->
      expected_result =
        root:
          row: [
            { id: [ '1' ] }
            { id: [ '2' ] }
          ]
      expect(result).toEqual expected_result
      done()
    .fail (m, c) ->
      expect(m).not.toBeDefined()
      expect(c).not.toBeDefined()

  it "gives feedback on xml error", (done) ->
    xml = "<root><root>"
    utils.parseXML xml
    .then (result) ->
      expect(result).not.toBeDefined()
    .fail (error) ->
      expect(error).toMatch /Can not parse XML content/
      done()

# TODO
xdescribe '#logError', ->

  it 'should throw exception', ->
    expect(-> utils.logError("Oops")).toThrow "Oops"

describe "#xmlVal", ->
  it "retrieves value from array", (done) ->
    xml = "<root><row><code>foo</code>123</row></root>"
    utils.parseXML xml
    .then (result) ->
      expect(utils.xmlVal(result.root.row[0], 'code')).toBe 'foo'
      expect(utils.xmlVal(result.root.row[0], 'foo', 'defaultValue')).toBe 'defaultValue'
      done()
    .fail (error) ->
      expect(error).not.toBeDefined()
