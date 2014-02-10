argv = require('optimist')
  .usage('Usage: $0 --projectKey [key] --clientId [id] --clientSecret [secret] --action [action] --source [source-XML-path] --target [target-XML-path]')
  .alias('projectKey', 'pk')
  .alias('clientId', 'ci')
  .alias('clientSecret', 'cs')
  .alias('action', 'a')
  .alias('source', 's')
  .alias('target', 't')
  .describe('projectKey', 'Sphere.io project key.')
  .describe('clientId', 'Sphere.io HTTP API client id.')
  .describe('clientSecret', 'Sphere.io HTTP API client secret.')
  .describe('action', 'Action to execute. Supported actions: ip, iup, eo, ios')
  .describe('source', 'Path to XML file to read from.')
  .describe('target', 'Path to XML file to write to.')
  .describe('action ip', 'Import products from brickfox (source parameter required)')
  .describe('action iup', 'Import updated products from brickfox (source parameter required)')
  .describe('action eo', 'Export orders to brickfox (target parameter required)')
  .describe('action ios', 'Import order status from brickfox (source parameter required)')
  .demand(['projectKey', 'clientId', 'clientSecret', 'action'])
  .argv

Connector = require('../main').Connector
ProductImport = require("./productimport")
ProductUpdateImport = require("./productupdateimport")
OrderExport = require("./orderexport")
OrderStatusImport = require("./orderstatusimport")

options =
  config:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret
  source: argv.source
  target: argv.target


handler = switch argv.action
  when "ip" then new ProductImport options
  when "iup" then new ProductUpdateImport options
  when "eo" then new OrderExport options
  when "ios" then new OrderStatusImport options
  else
    console.log "Unsupported action type: #{argv.action}"
    process.exit 1

handler.execute (success) ->
  process.exit 1 unless success