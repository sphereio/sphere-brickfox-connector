Connector = require('../main').Connector

describe 'Connector', ->
  beforeEach ->
    @connector = new Connector

  it 'should initialize', ->
    expect(@connector).toBeDefined()


