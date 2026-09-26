-- Scheduler: admin-configured task definitions a "scheduler"-role worker
-- periodically evaluates (see services/scheduler.lua's fire_due) to queue a
-- single pending `jobs` row per firing (type=the task's own type -
-- observe/analyze/notify/deliver, ref_id=task.id) for a worker of the
-- matching role to claim ahead of the existing stalest-observable polling
-- (observe only) - the
-- task's target (observable set, or notify dispatch plan) is resolved lazily at
-- claim time, not by fire_due. No separate run/audit table - `jobs` itself
-- is the only record of a firing's outcome. fire_due itself stays
-- deliberately decoupled from analyzer/observer/deliver role logic - see
-- CLAUDE.md.
local models = require("models")
local route_helpers = require("lib.routes")
local types = require("lapis.validate.types")
local db = require("lapis.db")
local cjson = require("cjson")

local compose = route_helpers.compose
local with_json_body = route_helpers.capture_bad_request_params_validate
local with_error_handling = route_helpers.with_error_handling

local base_path = "/api/scheduler"

local Plugin = {
  name = "scheduler",
  -- notifications_channels (this plugin's own registered name - see its
  -- plugin.lua, `name = 'notifications_channels'`): its policy_manager
  -- (needed to validate notify_policy_ids), and its
  -- delivery_queue (needed by claim_next_batch's 'deliver' branch - see
  -- services/scheduler.lua) - same wiring shape as entities'
  -- observable_type_manager below. The plugin loader topologically sorts by
  -- declared dependencies, not by literal position in app.lua's registration
  -- list, so this needs no reordering there.
  dependencies = { "security", "entities", "notifications_channels" },
}

function Plugin.setup(app, deps)
  local security = deps.security
  local auth, rbac, perms = security.auth, security.rbac, security.perms
  local require_auth = auth:with({ require = true })
  local observable_type_manager = deps.entities.observable_type_manager
  local policy_manager = deps.notifications_channels.policy_manager
  local delivery_queue = deps.notifications_channels.delivery_queue

  local search_manager = require("lib.resource_manager").new(models.SchedulerTasks, {
    fields_query_params = {
      "id",
      "type",
      "observable_type_id",
      "schedule_type",
      {
        key = "enabled",
        map_clause = function(p) return "enabled = " .. db.escape_literal(p.value == "true") end,
      },
      route_helpers.created_after_param(),
      route_helpers.created_before_param(),
    },
    fields_search_params = { "name" },
  })

  local service = require("plugins.scheduler.services.scheduler").new(
    models.SchedulerTasks, models.Observables, observable_type_manager,
    policy_manager, delivery_queue
  )

  app:get(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.SCHEDULER_READ),
      with_error_handling("Failed to list scheduler tasks", "Failed to list scheduler tasks")
    )(function(self)
      return { status = 200, json = search_manager:search(self) }
    end)
  )

  app:get(
    base_path .. "/:id",
    compose(require_auth, rbac:with(perms.SCHEDULER_READ))(function(self)
      local item = search_manager:find(self.params.id)
      if not item then
        return { status = 404, json = { message = "Scheduler task not found", id = self.params.id } }
      end
      return { status = 200, json = { item = item } }
    end)
  )

  app:post(
    base_path,
    compose(
      require_auth,
      rbac:with(perms.SCHEDULER_CREATE),
      with_json_body({
        { "name", types.valid_text },
        { "type", types.empty + types.valid_text },
        { "observable_type_id", types.empty + types.db_id },
        { "observable_ids", types.empty + types.array_of(types.number) },
        { "notify_policy_ids", types.empty + types.array_of(types.number) },
        { "schedule_type", types.valid_text },
        { "cron_expression", types.empty + types.valid_text },
        { "run_at", types.empty + types.valid_text },
        { "enabled", types.empty + types.boolean },
        { "run_now", types.empty + types.boolean },
      }),
      with_error_handling("Failed to create scheduler task", "Failed to create scheduler task")
    )(function(self)
      local item, err = service:create(self.params)
      if not item then
        return { status = 400, json = { message = err } }
      end
      return { status = 201, json = { message = "Scheduler task created", item = item } }
    end)
  )

  app:put(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.SCHEDULER_UPDATE),
      with_json_body({
        { "name", types.empty + types.valid_text },
        { "observable_ids", types.empty + types.array_of(types.number) },
        { "notify_policy_ids", types.empty + types.array_of(types.number) },
        { "schedule_type", types.empty + types.valid_text },
        { "cron_expression", types.empty + types.valid_text },
        { "run_at", types.empty + types.valid_text },
        { "enabled", types.empty + types.boolean },
        { "run_now", types.empty + types.boolean },
      }),
      with_error_handling("Failed to update scheduler task", "Failed to update scheduler task")
    )(function(self)
      local item, err = service:update(self.params.id, self.params)
      if not item then
        return { status = 400, json = { message = err } }
      end
      return { status = 200, json = { message = "Scheduler task updated", item = item } }
    end)
  )

  app:delete(
    base_path .. "/:id",
    compose(
      require_auth,
      rbac:with(perms.SCHEDULER_DELETE),
      with_error_handling("Failed to delete scheduler task", "Failed to delete scheduler task")
    )(function(self)
      search_manager:delete(self.params.id)
      return { status = 200, json = { message = "Scheduler task deleted" } }
    end)
  )

  -- Plain JSON dump/restore of scheduler_tasks - no preflight step, no
  -- per-row conflict resolution, just a created/failed count after import.
  -- Mirrors plugins/notification_channels/plugin.lua's identical
  -- GET/POST base_path .. "/export"/"/import" for notification_channels
  -- (a different, lighter precedent than rules/notification_policies'
  -- flat-document + zip + preflight import, which needs a mandatory `if:`
  -- expression this table has no equivalent of).
  app:get(
    base_path .. "/export",
    compose(require_auth, rbac:with(perms.SCHEDULER_READ))(function(self)
      local items = models.SchedulerTasks:select()
      local filename = "scheduler_tasks_export_" .. os.date("%Y-%m-%d") .. ".json"
      return {
        status = 200,
        headers = {
          ["Content-Type"] = "application/json",
          ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
        },
        layout = false,
        json = { description = "Scheduler tasks configuration", items = items },
      }
    end)
  )

  -- Each row is fed straight into service:create, which already validates
  -- it in full (type, cron_expression, observable_type_id/observable_ids/
  -- notify_policy_ids existence - see services/scheduler.lua's _derive);
  -- fields an exported row carries that create() doesn't read (id,
  -- next_run_at, last_run_at, created_at, updated_at) are simply ignored.
  -- One failing row is counted in `failed` rather than aborting the batch.
  app:post(
    base_path .. "/import",
    compose(require_auth, rbac:with(perms.SCHEDULER_CREATE))(function(self)
      local file = self.params.file
      if not file then
        return { status = 400, json = { message = "File is missing." } }
      end

      local ok_decode, decoded = pcall(cjson.decode, file.content)
      if not ok_decode then
        return { status = 500, json = { ok = false, error = "File content could not be decoded" } }
      end

      local created, failed = {}, 0
      for _, row in ipairs(decoded.items or {}) do
        local item = service:create(row)
        if item then
          table.insert(created, item)
        else
          failed = failed + 1
        end
      end

      return { json = { ok = true, content = { items = created, failed = failed } } }
    end)
  )

  -- Read-only preview: no persistence, gated on READ not CREATE.
  app:post(
    base_path .. "/preview-cron",
    compose(
      require_auth,
      rbac:with(perms.SCHEDULER_READ),
      with_json_body({
        { "cron_expression", types.valid_text },
        { "count", types.empty + types.number },
      }),
      with_error_handling("Failed to preview cron expression", "Failed to preview cron expression")
    )(function(self)
      local service_module = require("plugins.scheduler.services.scheduler")
      local runs, err = service_module.preview_cron(self.params.cron_expression, self.params.count)
      if not runs then
        return { status = 400, json = { message = err } }
      end
      return { status = 200, json = { next_runs = runs } }
    end)
  )

  -- Worker-facing: the "scheduler" role's tick. This is the one place a
  -- scheduler-fired `jobs` row is ever created (see service:fire_due /
  -- services/jobs.lua), so it requires JOBS_CREATE alongside the generic
  -- machine-facing WORKERS_WRITE gate.
  app:put(
    base_path .. "/fire-due",
    compose(
      require_auth,
      rbac:with(perms.WORKERS_WRITE),
      rbac:with(perms.JOBS_CREATE),
      with_error_handling("Failed to fire due scheduler tasks", "Failed to fire due scheduler tasks")
    )(function(self)
      return { status = 200, json = service:fire_due() }
    end)
  )

  -- Worker-facing: a role's priority pickup - claims the oldest pending
  -- `jobs` row of `type` (standalone path; embedded calls
  -- service:claim_next_batch directly, no HTTP). Response's `item` carries
  -- the full, freshly-resolved target for the claimed task's firing
  -- (`observables` for observe/analyze, `enqueued`/`alerts_matched` for
  -- notify, `groups` for deliver - a batch of alert_deliveries rows claimed
  -- via delivery_queue_service, same shape PUT /api/alert_deliveries/claim
  -- returns), so the claiming worker never needs a follow-up round trip to
  -- resolve it itself. Called by every consumer role (observer/analyzer/
  -- evaluator/deliver), never by "scheduler" itself, so it also requires
  -- JOBS_READ (finding/selecting a pending job) alongside WORKERS_WRITE.
  app:put(
    base_path .. "/claim",
    compose(
      require_auth,
      rbac:with(perms.WORKERS_WRITE),
      rbac:with(perms.JOBS_READ),
      with_json_body({ { "worker_id", types.valid_text }, { "type", types.valid_text } }),
      with_error_handling("Failed to claim scheduled job", "Failed to claim scheduled job")
    )(function(self)
      return { status = 200, json = { item = service:claim_next_batch(self.params.worker_id, self.params.type) } }
    end)
  )

  return { scheduler_service = service }
end

return Plugin
