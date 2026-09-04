-- Scraping-agent registry: monitors self-register/heartbeat here (both
-- the embedded worker and any standalone worker instance, see Phase 5's
-- shared worker code), and their heartbeat history is queryable for a
-- histogram. Ported from pibuzz's dispatchers plugin wiring in
-- application/main.lua.
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")
local db = require("lapis.db")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/monitors"

local Plugin = {
  name = "monitors",
  dependencies = { "security" },
}

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  local monitor_manager = require("plugins.monitors.services.monitors").new(
    models.Monitors,
    models.MonitorHeartbeats
  )

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.MONITORS_READ),
      with_error_handling("Failed to list monitors", "Failed to list monitors")
    )(function(self)
      return { status = 200, json = { items = monitor_manager:list() } }
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.MONITORS_READ))(function(self)
      local item = monitor_manager:get(self.params.id)
      if not item then
        return { status = 404, json = { message = "Monitor not found", id = self.params.id } }
      end
      return { status = 200, json = { item = item } }
    end)
  )

  app:put(
    base_path .. "/:id/heartbeat",
    compose(
      require_auth,
      rbac:with(perms.MONITORS_WRITE),
      with_json_body({
        { "connection_type", types.valid_text },
        { "version", types.empty + types.valid_text },
        { "capabilities", types.empty + types.array_of(types.valid_text) },
        { "item_filter", types.empty + types.valid_text },
        { "uptime_seconds", types.empty + types.number },
        { "config", types.empty + types.valid_text },
      }),
      with_error_handling("Failed to record heartbeat", "Failed to record heartbeat")
    )(function(self)
      local capabilities = self.params.capabilities
      if type(capabilities) == "table" then
        capabilities = db.array(capabilities)
      end

      local item = monitor_manager:heartbeat(self.params.id, {
        connection_type = self.params.connection_type,
        version = self.params.version,
        capabilities = capabilities,
        item_filter = self.params.item_filter,
        uptime_seconds = self.params.uptime_seconds,
        config = self.params.config,
      })

      return { status = 202, json = { message = "Heartbeat recorded", item = item } }
    end)
  )

  app:get(
    base_path .. "/:id/heartbeats",
    compose(
      require_auth,
      rbac:with(perms.MONITORS_READ),
      with_error_handling("Failed to list monitor heartbeats", "Failed to list monitor heartbeats")
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

      local data = monitor_manager:heartbeat_buckets(self.params.id, {
        bucket = self.params.bucket,
        since = self.params.since,
        until_ = self.params["until"],
      })

      return { status = 200, json = { items = data } }
    end)
  )

  return {
    monitor_manager = monitor_manager,
  }
end

return Plugin
