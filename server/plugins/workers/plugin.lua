-- Worker registry: workers self-register/heartbeat here (both
-- the embedded worker and any standalone worker instance, see Phase 5's
-- shared worker code), and their heartbeat history is queryable for a
-- histogram.
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")
local db = require("lapis.db")
local property_schema = require("lib.property_schema")
local jsonb_query = require("lib.jsonb_query")
local worker_role_schemas = require("plugins.workers.worker_role_schemas")
local export_response = require("lib.export_response")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/workers"

local WORKERS_EXPORT_COLUMNS = {
  "worker_id", "connection_type", "version", "capabilities", "config",
  "uptime_seconds", "roles", "properties", "last_seen_at", "created_at",
  "updated_at",
}

local WORKER_ROLE_SET = {}
for _, t in ipairs(worker_role_schemas.WORKER_ROLES) do
  WORKER_ROLE_SET[t] = true
end

-- Validates every element of `worker_roles` is a known role, then returns
-- the concatenation of each declared role's property-definition list -
-- the schema a worker's self-reported `properties` must satisfy given
-- the combination of roles it declared this heartbeat. Returns
-- (schema, nil) or (nil, err).
local function combined_property_schema(worker_roles)
  local schema = {}
  for _, t in ipairs(worker_roles) do
    if not WORKER_ROLE_SET[t] then
      return nil, "unknown worker role '" .. tostring(t) .. "'"
    end
    for _, prop in ipairs(worker_role_schemas.PROPERTY_SCHEMAS[t]) do
      table.insert(schema, prop)
    end
  end
  return schema, nil
end

local Plugin = {
  name = "workers",
  dependencies = { "security" },
}

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  local worker_manager = require("plugins.workers.services.workers").new(
    models.Workers,
    models.WorkerHeartbeats
  )

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.WORKERS_READ),
      with_error_handling("Failed to list workers", "Failed to list workers")
    )(function(self)
      return { status = 200, json = worker_manager:search(self) }
    end)
  )

  -- Downloads every worker matching the request's current filters/search/
  -- sort (unpaginated - see alerts' identical export route for the
  -- from/size mechanism) as JSON or CSV (?format=csv).
  app:get(
    base_path .. "/export",
    compose(
      require_auth,
      rbac:with(perms.WORKERS_READ),
      with_error_handling("Failed to export workers", "Failed to export workers")
    )(function(self)
      local result = worker_manager:search(self)
      return export_response.respond(self, result.items, WORKERS_EXPORT_COLUMNS, "workers", "Workers")
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.WORKERS_READ))(function(self)
      local item = worker_manager:get(self.params.id)
      if not item then
        return { status = 404, json = { message = "Worker not found", id = self.params.id } }
      end
      return { status = 200, json = { item = item } }
    end)
  )

  app:delete(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.WORKERS_DELETE),
      with_error_handling("Failed to delete worker", "Failed to delete worker")
    )(function(self)
      worker_manager:delete(self.params.id)
      return { status = 200, json = { message = "Worker deleted" } }
    end)
  )

  app:put(
    base_path .. "/:id/heartbeat",
    compose(
      require_auth,
      rbac:with(perms.WORKERS_WRITE),
      with_json_body({
        { "connection_type", types.valid_text },
        { "version", types.empty + types.valid_text },
        { "capabilities", types.empty + types.array_of(types.valid_text) },
        { "uptime_seconds", types.empty + types.number },
        { "config", types.empty + types.valid_text },
        { "roles", types.array_of(types.valid_text) },
        { "properties", types.empty + types.table },
      }),
      with_error_handling("Failed to record heartbeat", "Failed to record heartbeat")
    )(function(self)
      local capabilities = self.params.capabilities
      if type(capabilities) == "table" then
        capabilities = db.array(capabilities)
      end

      local worker_roles = self.params.roles
      if #worker_roles == 0 then
        return { status = 400, json = { message = "roles must declare at least one worker role" } }
      end

      local schema, schema_err = combined_property_schema(worker_roles)
      if not schema then
        return { status = 400, json = { message = schema_err } }
      end

      local ok, normalized_or_err = property_schema.validate_values(schema, self.params.properties)
      if not ok then
        return { status = 400, json = { message = normalized_or_err } }
      end

      local item = worker_manager:heartbeat(self.params.id, {
        connection_type = self.params.connection_type,
        version = self.params.version,
        capabilities = capabilities,
        uptime_seconds = self.params.uptime_seconds,
        config = self.params.config,
        roles = db.array(worker_roles),
        properties = jsonb_query.encode(normalized_or_err),
      })

      return { status = 202, json = { message = "Heartbeat recorded", item = item } }
    end)
  )

  app:get(
    base_path .. "/:id/heartbeats",
    compose(
      require_auth,
      rbac:with(perms.WORKERS_READ),
      with_error_handling("Failed to list worker heartbeats", "Failed to list worker heartbeats")
    )(function(self)
      local valid_buckets = { minute = true, hour = true, day = true }
      if not valid_buckets[self.params.bucket] then
        return {
          status = 400,
          json = { message = string.format("bucket is not valid: %s", tostring(self.params.bucket)) },
        }
      end

      if not self.params.since or not self.params["until"] then
        return { status = 400, json = { message = "since and until are required" } }
      end

      local data = worker_manager:heartbeat_buckets(self.params.id, {
        bucket = self.params.bucket,
        since = self.params.since,
        until_ = self.params["until"],
      })

      return { status = 200, json = { items = data } }
    end)
  )

  -- Admin on-demand trigger: the embedded worker's closest equivalent to
  -- the standalone worker's --once/WORKER_RUN_ONCE (see worker/lua/main.lua
  -- and docs/dev/worker-configuration.md's "Running as a one-shot job"
  -- section) - the embedded worker can't itself be invoked by an external
  -- OS cron/systemd timer (it lives inside the server's nginx worker
  -- process, not its own process), but an admin - or an external cron
  -- curling this route - can force one out-of-band pass of a given role's
  -- action, ahead of that role's own ngx.timer.every cadence.
  -- WORKERS_WRITE, same precedent as every other worker-mutating route in
  -- this plugin/the scheduler/notification_channels plugins. Reads the
  -- booted embedded worker instance off a plain Lua global, NOT via
  -- require("workers.observe_pending_worker") - see that module's own
  -- run_role_once/_G.watchtower_embedded_worker header comment for why a
  -- fresh require() from a request handler would be unsafe in dev.
  app:post(
    base_path .. "/embedded/run/:role",
    compose(
      require_auth,
      rbac:with(perms.WORKERS_WRITE),
      with_error_handling("Failed to trigger embedded worker role", "Failed to trigger embedded worker role")
    )(function(self)
      local embedded_worker = _G.watchtower_embedded_worker
      if not embedded_worker then
        return { status = 404, json = { message = "Embedded worker is not running on this server" } }
      end
      local ok, err, status = embedded_worker.run_role_once(self.params.role)
      if not ok then
        return { status = status or 400, json = { message = err } }
      end
      return { status = 202, json = { message = "Role triggered", role = self.params.role } }
    end)
  )

  return {
    worker_manager = worker_manager,
  }
end

return Plugin
