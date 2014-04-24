Q = require 'q'
fs = require 'q-io/fs'
_ = require 'lodash-node'
program = require 'commander'
tmp = require 'tmp'
{Sftp, ProjectCredentialsConfig, _u, Qutils} = require 'sphere-node-utils'
package_json = require '../package.json'
CategoryImport = require './import/categoryimport'
ManufacturersImport = require './import/manufacturersimport'
ProductImport = require './import/productimport'
ProductUpdateImport = require './import/productupdateimport'
OrderExport = require './export/orderexport'
OrderStatusImport = require './import/orderstatusimport'
utils = require './utils'
cons = require './constants'
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
      .option '--mapping <file>', 'JSON file containing Brickfox to SPHERE.IO mappings'
      .option '--config [file]', 'Path to configuration file with data like SFTP credentials and its working folders'
      .option '--bunyanVerbose', 'enables bunyan verbose logging output mode. Due to performance issues avoid using it in production environment'

    program
      .command cons.CMD_IMPORT_PRODUCTS
      .description 'Imports new and changed Brickfox products from XML into your SPHERE.IO project.'
      .option '--products <file>', 'XML file containing products to import'
      .option '--manufacturers [file]', 'XML file containing manufacturers to import'
      .option '--categories [file]', 'XML file containing categories to import'
      .option '--safeCreate', 'If defined, importer will check for product existence (by ProductId attribute mapping) in SPHERE.IO before sending create new product request'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --products <file> --manufacturers [file] --categories [file]'
      .action (opts) ->

        logger = new ProductImportLogger
          src: if argv.bunyanVerbose then argv.bunyanVerbose else false

        if opts.parent.config # use SFTP to load import/export files
          validateOpt(opts.parent.mapping, 'mapping', cons.CMD_IMPORT_PRODUCTS)
          loadResources(opts, logger)
          .then (resources) ->
            resources.options.safeCreate = opts.safeCreate
            importer = new CategoryImport resources.options
            processSftpImport(resources, importer, 'categories')
            .then (result) ->
              importer = new ManufacturersImport resources.options
              processSftpImport(resources, importer, 'manufacturers')
            .then (result) ->
              importer = new ProductImport resources.options
              processSftpImport(resources, importer, 'products')
          .then ->
            process.exit(0)
          .fail (error) ->
            logger.error error, 'Oops, something went wrong!'
            process.exit(1)
        else # use command line arguments to load import/export files
          validateGlobalOpts(opts, cons.CMD_IMPORT_PRODUCTS)
          validateOpt(opts.products, 'products', cons.CMD_IMPORT_PRODUCTS)

          options = createBaseOptions(opts, logger)
          options.safeCreate = opts.safeCreate
          mapping = null

          utils.readJsonFromPath(opts.parent.mapping)
          .then (mappingResult) ->
            mapping = mappingResult
            if opts.categories
              importer = new CategoryImport options
              importFn(importer, opts.categories, mapping, logger)
          .then (result) ->
            if opts.manufacturers
              importer = new ManufacturersImport options
              importFn(importer, opts.manufacturers, mapping, logger)
          .then (result) ->
            importer = new ProductImport options
            importFn(importer, opts.products, mapping, logger)
          .then ->
            process.exit(0)
          .fail (error) ->
            logger.error error, 'Oops, something went wrong!'
            process.exit(1)

    program
      .command cons.CMD_IMPORT_PRODUCTS_UPDATES
      .description 'Imports Brickfox product stock and price changes into your SPHERE.IO project.'
      .option '--products <file>', 'XML file containing products to import'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --products <file>'
      .action (opts) ->

        logger = new ProductUpdateImportLogger
          src: if argv.bunyanVerbose then argv.bunyanVerbose else false

        if opts.parent.config # use SFTP to load import/export files
          validateOpt(opts.parent.mapping, 'mapping', cons.CMD_IMPORT_PRODUCTS_UPDATES)
          loadResources(opts, logger)
          .then (resources) ->
            importer = new ProductUpdateImport resources.options
            processSftpImport(resources, importer, 'productUpdates')
          .then ->
            process.exit(0)
          .fail (error) ->
            logger.error error, 'Oops, something went wrong!'
            process.exit(1)
        else # use command line arguments to load import/export files
          validateGlobalOpts(opts, cons.CMD_IMPORT_PRODUCTS_UPDATES)
          validateOpt(opts.products, 'products', cons.CMD_IMPORT_PRODUCTS_UPDATES)

          options = createBaseOptions(opts, logger)

          utils.readJsonFromPath(opts.parent.mapping)
          .then (mapping) ->
            importer = new ProductUpdateImport options
            importFn(importer, opts.products, mapping, logger)
          .then ->
            process.exit(0)
          .fail (error) ->
            logger.error error, 'Oops, something went wrong!'
            process.exit(1)

    program
      .command cons.CMD_EXPORT_ORDERS
      .description 'Exports new orders from your SPHERE.IO project into Brickfox XML file.'
      .option '--target <file>', 'Path to the file the exporter will write the resulting XML into'
      .option '--numberOfDays [days]', 'Retrieves orders created within the specified number of days starting with the present day. Default value is: 7'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --numberOfDays [days] --mapping <file> --config [file] --target <file>'
      .action (opts) ->

        logger = new OrderExportLogger
          src: if argv.bunyanVerbose then argv.bunyanVerbose else false

        if opts.parent.config # use SFTP to load import/export files
          validateOpt(opts.parent.mapping, 'mapping', cons.CMD_EXPORT_ORDERS)
          loadResources(opts, logger)
          .then (resources) ->
            resources.options.numberOfDays = opts.numberOfDays
            exporter = new OrderExport resources.options
            processSftpExport(resources, exporter, 'orders')
          .then ->
            process.exit(0)
          .fail (error) ->
            logger.error error, 'Oops, something went wrong!'
            process.exit(1)
        else # use command line arguments to load import/export files
          validateGlobalOpts(opts, cons.CMD_EXPORT_ORDERS)
          validateOpt(opts.target, 'target', cons.CMD_EXPORT_ORDERS)

          options = createBaseOptions(opts, logger)
          options.numberOfDays = opts.numberOfDays

          utils.readJsonFromPath(opts.parent.mapping)
          .then (mapping) ->
            exporter = new OrderExport options
            exportFn(exporter, opts.target, mapping)
            .then (exportResult) ->
              exporter.doPostProcessing(exportResult)
            .then ->
              exporter.outputSummary()
              process.exit(0)
            .fail (error) ->
              exporter.outputSummary()
              logger.error error, 'Oops, something went wrong!'
              process.exit(1)
          .fail (error) ->
            logger.error error, 'Oops, something went wrong!'
            process.exit(1)

    program
      .command cons.CMD_IMPORT_ORDERS_STATUS
      .description 'Imports order and order entry status changes from Brickfox into your SPHERE.IO project.'
      .option '--status <file>', 'XML file containing order status to import'
      .option '--createStates', 'If set, will setup order line item states and its transitions according to mapping definition'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --status <file> --createStates'
      .action (opts) ->

        logger = new OrderStatusImportLogger
          src: if argv.bunyanVerbose then argv.bunyanVerbose else false

        if opts.parent.config # use SFTP to load import/export files
          validateOpt(opts.parent.mapping, 'mapping', cons.CMD_IMPORT_ORDERS_STATUS)
          loadResources(opts, logger)
          .then (resources) ->
            resources.options.createstates = opts.createStates
            importer = new OrderStatusImport resources.options
            processSftpImport(resources, importer, 'orderStatus')
          .then ->
            process.exit(0)
          .fail (error) ->
            logger.error error, 'Oops, something went wrong!'
            process.exit(1)
        else # use command line arguments to load import/export files
          validateGlobalOpts(opts, cons.CMD_IMPORT_ORDERS_STATUS)
          validateOpt(opts.status, 'status', cons.CMD_IMPORT_ORDERS_STATUS)

          options = createBaseOptions(opts, logger)
          options.createstates = opts.createStates

          utils.readJsonFromPath(opts.parent.mapping)
          .then (mapping) ->
            importer = new OrderStatusImport options
            importFn(importer, opts.status, mapping, logger)
          .then ->
            process.exit(0)
          .fail (error) ->
            logger.error error, 'Oops, something went wrong!'
            process.exit(1)

    validateOpt = (value, varName, commandName) ->
      if not value
        console.error "Missing required argument '#{varName}' for command '#{commandName}'!"
        process.exit 2

    validateGlobalOpts = (opts, commandName) ->
      validateOpt(opts.parent.projectKey, 'projectKey', commandName)
      validateOpt(opts.parent.clientId, 'clientId', commandName)
      validateOpt(opts.parent.clientSecret, 'clientSecret', commandName)
      validateOpt(opts.parent.mapping, 'mapping', commandName)

    initSftp = (host, username, password, logger) ->
      options =
        host: host
        username: username
        password: password
        logger: logger

      sftp = new Sftp options

    ###
    Simple temporary directory creation, it will be removed on process exit.
    ###
    createTmpDir = ->
      d = Q.defer()
      # unsafeCleanup: recursively removes the created temporary directory, even when it's not empty
      tmp.dir {unsafeCleanup: true}, (err, path) ->
        if err
          d.reject err
        else
          d.resolve path
      d.promise

    createBaseOptions = (opts, logger) ->
      options =
        config:
          project_key: opts.parent.projectKey
          client_id: opts.parent.clientId
          client_secret: opts.parent.clientSecret
        appLogger: logger
        logConfig:
          # pass logger to node-connect so that it can log into the same file
          logger: logger

    loadResources = (opts, logger) ->
      resources = {}
      ProjectCredentialsConfig.create()
      .then (credentialsResult) ->
        resources.options =
          config: credentialsResult.enrichCredentials
            project_key: opts.parent.projectKey
            client_id: opts.parent.clientId
            client_secret: opts.parent.clientSecret
          appLogger: logger
          logConfig:
            # pass logger to node-connect so that it can log into the same file
            logger: logger
        utils.readJsonFromPath(opts.parent.config)
      .then (configResult) ->
        resources.config = configResult
        utils.readJsonFromPath(opts.parent.mapping)
      .then (mappingResult) ->
        resources.mapping = mappingResult
        resources.sftpClient = initSftp(resources.config.sftp_host, resources.config.sftp_user, resources.config.sftp_password, logger)
        Q(resources)

    processSftpImport = (resources, importer, code) ->
      {options, config, mapping, tmpPath, sftpClient} = resources
      logger = options.appLogger
      tmp.setGracefulCleanup()
      createTmpDir()
      .then (tmpPathResult) ->
        tmpPath = tmpPathResult
        logger.debug "Tmp folder for '#{code}' import/export files created at: '#{tmpPath}'"
        sftpClient.openSftp()
      .then (sftp) ->
        sourceFolder = config.sftp_directories.import[code].source
        fileRegex = config.sftp_directories.import[code].fileRegex
        logger.info "Check for new '#{code}' in: '#{sourceFolder}'"
        sftpClient.downloadAllFiles(sftp, tmpPath, sourceFolder, fileRegex)
        .then ->
          sftpClient.close(sftp)
        .fail (error) ->
          sftpClient.close(sftp)
          Q.reject error
      .then ->
        fs.list(tmpPath)
      .then (files) ->
        if _.size(files) > 0
          sortedFiles = files.sort()
          logger.info sortedFiles, "Processing #{files.length} file(s)..."
          Qutils.processList sortedFiles, (fileName) ->
            importFn(importer, "#{tmpPath}/#{fileName}", mapping, logger)
            .then (result) ->
              sftpClient.openSftp()
              .then (sftp) ->
                sourceFolder = config.sftp_directories.import[code].source
                targetFolder = config.sftp_directories.import[code].processed
                logger.info "Move processed file: '#{fileName}' from: '#{sourceFolder}' to: '#{targetFolder}'"
                sftpClient.safeRenameFile(sftp, "#{sourceFolder}/#{fileName}", "#{targetFolder}/#{fileName}")
                .then (renameResult) ->
                  sftpClient.close(sftp)
                  Q()
                .fail (error) ->
                  sftpClient.close(sftp)
                  Q.reject error
        else
          logger.info "No new '#{code}' import/export files available."
          Q()

    importFn = (importer, fileName, mapping, logger) ->
      throw new Error 'You must provide importer function to be processed' unless importer
      throw new Error 'You must provide import fileName to be processed' unless fileName
      throw new Error 'You must provide logger to be processed' unless logger
      d = Q.defer()
      logger.info "About to process file #{fileName}"
      utils.xmlToJsonFromPath(fileName)
      .then (content) ->
        importer.execute(content, mapping)
        .then (result) ->
          importer.outputSummary()
          d.resolve(result)
        .fail (error) ->
          logger.error "Error on processing file: #{fileName}"
          importer.outputSummary()
          d.reject error
      .fail (error) ->
        logger.error "Cannot read file: #{fileName}"
        d.reject error
      d.promise

    processSftpExport = (resources, exporter, code) ->
      {options, config, mapping, tmpPath, sftpClient} = resources
      logger = options.appLogger
      tmp.setGracefulCleanup()
      createTmpDir()
      .then (tmpPathResult) ->
        tmpPath = tmpPathResult
        exportFn(exporter, tmpPath, mapping)
      .then (exportResult) ->
        fs.list(tmpPath)
        .then (files) ->
          if _.size(files) > 0
            sftpClient.openSftp()
            .then (sftp) ->
              targetFolder = config.sftp_directories.export[code].target
              Qutils.processList files, (fileName) ->
                logger.info "Uploading: '#{fileName}' to SFTP target: '#{targetFolder}'"
                sftpClient.safePutFile(sftp, "#{tmpPath}/#{fileName}", "#{targetFolder}/#{fileName}")
              .then ->
                exporter.doPostProcessing(exportResult)
              .then ->
                exporter.outputSummary()
                logger.info "Successfully uploaded #{_.size files} file(s)"
                sftpClient.close(sftp)
                Q()
              .fail (error) ->
                sftpClient.close(sftp)
                Q.reject error
          else
            exporter.outputSummary()

    exportFn = (exporter, targetPath, mapping) ->
      throw new Error 'You must provide exporter function to be processed' unless exporter
      throw new Error 'You must provide export targetPath to be processed' unless targetPath
      d = Q.defer()
      exporter.execute(mapping, targetPath)
      .then (result) ->
        d.resolve(result)
      .fail (error) ->
        exporter.outputSummary()
        d.reject error
      d.promise

    # parse and process command line arguments
    program.parse argv
    program.help() if program.args.length is 0

module.exports.run process.argv