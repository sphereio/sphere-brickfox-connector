_ = require('underscore')._
program = require 'commander'
package_json = require '../package.json'
ProductImport = require './import/productimport'
ProductUpdateImport = require './import/productupdateimport'
OrderExport = require './export/orderexport'
OrderStatusImport = require './import/orderstatusimport'
{ProductImportLogger, ProductUpdateImportLogger, OrderExportLogger, OrderStatusImportLogger} = require './loggers'

# TODO: use SFTP

module.exports = class

  @run: (argv) ->
    program
      .version package_json.version
      .usage '[command] [globals] [options]'
      .option '--projectKey <project-key>', 'your SPHERE.IO project-key'
      .option '--clientId <client-id>', 'your OAuth client id for the SPHERE.IO API'
      .option '--clientSecret <client-secret>', 'your OAuth client secret for the SPHERE.IO API'
      .option '--bunyanVerbose', 'enables bunyan verbose logging output mode. Due to performance issues avoid using it in production environment'

    program
      .command 'import-products'
      .description 'Imports new and changed Brickfox products from XML into your SPHERE.IO project.'
      .option '--products <file>', 'XML file containing products to import'
      .option '--manufacturers [file]', 'XML file containing manufacturers to import'
      .option '--categories [file]', 'XML file containing categories to import'
      .option '--mapping <file>', 'JSON file containing Brickfox to SPHERE.IO mapping'
      .option '--productTypeId [id]', 'Product type ID to use for product creation. If not set first product type fetched from project will be used.'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --productTypeId [id] --mapping <file> --products <file> --manufacturers [file] --categories [file]'
      .action (opts) ->

        validateGlobalOpts(opts, 'import-products')
        validateOpt(opts.mapping, 'mapping', 'import-products')
        validateOpt(opts.products, 'products', 'import-products')

        logger = new ProductImportLogger
          src: if argv.bunyanVerbose then argv.bunyanVerbose else false

        options =
          config:
            project_key: opts.parent.projectKey
            client_id: opts.parent.clientId
            client_secret: opts.parent.clientSecret
          mapping: opts.mapping
          products: opts.products
          manufacturers: opts.manufacturers
          categories: opts.categories
          productTypeId: opts.productTypeId
          appLogger: logger
          logConfig:
            # pass logger to node-connect so that it can log into the same file
            logger: logger

        handler = new ProductImport options
        handler.execute (success) ->
          if success
            process.exit 0
          else
            process.exit 1

    program
      .command 'import-products-updates'
      .description 'Imports Brickfox product stock and price changes into your SPHERE.IO project.'
      .option '--products <file>', 'XML file containing products to import'
      .option '--mapping <file>', 'JSON file containing Brickfox to SPHERE.IO mapping'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --products <file>'
      .action (opts) ->

        validateGlobalOpts(opts, 'import-products-updates')
        validateOpt(opts.mapping, 'mapping', 'import-products-updates')
        validateOpt(opts.products, 'products', 'import-products-updates')

        logger = new ProductUpdateImportLogger
          src: if argv.bunyanVerbose then argv.bunyanVerbose else false

        options =
          config:
            project_key: opts.parent.projectKey
            client_id: opts.parent.clientId
            client_secret: opts.parent.clientSecret
          mapping: opts.mapping
          products: opts.products
          appLogger: logger
          logConfig:
            logger: logger

        handler = new ProductUpdateImport options
        handler.execute (success) ->
          if success
            process.exit 0
          else
            process.exit 1

    program
      .command 'export-orders'
      .description 'Exports new orders from your SPHERE.IO project into Brickfox XML file.'
      .option '--output <file>', 'Path to the file the exporter will write the resulting XML into'
      .option '--numberOfDays [days]', 'Retrieves orders created within the specified number of days starting with the present day. Default value is: 7', 7
      .option '--channelId <id>', 'SyncInfo (http://commercetools.de/dev/http-api-projects-orders.html#sync-info) channel id which will be updated after succesfull order export'
      .option '--mapping <file>', 'JSON file containing Brickfox to SPHERE.IO mapping'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --numberOfDays [days] --channelId <id> --mapping <file> --output <file>'
      .action (opts) ->

        validateGlobalOpts(opts, 'export-orders')
        validateOpt(opts.output, 'output', 'export-orders')
        validateOpt(opts.channelId, 'channelId', 'export-orders')
        validateOpt(opts.mapping, 'mapping', 'export-orders')

        logger = new OrderExportLogger
          src: if argv.bunyanVerbose then argv.bunyanVerbose else false

        options =
          config:
            project_key: opts.parent.projectKey
            client_id: opts.parent.clientId
            client_secret: opts.parent.clientSecret
          mapping: opts.mapping
          numberOfDays: opts.numberOfDays
          output: opts.output
          channelid: opts.channelId
          appLogger: logger
          logConfig:
            logger: logger

        handler = new OrderExport options
        handler.execute (success) ->
          if success
            process.exit 0
          else
            process.exit 1

    program
      .command 'import-orders-status'
      .description 'Imports order and order entry status changes from Brickfox into your SPHERE.IO project.'
      .option '--status <file>', 'XML file containing order status to import'
      .option '--mapping <file>', 'JSON file containing Brickfox to SPHERE.IO mapping'
      .option '--createStates', 'If set, will setup order line item states and its transitions according to mapping definition'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --status <file> --createStates'
      .action (opts) ->

        validateGlobalOpts(opts, 'import-orders-status')
        validateOpt(opts.mapping, 'mapping', 'import-orders-status')
        validateOpt(opts.status, 'status', 'import-orders-status')

        logger = new OrderStatusImportLogger
          src: if argv.bunyanVerbose then argv.bunyanVerbose else false

        options =
          config:
            project_key: opts.parent.projectKey
            client_id: opts.parent.clientId
            client_secret: opts.parent.clientSecret
          mapping: opts.mapping
          status: opts.status
          createstates: opts.createStates
          appLogger: logger
          logConfig:
            logger: logger

        handler = new OrderStatusImport options
        handler.execute (success) ->
          if success
            process.exit 0
          else
            process.exit 1

    validateOpt = (value, varName, commandName) ->
      if not value
        console.error "Missing argument '#{varName}' for command '#{commandName}'!"
        process.exit 2

    validateGlobalOpts = (opts, commandName) ->
      validateOpt(opts.parent.projectKey, 'projectKey', commandName)
      validateOpt(opts.parent.clientId, 'clientId', commandName)
      validateOpt(opts.parent.clientSecret, 'clientSecret', commandName)

    program.parse argv
    program.help() if program.args.length is 0

module.exports.run process.argv