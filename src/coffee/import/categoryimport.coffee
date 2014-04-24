Q = require 'q'
_ = require 'lodash-node'
_s = require 'underscore.string'
{Rest} = require 'sphere-node-connect'
SphereClient = require 'sphere-node-client'
{_u} = require 'sphere-node-utils'
api = require '../../lib/sphere'
utils = require '../../lib/utils'



###
Imports Brickfox categories provided as XML into SPHERE.IO
###
class CategoryImport

  constructor: (@_options = {}) ->
    @rest = new Rest @_options
    @client = new SphereClient @_options
    @client.setMaxParallel(100)
    @logger = @_options.appLogger
    @categoriesCreated = 0
    @categoriesUpdated = 0
    @success = false


  execute: (categoriesXML) ->
    @startTime = new Date().getTime()
    @client.categories.perPage(0).fetch()
    .then (fetchedCategoriesResult) =>
      @fetchedCategories = utils.transformByCategoryExternalId(fetchedCategoriesResult.body.results)
      @logger.info "[Categories] Fetched SPHERE.IO categories count: '#{_.size @fetchedCategories}'"
      @categories = @_buildCategories(categoriesXML)
      @categoryCreates = @_buildCategoryCreates(@categories, @fetchedCategories) if @categories
      Q.all(_.map(@categoryCreates, (c) => @client.categories.save(c))) if @categoryCreates
    .then (createCategoriesResult) =>
      @categoriesCreated = _.size(@categoryCreates)
      # fetch created categories to get id's used for parent reference creation. Required only if new categories created.
      @client.categories.perPage(0).fetch() if @categoryCreates
    .then (fetchedCategoriesResult) =>
      @fetchedCategories = utils.transformByCategoryExternalId(fetchedCategoriesResult.body.results) if fetchedCategoriesResult
      @logger.info "[Categories] Fetched SPHERE.IO categories count after create: '#{_.size @fetchedCategories}'" if fetchedCategoriesResult
      @categoryUpdates = @_buildCategoryUpdates(@categories, @fetchedCategories) if @categories
      # TODO replace batchSeq with process provided by sphere-node-client (test it!)
      utils.batchSeq(@rest, api.updateCategory, @categoryUpdates, 0) if @categoryUpdates
    .then (updateCategoriesResult) =>
      @categoriesUpdated = _.size(@categoryUpdates)
      @success = true

  outputSummary: ->
    endTime = new Date().getTime()
    result = if @success then 'SUCCESS' else 'ERROR'
    @logger.info """[Categories] Import result: #{result}.
                    [Categories] Created: #{@categoriesCreated}
                    [Categories] Updated: #{@categoriesUpdated}
                    [Categories] Processing time: #{(endTime - @startTime) / 1000} seconds."""

  ###
  # Builds categories list from import data with all attributes (name, slug, parent <-> child relation) required for category creation or update.
  #
  # @param {Object} data Data to get categories information from
  # @return {Array} List of categories
  ###
  _buildCategories: (data) ->
    count = _.size(data.Categories?.Category)
    if count
      @logger.info "[Categories] Import categories found: '#{count}'"
    else
      @logger.info '[Categories] No categories to import found or undefined. Please check categories input XML.'
      return
    categories = []
    _.each data.Categories.Category, (c) =>
      category = @_convertCategory(c)
      categories.push category

    @logger.debug "[Categories] Import candidates count: '#{_.size categories}'"
    categories

  ###
  # Builds list of category create object representations.
  #
  # @param {Array} data List of category candidates to import
  # @param {Array} fetchedCategories List of existing categories
  # @return {Array} List of category create representations
  ###
  _buildCategoryCreates: (data, fetchedCategories) =>
    creates = []
    _.each data, (c) ->
      exists = _.has(fetchedCategories, c.id)
      # we are interested in new categories only
      if not exists
        name = c.name
        slug = c.slug
        # set category external id (over slug as workaround)
        # TODO: do not use slug as external category id (required Sphere support of custom attributes on category first)
        slug.nl = c.id
        create =
          name: name
          slug: slug
        creates.push create

    count = _.size(creates)
    if count > 0
      @logger.info "[Categories] Create count: '#{count}'"
      creates
    else
      @logger.info "[Categories] No category create required."
      null

  ###
  # Builds list of category update object representations.
  #
  # @param {Array} data List of category candidates to update
  # @param {Array} fetchedCategories List of existing categories
  # @return {Array} List of category update representations
  ###
  _buildCategoryUpdates: (data, fetchedCategories) ->
    updates = []
    _.each data, (c) ->
      actions = []
      newName = c.name
      oldCategory = utils.getCategoryByExternalId(c.id, fetchedCategories)
      oldName = oldCategory.name

      # check if category name changed
      if not _.isEqual(newName, oldName)
        action =
          action: "changeName"
          name: newName
        actions.push action

      parentId = c.parentId
      parentCategory = utils.getCategoryByExternalId(parentId, fetchedCategories) if parentId
      # check if category need to be assigned to parent
      if parentCategory
        action =
          action: "changeParent"
          parent:
            typeId: "category"
            id: parentCategory.id
        actions.push action

      if _.size(actions) > 0
        wrapper =
          id: oldCategory.id
          payload:
            version: oldCategory.version
            actions: actions
        updates.push wrapper

    count = _.size(updates)
    if count > 0
      @logger.info "[Categories] Update count: '#{count}'"
      updates
    else
      @logger.info "[Categories] No category update required."
      null

  ###
  # Transforms a list of existing categories into a new object (map alike) using external category id as abject property name (key).
  #
  # @param {Array} fetchedCategories List of existing categories
  # @throws {Error} If category external id is not defined
  # @return {Array} List of of transformed categories
  ###
  _transformByCategoryExternalId: (fetchedCategories) ->
    map = {}
    _.each fetchedCategories, (el) ->
      # TODO: do not use slug as external category id (required Sphere support of custom attributes on category first)
      externalId = el.slug.nl
      throw new Error "[Categories] Slug for language 'nl' (workaround: used as 'externalId') in MC is empty; Category id: '#{el.id}'" if not externalId
      map[externalId] = el
    map

  ###
  # Converts XML category data into Sphere category representation.
  #
  # @param {Object} categoryItem Category data
  # @return {Object} Sphere category representation
  ###
  _convertCategory: (categoryItem) ->
    names = utils.getLocalizedValues(categoryItem.Translations[0], 'Name')
    slugs = utils.generateLocalizedSlugs(names)
    category =
      id: categoryItem.CategoryId[0]
      name: names
      slug: slugs
    category.parentId = categoryItem.ParentId if categoryItem.ParentId
    category

module.exports = CategoryImport
