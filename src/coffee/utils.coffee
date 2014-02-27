fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'
{parseString} = require 'xml2js'

exports.xmlVal = (elem, attribName, fallback) ->
  return elem[attribName][0] if elem[attribName]
  fallback

exports.generateSlug = (name) ->
  # TODO use some random number too
  timestamp = new Date().getTime()
  _s.slugify(name).concat("-#{timestamp}").substring(0, 256)

exports.readFile = (file) ->
  deferred = Q.defer()
  fs.readFile file, 'utf8', (error, result) ->
    if error
      message = "Can not read file '#{file}'; #{error}"
      deferred.reject message
    else
      deferred.resolve result
  deferred.promise

exports.loadOptionalResource = (path) =>
  if path
    @readFile path
  else
    Q.fcall (val) ->
      null

exports.parseXML = (content) ->
  deferred = Q.defer()
  parseString content, (error, result) ->
    if error
      message = "Can not parse XML content; #{error}"
      deferred.reject message
    else
      deferred.resolve result
  deferred.promise

exports.xmlToJson = (path) =>
  @readFile(path)
  .then (fileContent) =>
    @parseXML(fileContent)

exports.pretty = (data) ->
  JSON.stringify data, null, 4
