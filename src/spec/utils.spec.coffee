utils = require '../lib/utils.js'

describe "#parseXML", ->
  it "works", ->
    xml = "<root><row><id>1</id></row><row><id>2</id></row></root>"
    utils.parseXML xml, (error, result) ->
      expect(error).toBeNull()
      e =
        root:
          row: [
            { id: [ '1' ] }
            { id: [ '2' ] }
          ]
      expect(result).toEqual e

  it "gives feedback on xml error", ->
    xml = "<root><root>"
    utils.parseXML xml, (error, result) ->
      expect(error).toMatch /Error/

describe "#xmlVal", ->
  it "works", ->
    xml = "<root><row><code>foo</code>123</row></root>"
    utils.parseXML xml, (error, result) ->
      expect(utils.xmlVal(result.root.row[0], 'code')).toBe 'foo'
      expect(utils.xmlVal(result.root.row[0], 'foo', 'defaultValue')).toBe 'defaultValue'