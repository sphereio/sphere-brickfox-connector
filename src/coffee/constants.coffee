constants =

  CMD_IMPORT_PRODUCTS: 'import-products'
  CMD_IMPORT_PRODUCTS_UPDATES: 'import-products-updates'
  CMD_EXPORT_ORDERS: 'export-orders'
  CMD_IMPORT_ORDERS_STATUS: 'import-orders-status'


for name,value of constants
  exports[name] = value