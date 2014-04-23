{Logger} = require 'sphere-node-utils'

class ProductImportLogger extends Logger

  @appName: 'brickfox-product-import-logger'
  @path: './brickfox-product-import-logger.log'
  @levelStream: 'debug'

class ProductUpdateImportLogger extends Logger

  @appName: 'brickfox-product-update-import-logger'
  @path: './brickfox-product-update-import-logger.log'
  @levelStream: 'debug'

class OrderExportLogger extends Logger

  @appName: 'brickfox-order-export-logger'
  @path: './brickfox-order-export-logger.log'
  @levelStream: 'debug'

class OrderStatusImportLogger extends Logger

  @appName: 'brickfox-order-status-import-logger'
  @path: './brickfox-order-status-import-logger.log'
  @levelStream: 'debug'


module.exports =
  ProductImportLogger: ProductImportLogger
  ProductUpdateImportLogger: ProductUpdateImportLogger
  OrderExportLogger: OrderExportLogger
  OrderStatusImportLogger: OrderStatusImportLogger