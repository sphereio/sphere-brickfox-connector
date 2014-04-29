#!/bin/bash

cat > "config.json" << EOF
{
    "myprojectKey": {
	    "sftp_directories": {
	        "export": {
	            "orders": {
	            	"description": "XMLs with orders created by SPHERE.IO",
	                "target": "/test/orders/export"
	            }
	        },
	        "import": {
	            "categories": {
	                "description": "XMLs with new and changed Brickfox categories.",
	                "source": "/test/article",
	                "processed": "/test/article/processed",
	                "fileRegex": "^(Categories_)(\\\d+)(_)(\\\d+)(\\\.xml)$"
	            },
	            "manufacturers": {
	                "description": "XMLs with new and changed Brickfox manufacturers.",
	                "source": "/test/article",
	                "processed": "/test/article/processed",
	                "fileRegex": "^(Manufacturers_)(\\\d+)(_)(\\\d+)(\\\.xml)$"
	            },
	            "products": {
	                "description": "XMLs with new Brickfox products and products with content changes like product name / description.",
	                "source": "/test/article",
	                "processed": "/test/article/processed",
	                "fileRegex": "^(Products_)(\\\d+)(_)(\\\d+)(\\\.xml)$"
	            },
	            "productUpdates": {
	                "description": "XMLs with Brickfox product stock and price changes.",
	                "source": "/test/stock",
	                "processed": "/test/stock/processed",
	                "fileRegex": "^(ProductsUpdate_)(\\\d+)(_)(\\\d+)(\\\.xml)$"
	            },
	            "orderStatus": {
	                "description": "XMLs with Brickfox order state changes.",
	                "source": "/test/orders/import",
	                "processed": "/test/orders/import/processed",
	                "fileRegex": "^(Orderstatus_)(\\\d+)(_)(\\\d+)(\\\.xml)$"
	            }
	        }
	    },
	    "sftp_host": "${SFTP_HOST}",
	    "sftp_user": "${SFTP_USER}",
	    "sftp_password": "${SFTP_PASSWORD}"
    }
}
EOF