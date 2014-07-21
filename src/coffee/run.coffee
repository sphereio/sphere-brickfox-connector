nutil = require 'util'
Q = require 'q'
fs = require 'q-io/fs'
_ = require 'lodash-node'
program = require 'commander'
tmp = require 'tmp'
{ExtendedLogger, Sftp, ProjectCredentialsConfig, _u, Qutils} = require 'sphere-node-utils'
package_json = require '../package.json'
Categories = require './import/categories'
Manufacturers = require './import/manufacturers'
Products = require './import/products'
ProductUpdates = require './import/productupdates'
Orders = require './export/orders'
OrderStatus = require './import/orderstatus'
utils = require './utils'
CONS = require './constants'



module.exports = class

  # workaround to make sure that all open logger streams(i.e.: bunyan) are flushed properly before node terminates
  @_exitCode = null
  @_setExitCode: (code) -> @_exitCode = code

  process.on 'exit', =>
    process.exit(@_exitCode)

  # curiously with process.on 'exit' above node does not throw errors / stack traces anymore
  process.on 'uncaughtException', (error) ->
    if error.stack
      console.error error.stack
    else
      console.error error

  @run: (argv) ->

    program
      .version package_json.version
      .usage '[command] [globals] [options]'
      .option '--projectKey <project-key>', 'your SPHERE.IO project-key. Optional if SFTP id used'
      .option '--clientId <client-id>', 'your OAuth client id for the SPHERE.IO API. Optional if SFTP id used'
      .option '--clientSecret <client-secret>', 'your OAuth client secret for the SPHERE.IO API. Optional if SFTP id used'
      .option '--mapping <file>', 'JSON file containing Brickfox to SPHERE.IO mappings'
      .option '--sftpCredentials [file]', 'the path to a JSON file where to read the credentials from'
      .option '--sftpHost', 'the SFTP host (will be used if sftpCredentials JSON is not given)'
      .option '--sftpUsername', 'the SFTP username (will be used if sftpCredentials JSON is not given)'
      .option '--sftpPassword', 'the SFTP password (will be used if sftpCredentials JSON is not given)'
      .option '--config [file]', 'the path to a JSON file where to read the configuration from (not optional if any of --sftp* arguments is used)'
      .option '--sphereHost [host]', 'SPHERE.IO API host to connecto to'
      .option '--logLevel [level]', 'specifies log level (error|warn|info|debug|trace) [info]', 'info'
      .option '--logDir [directory]', 'specifies log file directory [.]', '.'
      .option '--bunyanVerbose', 'enables bunyan verbose logging output mode. Due to performance issues avoid using it in production environment'

    program
      .command CONS.CMD_IMPORT_PRODUCTS
      .description 'Imports new and changed Brickfox products from XML into your SPHERE.IO project.'
      .option '--products <file>', 'XML file containing products to import'
      .option '--manufacturers [file]', 'XML file containing manufacturers to import'
      .option '--categories [file]', 'XML file containing categories to import'
      .option '--safeCreate', 'If defined, importer will check for product existence (by ProductId attribute mapping) in SPHERE.IO before sending create new product request'
      .option '--continueOnProblems', 'When a product does not validate on the server side (400er response), ignore it and continue with the next products'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --products <file> --manufacturers [file] --categories [file]'
      .action (opts) =>

        validateGlobalOpts(opts, CONS.CMD_IMPORT_PRODUCTS)
        logger = createLogger(opts)

        if opts.parent.config # use SFTP to load import/export files
          loadResources(opts, logger)
          .then (resources) ->
            resources.options.safeCreate = opts.safeCreate
            resources.options.continueOnProblems = opts.continueOnProblems
            importer = new Categories resources.options
            processSftpImport(resources, importer, 'categories')
            .then (result) ->
              importer = new Manufacturers resources.options
              processSftpImport(resources, importer, 'manufacturers')
            .then (result) ->
              importer = new Products resources.options
              processSftpImport(resources, importer, 'products')
          .then =>
            @_setExitCode 0
          .fail (error) =>
            logger.error error, 'Oops, something went wrong!'
            logger.error error.stack if error.stack
            @_setExitCode 1
          .done()
        else # use command line arguments to load import/export files
          validateCredentialsOpts(opts, CONS.CMD_IMPORT_PRODUCTS)
          validateOpt(opts.products, 'products', CONS.CMD_IMPORT_PRODUCTS)

          options = createBaseOptions(opts, logger)
          options.safeCreate = opts.safeCreate
          options.continueOnProblems = opts.continueOnProblems
          mapping = null

          utils.readJsonFromPath(opts.parent.mapping)
          .then (mappingResult) ->
            mapping = mappingResult
            if opts.categories
              importer = new Categories options
              importFn(importer, opts.categories, mapping, logger)
          .then (result) ->
            if opts.manufacturers
              importer = new Manufacturers options
              importFn(importer, opts.manufacturers, mapping, logger)
          .then (result) ->
            importer = new Products options
            importFn(importer, opts.products, mapping, logger)
          .then =>
            @_setExitCode 0
          .fail (error) =>
            logger.error error, 'Oops, something went wrong!'
            logger.error error.stack if error.stack
            @_setExitCode 1
          .done()

    program
      .command CONS.CMD_IMPORT_PRODUCTS_UPDATES
      .description 'Imports Brickfox product stock and price changes into your SPHERE.IO project.'
      .option '--products <file>', 'XML file containing products to import'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --products <file>'
      .action (opts) =>

        validateGlobalOpts(opts, CONS.CMD_IMPORT_PRODUCTS_UPDATES)
        logger = createLogger(opts)

        if opts.parent.config # use SFTP to load import/export files
          loadResources(opts, logger)
          .then (resources) ->
            importer = new ProductUpdates resources.options
            processSftpImport(resources, importer, 'productUpdates')
          .then =>
            @_setExitCode 0
          .fail (error) =>
            logger.error error, 'Oops, something went wrong!'
            logger.error error.stack if error.stack
            @_setExitCode 1
          .done()
        else # use command line arguments to load import/export files
          validateCredentialsOpts(opts, CONS.CMD_IMPORT_PRODUCTS_UPDATES)
          validateOpt(opts.products, 'products', CONS.CMD_IMPORT_PRODUCTS_UPDATES)

          options = createBaseOptions(opts, logger)

          utils.readJsonFromPath(opts.parent.mapping)
          .then (mapping) ->
            importer = new ProductUpdates options
            importFn(importer, opts.products, mapping, logger)
          .then =>
            @_setExitCode 0
          .fail (error) =>
            logger.error error, 'Oops, something went wrong!'
            logger.error error.stack if error.stack
            @_setExitCode 1
          .done()

    program
      .command CONS.CMD_EXPORT_ORDERS
      .description 'Exports new orders from your SPHERE.IO project into Brickfox XML file.'
      .option '--target <file>', 'Path to the file the exporter will write the resulting XML into'
      .option '--numberOfDays [days]', 'Retrieves orders created within the specified number of days starting with the present day. Default value is: 7'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --numberOfDays [days] --target <file>'
      .action (opts) =>

        validateGlobalOpts(opts, CONS.CMD_EXPORT_ORDERS)
        logger = createLogger(opts)

        if opts.parent.config # use SFTP to load import/export files
          loadResources(opts, logger)
          .then (resources) ->
            resources.options.numberOfDays = opts.numberOfDays
            exporter = new Orders resources.options
            processSftpExport(resources, exporter, 'orders')
          .then =>
            @_setExitCode 0
          .fail (error) =>
            logger.error error, 'Oops, something went wrong!'
            logger.error error.stack if error.stack
            @_setExitCode 1
          .done()
        else # use command line arguments to load import/export files
          validateCredentialsOpts(opts, CONS.CMD_EXPORT_ORDERS)
          validateOpt(opts.target, 'target', CONS.CMD_EXPORT_ORDERS)

          options = createBaseOptions(opts, logger)
          options.numberOfDays = opts.numberOfDays

          utils.readJsonFromPath(opts.parent.mapping)
          .then (mapping) =>
            exporter = new Orders options
            exportFn(exporter, opts.target, mapping)
            .then (exportResult) ->
              exporter.doPostProcessing(exportResult)
            .then =>
              # output result after order export post processing
              exporter.outputSummary()
              @_setExitCode 0
            .fail (error) =>
              exporter.outputSummary()
              logger.error error, 'Oops, something went wrong!'
              logger.error error.stack if error.stack
              @_setExitCode 1
          .fail (error) =>
            logger.error error, 'Oops, something went wrong!'
            logger.error error.stack if error.stack
            @_setExitCode 1
          .done()

    program
      .command CONS.CMD_IMPORT_ORDERS_STATUS
      .description 'Imports order and order entry status changes from Brickfox into your SPHERE.IO project.'
      .option '--status <file>', 'XML file containing order status to import'
      .option '--createStates', 'If set, will setup order line item states and its transitions according to mapping definition'
      .usage '--projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --status <file> --createStates'
      .action (opts) =>

        validateGlobalOpts(opts, CONS.CMD_IMPORT_ORDERS_STATUS)
        logger = createLogger(opts)

        if opts.parent.config # use SFTP to load import/export files
          loadResources(opts, logger)
          .then (resources) ->
            resources.options.createstates = opts.createStates
            importer = new OrderStatus resources.options
            processSftpImport(resources, importer, 'orderStatus')
          .then =>
            @_setExitCode 0
          .fail (error) =>
            logger.error error, 'Oops, something went wrong!'
            logger.error error.stack if error.stack
            @_setExitCode 1
          .done()
        else # use command line arguments to load import/export files
          validateCredentialsOpts(opts, CONS.CMD_IMPORT_ORDERS_STATUS)
          validateOpt(opts.status, 'status', CONS.CMD_IMPORT_ORDERS_STATUS)

          options = createBaseOptions(opts, logger)
          options.createstates = opts.createStates

          utils.readJsonFromPath(opts.parent.mapping)
          .then (mapping) ->
            importer = new OrderStatus options
            importFn(importer, opts.status, mapping, logger)
          .then =>
            @_setExitCode 0
          .fail (error) =>
            logger.error error, 'Oops, something went wrong!'
            logger.error error.stack if error.stack
            @_setExitCode 1
          .done()

    validateOpt = (value, varName, commandName) ->
      if not value
        console.error "Missing required argument '#{varName}' for command '#{commandName}'!"
        process.exit(2)

    validateGlobalOpts = (opts, commandName) ->
      validateOpt(opts.parent.mapping, 'mapping', commandName)

    validateCredentialsOpts = (opts, commandName) ->
      validateOpt(opts.parent.projectKey, 'projectKey', commandName)
      validateOpt(opts.parent.clientId, 'clientId', commandName)
      validateOpt(opts.parent.clientSecret, 'clientSecret', commandName)

    initSftp = (host, username, password, logger) ->
      throw new Error 'You must provide host in order to connect to SFTP' unless host
      throw new Error 'You must provide username in order to connect to SFTP' unless username
      throw new Error 'You must provide password in order to connect to SFTP' unless password
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

    createLogger = (opts) ->
      logger = new ExtendedLogger
        additionalFields:
          project_key: opts.parent.projectKey
          operation_type: opts._name
        logConfig:
          name: "#{package_json.name}-#{package_json.version}"
          streams: [
            {level: 'error', stream: process.stderr}
            {level: opts.parent.logLevel, path: "#{opts.parent.logDir}/sphere-brickfox-connector.log"}
          ]
          src: if opts.parent.bunyanVerbose then true else false

      process.on 'SIGUSR2', -> logger.reopenFileStreams()
      logger

    createBaseOptions = (opts, logger) ->
      options =
        config:
          project_key: opts.parent.projectKey
          client_id: opts.parent.clientId
          client_secret: opts.parent.clientSecret
        logConfig: logger.bunyanLogger
        appLogger: logger

    loadResources = (opts, logger) ->
      resources = {}
      ProjectCredentialsConfig.create()
      .then (credentialsResult) ->
        resources.options =
          config: credentialsResult.enrichCredentials
            project_key: opts.parent.projectKey
            client_id: opts.parent.clientId
            client_secret: opts.parent.clientSecret
          logConfig: logger.bunyanLogger
          appLogger: logger
          baseConfig:
            host = opts.parent.sphereHost if opts.parent.sphereHost
        utils.readJsonFromPath(opts.parent.config)
      .then (configResult) ->
        # get configuration for given project key
        projectConfig = configResult[opts.parent.projectKey]
        throw new Error  "No configuration for projectKey: '#{opts.parent.projectKey}' in '#{opts.parent.config}' found." if not projectConfig
        resources.config = projectConfig
        utils.readJsonFromPath(opts.parent.mapping)
      .then (mappingResult) ->
        resources.mapping = mappingResult
        utils.readJsonFromPath(opts.parent.sftpCredentials) if opts.parent.sftpCredentials
      .then (sftpCredentialsResult) ->
        sftpCred = {}
        sftpCred = sftpCredentialsResult[opts.parent.projectKey] or {} if sftpCredentialsResult
        {host, username, password} = _.defaults sftpCred,
          host: opts.parent.sftpHost
          username: opts.parent.sftpUsername
          password: opts.parent.sftpPassword
        throw new Error "Missing sftp host; --sftpCredentials: '#{opts.parent.sftpCredentials}'" if not host
        throw new Error "Missing sftp username; --sftpCredentials: '#{opts.parent.sftpCredentials}'" if not username
        throw new Error "Missing sftp password; --sftpCredentials: '#{opts.parent.sftpCredentials}'" if not password
        resources.sftpClient = initSftp(host, username, password, logger)
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
        logger.debug "Check for new '#{code}' in: '#{sourceFolder}'"
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
        d.reject error
      d.promise

    # parse and process command line arguments
    program.parse argv
    program.help() if program.args.length is 0

module.exports.run process.argv
