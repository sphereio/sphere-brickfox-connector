sphere-brickfox-connector
=========================

[![Build Status](https://travis-ci.org/sphereio/sphere-brickfox-connector.png?branch=master)](https://travis-ci.org/sphereio/sphere-brickfox-connector) [![Coverage Status](https://coveralls.io/repos/sphereio/sphere-brickfox-connector/badge.png)](https://coveralls.io/r/sphereio/sphere-brickfox-connector) [![Dependency Status](https://david-dm.org/sphereio/sphere-brickfox-connector.png?theme=shields.io)](https://david-dm.org/sphereio/sphere-brickfox-connector) [![devDependency Status](https://david-dm.org/sphereio/sphere-brickfox-connector/dev-status.png?theme=shields.io)](https://david-dm.org/sphereio/sphere-brickfox-connector#info=devDependencies)

This repository contains a set of data connectors to sync data between brickfox &lt;-> SPHERE.IO

## Setup

* install [NodeJS](http://support.sphere.io/knowledgebase/articles/307722-install-nodejs-and-get-a-component-running) (platform for running application)
* install [npm]((http://gruntjs.com/getting-started)) (NodeJS package manager, bundled with node since version 0.6.3!)
* install [grunt-cli] (http://gruntjs.com/getting-started) (automation tool)
*  resolve dependencies using `npm`
```bash
$ npm install
```
* build javascript sources
```bash
$ grunt build
```

## General Usage
### Mapping

Before running this tool Brickfox to SPHERE.IO mapping has to be defined.

#### Product import mapping attributes

 - `target`: Specifies where to save mapped Brickfox value to. Possible values: ```product | variant```

 - `isCustom`: Only relevant for targets of type ```variant``` and specifies if value should be mapped to one of the SPHERE.IO [product type](http://commercetools.de/dev/http-api-projects-productTypes.html#product-type) attributes. Possible values ```true | false```

 - `type`: Defines attribute type. Standard type [values](http://commercetools.de/dev/http-api-projects-productTypes.html#attribute-type).

  Special type values:
     - `special-tax`: Attribute's value will be mapped to configured tax category IDs
     - `special-price`: Attribute's value will be mapped to configured customer group ID, channel group ID and country
     - `special-image`: Attribute's value will used as URL for creation of variant images. Optional special mapping attribute `baseURL` can be used for prefixing of values with base url if non defined

  > Make sure that localized Brickfox attributes are mapped to localized ltext / lnum SPHERE.IO attributes.

 - `to`: Defines SPHERE.IO product attribute name where the mapped value will be saved to. Possible product [attributes](http://commercetools.de/dev/http-api-projects-products.html#new-product). Possible variant [attributes](http://commercetools.de/dev/http-api-projects-products.html#new-product-variant)

 - `logoutMissing`: Used for output of missing product type attribute values. Can be usefull for product type setup
 - `transformers`: List of transformers to apply on the "enum" key or "text" value. Supported value transformers: regular expressions, lower case, upper case. [Examples](https://github.com/sphereio/sphere-brickfox-connector/blob/master/examples/mapping.json)


 > To ensure successful synchronization with Brickfox following Brickfox attribute mappings are mandatory:
  > - VariationId (as variant product type attribute)
  >- ProductId (as variant product type attribute)
  >- ExternVariationId (as variant sku)

Product attribute mapping examples
```json
{
  "meta_title": {
        "target": "product",
        "type": "ltext",
        "to": "metaTitle"
    },
    "ProductId": {
        "target": "variant",
        "isCustom": "true",
        "type": "number",
        "to": "productId"
    },
    "PriceGross": {
        "target": "variant",
        "type": "special-price",
        "specialMapping": {
            "country": "DE",
            "customerGroup": "4b96b6f9-03b5-420e-8720-e243837482a8",
            "channel": "ad62d775-6d9c-49c0-af3a-3acd60008331"
       	},
        "to": "prices"
    }
}
```
More mapping examples can be found [here](https://github.com/sphereio/sphere-brickfox-connector/blob/master/examples/mapping.json)


This tool uses sub commands for the various task. Please refer to the usage of the concrete action:

- [Import products](#Import products)
- [Import stock and price updates](#Import stock and price updates)
- [Export orders](#Export orders)
- [Import order status updates](#Import order status updates)

General command line options can be seen by simply executing the command `node lib/run`.
```
node lib/run

  Usage: run [command] [globals] [options]

  Commands:

    import-products [options]  Imports new and changed Brickfox products from XML into your SPHERE.IO project.
    import-products-updates [options]  Imports Brickfox product stock and price changes into your SPHERE.IO project.
    export-orders [options]  Exports new orders from your SPHERE.IO project into Brickfox XML file.
    import-orders-status [options]  Imports order and order entry status changes from Brickfox into your SPHERE.IO project.

  Options:

    -h, --help                      output usage information
    -V, --version                   output the version number
    --projectKey <project-key>      your SPHERE.IO project-key
    --clientId <client-id>          your OAuth client id for the SPHERE.IO API
    --clientSecret <client-secret>  your OAuth client secret for the SPHERE.IO API
    --mapping <file>                JSON file containing Brickfox to SPHERE.IO mappings
    --config [file]                 path to configuration file with data like SFTP credentials and its working folders
    --logLevel [level]              specifies log level (error|warn|info|debug|trace) [info]
    --logDir [directory]            specifies log file directory [.]
    --bunyanVerbose                 enables bunyan verbose logging output mode. Due to performance issues avoid using it in production environment
```

For all command specific options please call `node lib/run <command> --help`.


## Import products

### Usage

```
node lib/run import-products --help

  Usage: import-products --projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --products <file> --manufacturers [file] --categories [file]

  Options:

    -h, --help              output usage information
    --products <file>       XML file containing products to import
    --manufacturers [file]  XML file containing manufacturers to import
    --categories [file]     XML file containing categories to import
    --safeCreate            If defined, importer will check for product existence (by ProductId attribute mapping) in SPHERE.IO before sending create new product request
    --continueOnProblems    When a product does not validate on the server side (400er response), ignore it and continue with the next products
```

## Import stock and price updates

### Usage

```
node lib/run import-products-updates --help

  Usage: import-products-updates --projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --products <file>

  Options:

    -h, --help         output usage information
    --products <file>  XML file containing products to import
```

## Export orders

### Usage

```
node lib/run export-orders --help

  Usage: export-orders --projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --numberOfDays [days] --mapping <file> --config [file] --target <file>

  Options:

    -h, --help             output usage information
    --target <file>        Path to the file the exporter will write the resulting XML into
    --numberOfDays [days]  Retrieves orders created within the specified number of days starting with the present day. Default value is: 7
```

## Import order status updates

### Usage

```
node lib/run import-orders-status --help

  Usage: import-orders-status --projectKey <project-key> --clientId <client-id> --clientSecret <client-secret> --mapping <file> --config [file] --status <file> --createStates

  Options:

    -h, --help       output usage information
    --status <file>  XML file containing order status to import
    --createStates   If set, will setup order line item states and its transitions according to mapping definition
```

## Logging

By default application logs into the file ./sphere-brickfox-connector.log with log level 'info'. Log level can be overriden with parameter --logLevel
> Once you installed bunyan CLI ```npm install -g bunyan``` following can be used for prettyfied log output: ```tail -f ./sphere-brickfox-connector.log | bunyan```

## Tests
Tests are written using [jasmine](https://jasmine.github.io/) (behavior-driven development framework for testing javascript code). Thanks to [jasmine-node](https://github.com/mhevery/jasmine-node), this test framework is also available for node.js.

To run tests, simple execute the *test* task using `grunt`.
```bash
$ grunt test
```

## Styleguide
We <3 CoffeeScript here at commercetools! So please have a look at this referenced [coffeescript styleguide](https://github.com/polarmobile/coffeescript-style-guide) when doing changes to the code.
