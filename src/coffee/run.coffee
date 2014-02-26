argv = require('optimist')
  .usage('Usage: $0 --projectKey [key] --clientId [id] --clientSecret [secret]
  --action [action] --source [XML source path] --target [XML target path]
  --productTypeId [id] --mapping [JSON target path]')
  .alias('projectKey', 'pk')
  .alias('clientId', 'ci')
  .alias('clientSecret', 'cs')
  .alias('action', 'a')
  .alias('source', 's')
  .alias('target', 't')
  .alias('productTypeId', 'pt')
  .describe('projectKey', 'Sphere.io project key.')
  .describe('clientId', 'Sphere.io HTTP API client id.')
  .describe('clientSecret', 'Sphere.io HTTP API client secret.')
  .describe('action', 'Action to execute. Supported actions: ip, iup, eo, ios')
  .describe('source', 'Path to XML file to read from (required for imports)')
  .describe('target', 'Path to XML file to write to (required for exports)')
  .describe('productTypeId', 'Product type ID to use for product creation. If not set first type from list will be used.')
  .describe('mapping', 'Product import attributes mapping (Brickfox -> SPHERE) file path.')
  .describe('action ip', 'Import products from brickfox (source, mapping parameters required)')
  .describe('action iup', 'Import updated products from brickfox (source parameter required)')
  .describe('action eo', 'Export orders to brickfox (target parameter required)')
  .describe('action ios', 'Import order status from brickfox (source parameter required)')
  .demand(['projectKey', 'clientId', 'clientSecret', 'action', 'mapping'])
  .argv

ProductImport = require("./import/productimport")
ProductUpdateImport = require("./import/productupdateimport")
OrderExport = require("./export/orderexport")
OrderStatusImport = require("./import/orderstatusimport")

options =
  config:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret
  source: argv.source
  target: argv.target
  productTypeId: argv.productTypeId
  mapping: argv.mapping
  logConfig: {
    levelStream: 'warn' # log level for stdout stream
    levelFile: 'info' # log level for file stream
    path: './sphere-brickfox-connect.log' # where to write the file stream
    name: 'sphere-brickfox-connect' # name of the application
    src: false # includes a log of the call source location (file, line, function).
               # Determining the source call is slow, therefor it's recommended not to enable this on production.
    streams: [ # a list of streams that defines the type of output for log messages
      {level: 'warn', stream: process.stdout}
      {level: 'info', path: './sphere-brickfox-connect.log'}
    ]
  }


handler = switch argv.action
  when "ip" then new ProductImport options
  when "iup" then new ProductUpdateImport options
  when "eo" then new OrderExport options
  when "ios" then new OrderStatusImport options
  else
    console.log "Unsupported action type: #{argv.action}"
    process.exit 1

startTime = new Date().getTime()

handler.execute (success) ->
  endTime = new Date().getTime()
  console.log "#{handler.successCounter} product(s) out of #{handler.toBeImported} imported. #{handler.failCounter} failed. Processing time: #{(endTime - startTime) / 1000} seconds."
  process.exit 1 unless success