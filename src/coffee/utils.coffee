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
      deferred.reject "Can not read file '#{file}'; #{error}"
    else
      deferred.resolve result
  deferred.promise

exports.writeFile = (file, content) ->
  deferred = Q.defer()
  fs.writeFile file, content, (error, result) ->
    if error
      deferred.reject "Can not write file '#{file}'; #{error}"
    else
      deferred.resolve "OK"
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

###
# Executes in parallel defined number of asynchronous promise requests.
#
# @param {Array} list List of promise requests to fire
# @param {Array} numberOfParallelRequest Number of requests to be fired in parallel
# @return {Boolean} Returns true if all promises could be successfully resolved
###
exports.batch = (list, numberOfParallelRequest) ->
  deferred = Q.defer()
  doBatch = (list, numberOfParallelRequest) ->
    current = _.take list, numberOfParallelRequest
    Q.all(current)
    .then (result) ->
      if _.size(current) < numberOfParallelRequest
        deferred.resolve result
      else
        doBatch _.tail(list, numberOfParallelRequest), numberOfParallelRequest
    .fail (error) ->
      deferred.reject error
   doBatch(list, numberOfParallelRequest)
   deferred.promise

###
# Returns localized values for all detected languages.
#
# @param {Object} mainNode Main XML node to get Localizations from
# @param {String} name Element name to localize
# @return {Object} Localized values
###
exports.getLocalizedValues = (mainNode, name) =>
  localized = {}
  _.each mainNode, (item) =>
    _.each item, (val, index, list) =>
      lang = list[index]['$'].lang
      value = @xmlVal(list[index], name)
      localized[lang] = value
  localized

###
# Returns slugified values for given localized parameter values.
#
# @param {Object} mainNode Main XML node to get Localizations from
# @return {Object} Localized slugs
###
exports.generateLocalizedSlugs = (names) =>
  slugs = {}
  _.each names, (value, key, list) =>
    slug = @generateSlug(value)
    slugs[key] = slug
  slugs

###
# Asserts for existence of required Brickfox ProductId mapping
#
# @param {Object} mappings Object with attribute mappings
# @throws {Error} If no mapping for Brickfox field 'ProductId' is defined
###
exports.assertProductIdMappingIsDefined = (mappings) ->
  if not mappings.ProductId?.to
    throw new Error "No Brickfox to SPHERE 'ProductId' attribute mapping found. ProductId is required in order to map Brickfox product updates to existing SPHERE products."

###
# Asserts for existence of required Brickfox VariationId mapping
#
# @param {Object} mappings Object with attribute mappings
# @throws {Error} If no mapping for Brickfox field 'VariationId' is defined
###
exports.assertVariationIdMappingIsDefined = (mappings) ->
  if not mappings.VariationId?.to
    throw new Error "No Brickfox to SPHERE 'VariationId' attribute mapping found. VariationId is required in order to export Sphere orders to Brickfox."

###
# Asserts SPHERE SKU field mapping is defined
#
# @param {Object} mappings Object with attribute mappings
# @throws {Error} If no mapping for SPHERE field 'sku' is defined
###
exports.assertSkuMappingIsDefined = (mappings) ->
  brickfoxSkuFieldName = _.find mappings, (mapping) -> mapping.to is 'sku'
  if not brickfoxSkuFieldName
    throw new Error "Error on product update / import. SPHERE 'sku' attribute mapping could not be found."

exports.getVariantAttValue = (mappings, name, variant) ->
  value
  mapping = mappings[name]
  mappedTo = mapping.to
  if mapping.isCustom
    att = _.find variant.attributes, (att) -> att.name is mappedTo
    value = att.value
  else
    value = variant[mappedTo]

  if not value
    throw new Error "Variant with sku: '#{variant.sku}' does not define required attribute value for Brickfox field name: '#{name}'. Make sure you defined mapping for this field."
  else
    value

exports.buildRemovePriceAction = (price, variantId) ->
  action =
    action: 'removePrice'
    variantId: variantId
    price: price

exports.buildAddPriceAction = (price, variantId) ->
  action =
    action: 'addPrice'
    variantId: variantId
    price: price

