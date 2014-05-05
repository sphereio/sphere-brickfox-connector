Q = require 'q'
_ = require 'lodash-node'
_s = require 'underscore.string'
utils = require './utils'
{_u} = require 'sphere-node-utils'

#TODO use sphere-node-client/sync or GET/POST

###
# Updates asynchronously category in Sphere.
#
# @param {Object} data Update category request data
# @return {Object} If success returns promise with success message otherwise rejects with error message
###
exports.updateCategory = (rest, data) ->
  deferred = Q.defer()
  rest.POST "/categories/#{data.id}", data.payload, (error, response, body) ->
    if error
      deferred.reject "HTTP error on category update; Error: #{error}; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
    else
      if response.statusCode isnt 200
        message = "Error on category update; Request body: \n #{utils.pretty data} \n\n Response body: '#{utils.pretty body}'"
        deferred.reject message
      else
        message = "Category with id: '#{data.id}' updated."
        deferred.resolve message
  deferred.promise

exports.queryOrders = (rest, where, expand) ->
  @get(rest, @pathWhere("/orders", where, null, [expand]))

exports.addDelivery = (rest, order, deliveryItems) ->
  action =
    action: 'addDelivery'
    items: deliveryItems

  json =
    version: order.version
    actions: [action]

  @post(rest, "/orders/#{order.id}", json)

exports.addParcel = (rest, order, deliveryId, trackingData, measurements) ->
  action =
    action: 'addParcelToDelivery'
    deliveryId: deliveryId

  action.trackingData = trackingData if trackingData?
  action.measurements = measurements if measurements?

  json =
    version: order.version
    actions: [action]

  @post(rest, "/orders/#{order.id}", json)


exports.transitionLineItemStates = (rest, order, actions) ->
  json =
    version: order.version
    actions: actions

  @post(rest, "/orders/#{order.id}", json)

exports.pathWhere = (path, where, sort = [], expand = [], limit = 0, offset = 0) ->
  sorting = if not _.isEmpty(sort) then "&" + _.map(sort, (s) -> "sort=" + encodeURIComponent(s)).join("&") else ""
  expanding = if not _.isEmpty(expand) then "&" + _.map(expand, (e) -> "expand=" + encodeURIComponent(e)).join("&") else ""

  "#{path}?where=#{encodeURIComponent(where)}#{sorting}#{expanding}&limit=#{limit}&offset=#{offset}"

exports.ensureStates = (rest, defs, logger) ->
  statePromises = _.map defs, (def) =>
    @get(rest, @pathWhere('/states', "key=\"#{def.key}\" and type=\"LineItemState\""))
    .then (list) =>
      if list.total is 0
        logger.info "Before create new LineItemState with key: '#{def.key}'"
        json =
          key: def.key
          type: 'LineItemState'
          initial: false
        @post(rest, "/states", json)
      else
        list.results[0]
    .then (state) ->
      state.definition = def
      state

  Q.all statePromises
  .then (createdStates) =>
    finalPromises = _.map createdStates, (state) =>
      if (not state.transitions and state.definition.transitions) or
      (state.transitions and not state.definition.transitions) or
      (state.transitions and state.definition.transitions and _.size(state.transitions) != _.size(state.definition.transitions))
        json =
          if state.definition.transitions
            logger.info "Before add transitions to state with key: '#{state.key}'; transitions: \n '#{_u.prettify state.definition.transitions}'"
            version: state.version
            actions: [{action: 'setTransitions', transitions: _.map(state.definition.transitions, (tk) -> {typeId: 'state', id: _.find(createdStates, (s) -> s.key is tk).id})}]
          else
            logger.info "Before removal of all transitions for state with key: '#{state.key}'"
            version: state.version
            actions: [{action: 'setTransitions'}]

        @post(rest, "/states/#{state.id}", json)
      else
        Q(state)

    Q.all finalPromises

exports.get = (rest, path) ->
  d = Q.defer()
  rest.PAGED path, (error, response, body) ->
    if error
      d.reject "HTTP error on GET; Request path: '#{path}'; Error: #{error}; Response body: #{utils.pretty body}"
    else if response.statusCode is 200
      d.resolve body
    else
      d.reject "GET failed. StatusCode: '#{response.statusCode}'; Request path: '#{path}'; \n Response body: \n #{utils.pretty body}"
  d.promise

exports.post = (rest, path, json) ->
  d = Q.defer()
  rest.POST path, json, (error, response, body) ->
    if error
      d.reject "HTTP error on POST; Request path: '#{path}'; Error: #{error}; \n Request body: \n #{utils.pretty json} \n\n Response body: \n #{utils.pretty body}"
    else if response.statusCode is 200 or response.statusCode is 201
      d.resolve body
    else
      d.reject "POST failed. StatusCode: '#{response.statusCode}'; Request path: '#{path}'; \n Request body: \n #{utils.pretty json} \n\n Response body: \n #{utils.pretty body}"
  d.promise