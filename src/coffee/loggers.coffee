{Logger} = require 'sphere-node-connect'

class ProductImportLogger extends Logger

  @appName: 'brickfox-product-import-logger'
  @path: './brickfox-product-import-logger.log'
  @levelStream: 'debug'

class ProductUpdateImportLogger extends Logger

  @appName: 'brickfox-product-update-logger'
  @path: './brickfox-product-update-logger.log'
  @levelStream: 'debug'


module.exports =
  ProductImportLogger: ProductImportLogger
  ProductUpdateImportLogger: ProductUpdateImportLogger