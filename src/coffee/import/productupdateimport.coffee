fs = require 'fs'
Q = require 'q'
_ = require('underscore')._
_s = require 'underscore.string'

###
TODO: Add class description/comment.
###
class ProductUpdateImport

  constructor: (@_options = {}) ->
    this

  ###
  TODO: Add method description/comment.
  @param {function} callback The callback function to be invoked when the method finished its work.
  @return Result of the given callback
  ###
  execute: (callback) ->
    console.log "ProductUpdateImport executed..."
    callback true

module.exports = ProductUpdateImport.execute
