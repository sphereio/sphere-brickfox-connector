fs = require 'fs'
Q = require 'q'
_ = require("underscore")._
_s = require('underscore.string')

###
TODO: Add class description/comment.
###
class Connector


  ###
  TODO: Add method description/comment.
  @param {string} arg1 Entire types CSV as an array of records.
  @param {string} arg2 Entire attributes CSV as an array of records.
  @param {function} callback The callback function to be invoked when the method finished its work.
  @return Result of the given callback
  ###
  run: (arg1, arg2, callback) ->
    callback true

module.exports = Connector
