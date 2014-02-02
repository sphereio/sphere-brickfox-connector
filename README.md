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

## Usage
```bash
$ node lib/run.js
Usage: node ./lib/run.js --projectKey [key] --clientId [id] --clientSecret [secret]

Options:
  --projectKey, -k    Sphere.io project key.             [required]
  --clientId, -i      Sphere.io HTTP API client id.      [required]
  --clientSecret, -s  Sphere.io HTTP API client secret.  [required]

Missing required arguments: projectKey, clientId, clientSecret
```

## Tests
Tests are written using [jasmine](http://pivotal.github.io/jasmine/) (behavior-driven development framework for testing javascript code). Thanks to [jasmine-node](https://github.com/mhevery/jasmine-node), this test framework is also available for node.js.

To run tests, simple execute the *test* task using `grunt`.
```bash
$ grunt test
```

## Styleguide
We <3 CoffeeScript here at commercetools! So please have a look at this referenced [coffeescript styleguide](https://github.com/polarmobile/coffeescript-style-guide) when doing changes to the code.
