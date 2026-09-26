-- Observation ingest/history (/api/observations, unchanged base path &
-- permissions from the old server/plugins/observations/plugin.lua).
-- Generalized to be observable-type-driven: an observation's fields live in
-- `properties` (jsonb), validated against its Observable's observable_type's
-- `observation_schema` via lib/property_schema.lua instead of fixed
-- price/discount/available/url columns. This is the accepted API break
-- from the old flat POST body shape (see docs/dev/observable-types-storage.md).
local db = require("lapis.db")
local models = require("models")
local route_helpers = require("lib.routes")
local property_schema = require("lib.property_schema")
local jsonb_query = require("lib.jsonb_query")
local export_response = require("lib.export_response")
local types = require("lapis.validate.types")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local get_db_query_params_from_request_params = route_helpers.get_db_query_params_from_request_params
local get_db_where_clause_from_request_params = route_helpers.get_db_where_clause_from_request_params
local create_search_map_clause = route_helpers.create_search_map_clause
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/observations"

local OBSERVATIONS_EXPORT_COLUMNS = { "id", "observable_id", "worker", "timestamp", "properties", "observable" }

local function decode_observation(observation)
  if not observation then
    return observation
  end
  observation.properties = jsonb_query.decode(observation.properties)
  return observation
end

-- Shared by the list route and the export route below: builds the
-- dynamic where_params/search columns from the selected observable type's
-- observation_schema (if any), then selects/enriches/decodes exactly as
-- the list route always has. Returns (observations, total_items) - with no
-- `from`/`size` in the request, get_db_query_params_from_request_params
-- (lib/routes.lua) never applies offset/limit, so the export route (which
-- omits them) naturally gets every matching row, unpaginated.
local function search_observations(self, observable_type_manager)
  local observable_type = self.params.observable_type_id and observable_type_manager:find(self.params.observable_type_id)

  local where_params = {
    "id",
    "worker",
    "observable_id",
    {
      key = "timestamp_after",
      map_clause = function(p)
        return "timestamp >= " .. db.escape_literal(route_helpers.resolve_relative_date(p.value))
      end,
    },
    {
      key = "timestamp_before",
      map_clause = function(p)
        return "timestamp <= " .. db.escape_literal(route_helpers.resolve_relative_date(p.value))
      end,
    },
  }
  local search_columns = {}

  if self.params.observable_type_id then
    -- observations has no observable_type_id column of its own - filter by
    -- joining through the owning Observable.
    table.insert(where_params, {
      key = "observable_type_id",
      map_clause = function(p)
        return "observable_id in (select id from observables where observable_type_id = " .. db.escape_literal(p.value) .. ")"
      end,
    })
  end

  if observable_type then
    for _, p in ipairs(jsonb_query.where_params_for_schema("properties", observable_type.observation_schema)) do
      table.insert(where_params, p)
    end
    for _, c in ipairs(jsonb_query.searchable_columns("properties", observable_type.observation_schema)) do
      table.insert(search_columns, c)
    end
  end

  table.insert(where_params, { key = "search", map_clause = create_search_map_clause(search_columns) })

  local db_query = get_db_query_params_from_request_params(self, where_params)
  local where_clause = get_db_where_clause_from_request_params(self, where_params)

  local observations = models.Observations:select(db_query)
  models.Observables:include_in(observations, "observable_id")
  local total_items = models.Observations:count(where_clause)
  for _, o in ipairs(observations) do
    decode_observation(o)
  end

  return observations, total_items
end

return function(app, deps, observable_type_manager)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.OBSERVATIONS_READ),
      with_error_handling("Failed to list observations", "Unable to get the observation list.")
    )(function(self)
      local observations, total_items = search_observations(self, observable_type_manager)
      return { json = { items = observations or {}, total_items = total_items } }
    end)
  )

  -- Downloads every observation matching the request's current filters/
  -- search/sort (unpaginated - see search_observations above for the
  -- from/size mechanism) as JSON or CSV (?format=csv).
  app:get(
    base_path .. "/export",
    compose(
      require_auth,
      rbac:with(perms.OBSERVATIONS_READ),
      with_error_handling("Failed to export observations", "Failed to export observations")
    )(function(self)
      local observations = search_observations(self, observable_type_manager)
      return export_response.respond(self, observations, OBSERVATIONS_EXPORT_COLUMNS, "observations", "Observations")
    end)
  )

  -- Ingests a new observation - validates `properties` against the
  -- Observable's observable_type's observation_schema and persists it.
  -- Deliberately does NOT run rule matching here: analysis is a worker job,
  -- never an API endpoint's, so it's left to whichever "analyzer"-role
  -- worker is configured, picked up asynchronously (interval sweep, or a
  -- scheduler-fired type='analyze' task) via services/reanalyze.lua
  -- (embedded worker) or worker_rule_matcher.lua (standalone). `worker_id`
  -- (required) identifies which worker produced this observation - copied
  -- onto the observation so `worker` is usable in rule definitions
  -- generically (see shared/rule_engine/allowed_fields.lua), without exposing
  -- any observable-type-specific field directly.
  app:post(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.OBSERVATIONS_CREATE),
      with_json_body({
        { "id", types.db_id },
        { "timestamp", types.valid_text },
        { "worker_id", types.valid_text },
      })
    )(function(self)
      local observable = models.Observables:find({ id = self.params.id })
      if not observable then
        return { status = 404, json = { message = "Observable not found", id = self.params.id } }
      end

      local observable_type = observable_type_manager:find(observable.observable_type_id)
      local ok, normalized_or_err = property_schema.validate_values(
        observable_type and observable_type.observation_schema,
        self.params.properties
      )
      if not ok then
        return { status = 400, json = { success = false, message = normalized_or_err } }
      end

      local ok_create, result = pcall(function()
        return models.Observations:create({
          observable_id = self.params.id,
          timestamp = self.params.timestamp,
          worker = self.params.worker_id,
          properties = jsonb_query.encode(normalized_or_err),
        })
      end)

      if not ok_create then
        return { status = 500, json = { success = false, message = result or "Unable to add record." } }
      end

      return {
        status = 200,
        json = { success = true, message = "Observation added successfully.", data = decode_observation(result) },
      }
    end)
  )

  app:delete(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.OBSERVATIONS_DELETE))(function(self)
      local id = self.params.id
      if not id then
        return { status = 400, json = { error = "Missing observation id." } }
      end

      local opr, err = models.Observations:find({ id = id }):delete()
      if not opr then
        return { status = 500, json = { error = err or "Unable to remove observation." } }
      end

      return { json = { success = true, message = "Observation removed successfully.", data = err } }
    end)
  )
end
