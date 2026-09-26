-- Jobs: one row per work-assignment attempt on a (worker, type, ref_id)
-- target - the worker-facing report/ack/error protocol a worker uses to
-- record observe progress, plus the read-side list/stats views. Generalized
-- with a `type` dimension (see config/dataset/init.sql's comment on
-- jobs.type) and per-type rollup targets (see services/jobs.lua).
local db = require("lapis.db")
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")
local export_response = require("lib.export_response")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/jobs"

local JOBS_EXPORT_COLUMNS = {
  "id", "worker_id", "type", "ref_id", "from_scheduler", "status", "message",
  "action", "result", "retries", "taken_at", "acked_at", "error_at",
  "created_at", "updated_at",
}

local Plugin = {
  name = "jobs",
  dependencies = { "security" },
}

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })

  -- Rollup target for type='observe': observables' own last_observe_* columns
  -- (see config/dataset/init.sql). type='analyze'/'notify' have no
  -- registered target yet - see jobs.lua's M.new header comment.
  --
  -- remove_fields_on_update strips `properties` from the update payload:
  -- resource_manager.lua's :update copies every column off the existing
  -- row (including `properties`) before applying `apply`'s changes, and
  -- the Postgres driver already auto-decodes a jsonb column into a plain
  -- Lua table on read - writing that table straight back via observable:update
  -- (rather than through jsonb_query.encode's db.raw wrapping, which only
  -- plugins/entities' own routes do) fails with "unknown table passed to
  -- escape_literal". The rollup never intends to touch `properties`
  -- anyway, so dropping it from the payload leaves that column untouched.
  local observables_manager = require("lib.resource_manager").new(models.Observables, {
    remove_fields_on_update = { "properties" },
  })

  local job_manager = require("plugins.jobs.services.jobs").new(models.Jobs, {
    observe = {
      manager = observables_manager,
      apply = function(d, winner)
        d.last_observe_status = winner.status
        d.last_observe_worker = winner.worker_id
        if winner.taken_at then
          d.last_observe_take_at = winner.taken_at
        end
        if winner.acked_at then
          d.last_observe_ack_at = winner.acked_at
        end
        return d
      end,
    },
  })

  local job_search_manager = require("lib.resource_manager").new(models.Jobs, {
    fields_query_params = {
      "id",
      "worker_id",
      "type",
      "status",
      "ref_id",
      -- ref_id is polymorphic (see config/dataset/init.sql's comment on
      -- jobs.type/from_scheduler): resolves through scheduler_tasks for a
      -- scheduler-fired row, through observables for an ordinary per-observable one -
      -- from_scheduler is what disambiguates which join applies.
      {
        key = "observable_type_id",
        map_clause = function(p)
          return string.format(
            "((from_scheduler AND ref_id IN (SELECT id FROM scheduler_tasks WHERE observable_type_id = %s)) "
              .. "OR (NOT from_scheduler AND ref_id IN (SELECT id FROM observables WHERE observable_type_id = %s)))",
            db.escape_literal(p.value),
            db.escape_literal(p.value)
          )
        end,
      },
      route_helpers.created_after_param(),
      route_helpers.created_before_param(),
    },
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

  -- Downloads every job matching the request's current filters/search/
  -- sort (unpaginated - see alerts' identical export route for the
  -- from/size mechanism) as JSON or CSV (?format=csv).
  app:get(
    base_path .. "/export",
    compose(
      require_auth,
      rbac:with(perms.JOBS_READ),
      with_error_handling("Failed to export jobs", "Failed to export jobs")
    )(function(self)
      local result = job_search_manager:search(self)
      return export_response.respond(self, result.items, JOBS_EXPORT_COLUMNS, "jobs", "Jobs")
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

  app:delete(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.JOBS_DELETE),
      with_error_handling("Failed to delete job", "Failed to delete job")
    )(function(self)
      job_search_manager:delete(self.params.id)
      return { status = 200, json = { message = "Job deleted" } }
    end)
  )

  -- Worker-facing report protocol: a job is lazily created on its first
  -- report, upserted in place by (worker_id, type, ref_id) only while it
  -- stays "triggering" (see services/jobs.lua:report / jobs_active_unique_idx)
  -- - once it goes terminal, the next report for that same worker+target
  -- starts a fresh, independent row. `:status` is "triggering" or "ack",
  -- mapped to the DB's "triggering"/"acknowledged" values.
  app:put(
    base_path .. "/:type/:ref_id/:status",
    compose(
      require_auth,
      rbac:with(perms.JOBS_UPDATE),
      with_json_body({
        { "worker_id", types.valid_text },
        { "action", types.empty + types.valid_text },
        { "message", types.empty + types.valid_text },
        { "result", types.empty + types.table },
        -- Set by a scheduler-fired batch's own final ack (see
        -- shared/watchtower_worker_core/pollers/observe.lua / shared/watchtower_worker_core/provider_http.lua's
        -- M:report_batch_result) - :ref_id there is a scheduler_tasks.id,
        -- not an observables.id, so the ordinary type='observe' observables rollup
        -- must not run for it (see services/jobs.lua's M:report header
        -- comment). Every ordinary per-observable report omits this and behaves
        -- exactly as before.
        { "skip_rollup", types.empty + types.boolean },
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
        self.params.worker_id,
        status_value,
        self.params.action,
        self.params.message,
        self.params.result,
        self.params.skip_rollup
      )

      return { status = 202, json = { message = "Status changed", item = job, rollup = rollup_target } }
    end)
  )

  app:put(
    base_path .. "/:type/:ref_id/error",
    compose(
      require_auth,
      rbac:with(perms.JOBS_UPDATE),
      with_json_body({
        { "worker_id", types.valid_text },
        { "message", types.empty + types.valid_text },
        -- See the :status route's identical param above.
        { "skip_rollup", types.empty + types.boolean },
      }),
      with_error_handling("Failed to record job error", "Failed to record job error")
    )(function(self)
      local job, rollup_target = job_manager:report_error(
        self.params.type,
        self.params.ref_id,
        self.params.worker_id,
        self.params.message,
        self.params.skip_rollup
      )

      return { status = 202, json = { message = "Error recorded", item = job, rollup = rollup_target } }
    end)
  )

  -- Worker-facing housekeeping tick: resets any 'triggering' row stuck past
  -- `timeout_seconds` back to 'error', freeing jobs_active_unique_idx for a
  -- fresh claim - see services/jobs.lua's reap_stale and
  -- shared/watchtower_worker_core/pollers/reap_stale.lua. A state transition
  -- on existing jobs, like the :status/error reports above, so it uses the
  -- same JOBS_UPDATE permission rather than the generic WORKERS_WRITE.
  app:put(
    base_path .. "/reap-stale",
    compose(
      require_auth,
      rbac:with(perms.JOBS_UPDATE),
      with_json_body({
        { "timeout_seconds", types.empty + types.db_id },
      }),
      with_error_handling("Failed to reap stale jobs", "Failed to reap stale jobs")
    )(function(self)
      local timeout_seconds = tonumber(self.params.timeout_seconds) or 300
      local items = job_manager:reap_stale(timeout_seconds)
      return { status = 200, json = { reaped = #items, items = items } }
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
