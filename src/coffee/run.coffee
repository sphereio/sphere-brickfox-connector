Q = require('q')

argv = require('optimist')
  .usage('Usage: $0 --arg1 [string] --arg2 [string]')
  .alias('arg1', 'a1')
  .alias('arg2', 'a2')
  .describe('arg1', 'Put description here.')
  .describe('arg2', 'Put description here.')
  .demand(['arg1', 'arg2'])
  .argv

Connector = require('../main').Connector

connector = new Connector
connector.run argv.arg1, argv.arg2, (success) ->
  process.exit 1 unless success