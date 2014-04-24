fs = require 'fs'
Q = require 'q'
_ = require 'lodash-node'
_s = require 'underscore.string'
{parseString} = require 'xml2js'

exports.xmlVal = (elem, attribName, fallback) ->
  return elem[attribName][0] if elem[attribName]
  fallback

exports.generateSlug = (name) ->
  # TODO use some random number too
  timestamp = new Date().getTime()
  randomInt = @getRandomInt(100000000, 10000000000)
  _s.slugify(name).concat("-#{timestamp}-#{randomInt}")

###
Returns a random integer between min and max
Using Math.round() will give you a non-uniform distribution!

@param {Integer} min integer value
@throws {Integer} max integer value
@return {Integer} generated integer value
###
exports.getRandomInt = (min, max) ->
  Math.floor(Math.random() * (max - min + 1)) + min

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
      deferred.resolve 'CREATED'
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

exports.xmlToJsonFromPath = (path) ->
  @readFile(path)
  .then (fileContent) =>
    @parseXML(fileContent)

exports.readJsonFromPath = (path) ->
  @readFile(path)
  .then (fileContent) ->
    Q(JSON.parse(fileContent))

exports.pretty = (data) ->
  JSON.stringify data, null, 4

###
Executes in parallel defined number of asynchronous promise requests.

@param {Array} list List of promise requests to fire
@param {Array} numberOfParallelRequest Number of requests to be fired in parallel
@return {Boolean} Returns true if all promises could be successfully resolved
###
exports.batch = (list, numberOfParallelRequest = 100) ->
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
Creates promise for each list element and fires each promise sequentially.

@param {Object} rest SPHERE.IO API client to use
@param {Object} createPromise Function reference to use for promise creation
@param {Array} data Date used for promise creation
@param {Integer} index Index of the date to start with (default: 0)
@return {Array} Promise results to write into
###
exports.batchSeq = (rest, createPromise, data, index = 0, allResult = [], percent = 0) =>
  createPromise(rest, data[index])
  .then (result) =>
    dataSize = _.size(data)
    newIndex = index + 1
    donePercent = _s.numberFormat((newIndex * 100) / dataSize)
    if (donePercent - percent) >= 1
      console.log "Processed #{newIndex} out of #{dataSize}. Done: #{donePercent}%"
    newResult = allResult.concat result
    if (newIndex) < dataSize
      @batchSeq(rest, createPromise, data, newIndex, newResult, donePercent)
    else
      Q(newResult)

###
Returns localized values for all detected languages.

@param {Object} mainNode Main XML node to get Localizations from
@param {String} name Element name to localize
@return {Object} Localized values
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
Returns slugified values for given localized parameter values.

@param {Object} mainNode Main XML node to get Localizations from
@return {Object} Localized slugs
###
exports.generateLocalizedSlugs = (names) =>
  slugs = {}
  _.each names, (value, key, list) =>
    slug = @generateSlug(value)
    slugs[key] = slug
  slugs

###
Asserts for existence of required Brickfox ProductId mapping

@param {Object} mappings Object with attribute mappings
@throws {Error} If no mapping for Brickfox field 'ProductId' is defined
###
exports.assertProductIdMappingIsDefined = (mappings) ->
  if not mappings.ProductId?.to
    throw new Error "No Brickfox to SPHERE 'ProductId' attribute mapping found. ProductId is required in order to map Brickfox product updates to existing SPHERE products."

###
Asserts for existence of required Brickfox VariationId mapping

@param {Object} mappings Object with attribute mappings
@throws {Error} If no mapping for Brickfox field 'VariationId' is defined
###
exports.assertVariationIdMappingIsDefined = (mappings) ->
  if not mappings.VariationId?.to
    throw new Error "No Brickfox to SPHERE 'VariationId' attribute mapping found. VariationId is required in order to export Sphere orders to Brickfox."

###
Asserts SPHERE SKU field mapping is defined

@param {Object} mappings Object with attribute mappings
@throws {Error} If no mapping for SPHERE field 'sku' is defined
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

###
Transforms a list of categories into a new object (map alike) using external category id as abject property key and category as value.

@param {Array} categories List of existing categories
@throws {Error} If category external id is not defined
@return {Array} List of of transformed categories
###
exports.transformByCategoryExternalId = (categories) ->
  map = {}
  _.each categories, (c) ->
    # TODO: do not use slug as external category id (required Sphere support of custom attributes on category first)
    externalId = c.slug.nl
    throw new Error "[Categories] Slug for language 'nl' (workaround: used as 'externalId') in MC is empty; Category id: '#{c.id}'" if not externalId
    map[externalId] = c
  map

###
Returns category object with given external/Brickfox id. If category with requested external id was not found
an error is thrown as this id is used as common identifier for synchronization between Brickfox and Sphere categories.

@param {Array} fetchedCategories List of existing categories
@throws {Error} If category external id is not defined
@return {Array} List of of transformed categories
###
exports.getCategoryByExternalId = (id, categories) ->
  category = categories[id]
  throw new Error "Unexpected error. Category with externalId: '#{id}' not found." if not category
  category

###
Returns product type. If 'productTypeId' is provided by configuration,
product type with given id is returned otherwise first element from the product
type list is returned.

@param {Array} productTypes List of product types
@param {String} id Product type ID
@param {String} projectKey SPHERE.IO project key
@throws {Error} If no product types were found or product type for given product type id was not found
@return {Object} Product type
###
exports.getProductTypeByConfig = (productTypes, id, projectKey) ->
  if _.size(productTypes) == 0
    throw new Error "No product type defined for SPHERE project '#{projectKey}'. Please create one before running product import."

  productType = null
  if id
    productType = _.find productTypes, (type) ->
      type.id is id
    if not productType
      throw new Error "SPHERE project '#{projectKey}' does not contain product type with id: '#{id}'"
  else
    # take first available product type from the list
    productType = productTypes[0]
  productType