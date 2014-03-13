_ = require('underscore')._
ProductImport = require("./import/productimport")
ProductUpdateImport = require("./import/productupdateimport")
OrderExport = require("./export/orderexport")
OrderStatusImport = require("./import/orderstatusimport")
{ProductImportLogger, ProductUpdateImportLogger} = require './loggers'

# TODO replace optimist with commander or something else that supports subcommands.
argv = require('optimist')
  .usage('Usage: $0
  --projectKey [key]
  --clientId [id]
  --clientSecret [secret]
  --action [action]
  --products [XML source path]
  --manufacturers [XML source path]
  --categories [XML source path]
  --target [XML target path]
  --productTypeId [id]
  --mapping [JSON target path] --debug')
  .describe('projectKey', 'Sphere.io project key.')
  .describe('clientId', 'Sphere.io HTTP API client id.')
  .describe('clientSecret', 'Sphere.io HTTP API client secret.')
  .describe('action', 'Action to execute. Supported actions: ip, iup, eo, ios.')
  .describe('products', 'Path to XML file with products.')
  .describe('manufacturers', 'Path to XML file with manufacturers.')
  .describe('categories', 'Path to XML file with categories.')
  .describe('target', 'Path to XML file to write to (required for exports)')
  .describe('productTypeId', 'Product type ID to use for product creation. If not set first type from list will be used.')
  .describe('mapping', 'Product import attributes mapping (Brickfox -> SPHERE) file path.')
  .describe('action ip', 'Import products from brickfox (products, manufacturers, categories and mapping parameters required)')
  .describe('action iup', 'Import updated products from brickfox (products parameter required)')
  .describe('action eo', 'Export orders to brickfox (target parameter required)')
  .describe('action ios', 'Import order status from brickfox (status parameter required)')
  .describe('debug', 'Enable verbose logging output mode. Due to performance issues avoid using it in production environment.')
  .demand(['projectKey', 'clientId', 'clientSecret', 'action'])
  .argv

debug = if argv.debug then argv.debug else false

options =
  config:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret
  mapping: argv.mapping
  products: argv.products
  manufacturers: argv.manufacturers
  categories: argv.categories
  productTypeId: argv.productTypeId
  target: argv.target
  debug: debug

handler = switch argv.action
  when "ip"
    @logger = new ProductImportLogger
      src: debug
    new ProductImport _.extend options,
      logConfig:
        # pass logger to node-connect so that it can log into the same file
        logger: @logger
      appLogger: @logger
  when "iup"
    @logger = new ProductUpdateImportLogger
      src: debug
    new ProductUpdateImport _.extend options,
      logConfig:
        logger: @logger
      appLogger: @logger
  when "eo" then new OrderExport options
  when "ios" then new OrderStatusImport options
  else
    console.log "Unsupported action type: #{argv.action}"
    process.exit 1

handler.execute (success) ->
  process.exit 1 unless success