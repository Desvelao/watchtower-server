-- Jobs: one row per (monitor, type, ref_id) work assignment - the
-- monitor-facing report/ack/error protocol a worker uses to record scrape
-- progress, plus the read-side list/stats views. Ported from pibuzz's
-- deliveries plugin wiring in application/main.lua, generalized with a
-- `type` dimension (see config/dataset/init.sql's comment on jobs.type)
-- and per-type rollup targets (see services/jobs.lua).
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/jobs"

local Plugin = {
  name = "jobs",
  dependencies = { "security" },
}

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  -- Rollup target for type='scrape': items' own last_scrape_* columns
  -- (see config/dataset/init.sql). type='notify' has no registered target
  -- yet - see jobs.lua's M.new header comment.
  local items_manager = require("lib.resource_manager").new(models.Items, {})

  local job_manager = require("plugins.jobs.services.jobs").new(models.Jobs, {
    scrape = {
      manager = items_manager,
      apply = function(d, winner)
        d.last_scrape_status = winner.status
        d.last_scrape_monitor = winner.monitor_id
        if winner.taken_at then
          d.last_scrape_take_at = winner.taken_at
        end
        if winner.acked_at then
          d.last_scrape_ack_at = winner.acked_at
        end
        return d
      end,
    },
  })

  local job_search_manager = require("lib.resource_manager").new(models.Jobs, {
    fields_query_params = { "id", "monitor_id", "type", "status", "ref_id" },
    fields_search_params = { "message", "action" },
    select_fields = "*",
  })

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.JOBS_READ),
      with_error_handling("Failed to list jobs", "Failed to list jobs")
    )(function(self)
      return { status = 200, json = job_search_manager:search(self) }
    end)
  )

  app:get(
    base_path .. "/stats",
    compose(
      require_auth,
      rbac:with(perms.JOBS_READ),
      with_error_handling("Failed to get job stats", "Failed to get job stats")
    )(function(self)
      return { status = 200, json = { items = job_manager:stats(self.params.type) } }
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.JOBS_READ))(function(self)
      local item = job_search_manager:find(self.params.id)
      if not item then
        return { status = 404, json = { message = "Job not found", id = self.params.id } }
      end
      return { status = 200, json = { item = item } }
    end)
  )

  -- Monitor-facing report protocol: a job is lazily created on its first
  -- report, upserted by (monitor_id, type, ref_id) thereafter (see
  -- services/jobs.lua:report). `:status` is "triggering" or "ack"
  -- (mirroring pibuzz's alert lifecycle route), mapped to the DB's
  -- "triggering"/"acknowledged" values.
  app:put(
    base_path .. "/:type/:ref_id/:status",
    compose(
      require_auth,
      rbac:with(perms.MONITORS_WRITE),
      with_json_body({
        { "monitor_id", types.valid_text },
        { "action", types.empty + types.valid_text },
        { "message", types.empty + types.valid_text },
      }),
      with_error_handling("Failed to report job status", "Failed to report job status")
    )(function(self)
      local status_map = { triggering = "triggering", ack = "acknowledged" }
      local status_value = status_map[self.params.status]

      if not status_value then
        return {
          status = 400,
          json = { message = string.format("Status is not valid: %s", tostring(self.params.status)) },
        }
      end

      local job, rollup_target = job_manager:report(
        self.params.type,
        self.params.ref_id,
        self.params.monitor_id,
        status_value,
        self.params.action,
        self.params.message
      )

      return { status = 202, json = { message = "Status changed", item = job, rollup = rollup_target } }
    end)
  )

  app:put(
    base_path .. "/:type/:ref_id/error",
    compose(
      require_auth,
      rbac:with(perms.MONITORS_WRITE),
      with_json_body({
        { "monitor_id", types.valid_text },
        { "message", types.empty + types.valid_text },
      }),
      with_error_handling("Failed to record job error", "Failed to record job error")
    )(function(self)
      local job, rollup_target = job_manager:report_error(
        self.params.type,
        self.params.ref_id,
        self.params.monitor_id,
        self.params.message
      )

      return { status = 202, json = { message = "Error recorded", item = job, rollup = rollup_target } }
    end)
  )

  app:get(
    base_path .. "/for/:type/:ref_id",
    compose(
      require_auth,
      rbac:with(perms.JOBS_READ),
      with_error_handling("Failed to list jobs", "Failed to list jobs")
    )(function(self)
      return { status = 200, json = { items = job_manager:list_for(self.params.type, self.params.ref_id) } }
    end)
  )

  return {
    job_manager = job_manager,
  }
end

return Plugin
