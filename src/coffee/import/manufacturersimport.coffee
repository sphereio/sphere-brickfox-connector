Q = require 'q'
_ = require 'underscore'
SphereClient = require 'sphere-node-client'
utils = require '../../lib/utils'



###
Imports Brickfox manufacturers provided as XML into SPHERE.IO
###
class ManufacturersImport

  constructor: (@_options = {}) ->
    @client = new SphereClient @_options
    @client.setMaxParallel(100)
    @logger = @_options.appLogger
    @success = false
    @manufacturersCreated = 0


  execute: (manufacturersXML, mappings) ->
    @startTime = new Date().getTime()
    @client.productTypes.perPage(0).fetch()
    .then (fetchedProductTypesResult) =>
      productType = utils.getProductTypeByConfig(fetchedProductTypesResult.body.results, mappings.productImport.productTypeId, @_options.config.project_key)
      @updateActions = @_buildManufacturers(manufacturersXML, productType, mappings.productImport.mapping) if manufacturersXML
      @client.productTypes.byId(productType.id).update({version: productType.version, actions: @updateActions}) if @updateActions
    .then (productTypeUpdateResult) =>
      @manufacturersCreated = _.size(@updateActions)
      @success = true

  outputSummary: ->
    endTime = new Date().getTime()
    result = if @success then 'SUCCESS' else 'ERROR'
    @logger.info """[Manufacturers] Import result: #{result}.
                    [Manufacturers] Manufacturers created: #{@manufacturersCreated}
                    [Manufacturers] Processing time: #{(endTime - @startTime) / 1000} seconds."""

  ###
  # If manufacturers mapping is defined builds an array of update actions for mapped product type attribute
  #
  # @param {Object} data Data to get manufacturers information from
  # @param {Object} productType Product type with existing manufacturer values
  # @param {Object} mappings Product import attribute mappings
  # @return {Array} List of product type update actions
  ###
  _buildManufacturers: (data, productType, mappings) ->
    @logger.info '[Manufacturers] Manufacturers XML import started...'

    if not mappings.ManufacturerId
      @logger.info '[Manufacturers] Mapping for ManufacturerId is not defined. No manufacturers will be created.'
      return

    count = _.size(data.Manufacturers?.Manufacturer)
    if count
      @logger.info "[Manufacturers] Import manufacturers found: '#{count}'"
    else
      @logger.info '[Manufacturers] No manufacturers to import found or undefined. Please check manufacturers input XML.'
      return

    attributeName = mappings.ManufacturerId.to
    # find attribute on product type
    matchedAttr = _.find productType.attributes, (value) -> value.name is attributeName
    if not matchedAttr
      throw new Error "Error on manufacturers import. ManufacturerId mapping attributeName: '#{attributeName}' could not be found on product type with id: '#{productType.id}'"

    actions = []
    # extract only keys from product type attribute values
    keys = _.pluck(matchedAttr.type.values, 'key')
    _.each data.Manufacturers.Manufacturer, (m) ->
      key = m.ManufacturerId[0]
      exists = _.contains(keys,  key)
      if not exists
        # attribute value does not exist yet -> create new addLocalizedEnumValue action
        value = utils.getLocalizedValues(m.Translations[0], 'Name')
        action =
          action: 'addLocalizedEnumValue'
          attributeName: attributeName
          value:
            key: key
            label: value
        actions.push action

    if _.size(actions) > 0
      @logger.info "[Manufacturers] Update actions to send for attribute '#{attributeName}': '#{_.size actions}'"
      actions
    else
      @logger.info "[Manufacturers] No update action for manufacturers attribute '#{attributeName}' required."
      null

module.exports = ManufacturersImport
