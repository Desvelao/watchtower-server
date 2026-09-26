-- The scheduling engine: validates/derives scheduler_tasks rows, and
-- implements the two operations both worker runtimes drive their own
-- ticks through - fire_due (any role's job, queuing a single pending job
-- per firing without resolving the task's target) and claim_next_batch
-- (a role's priority-pickup, which resolves the task's target at claim
-- time). Generic across all four task types (observe/analyze/notify/deliver):
-- observe/analyze target a set of observables (observable_type_id +
-- observable_ids) and get the resolved set back from the claim; notify
-- targets a notification-policy pass (notify_policy_ids) and gets that scope
-- back from the claim - nothing more. The claim never evaluates anything: an
-- API route must never itself evaluate/decide, so which alerts match which
-- policies is decided entirely worker-side (the "notification_policies_
-- evaluator" role, via shared/watchtower_worker_core/
-- notification_policy_matcher.lua - in-process for the embedded worker, over
-- narrow non-evaluating endpoints for the standalone one), which enqueues its
-- result onto alert_deliveries (a durable queue - see that table's own header
-- comment in config/dataset/init.sql) rather than sending anything. deliver
-- has no target of its own at all - claiming a 'deliver' job just calls
-- delivery_queue_service's own claim_batch (the same claim PUT
-- /api/alert_deliveries/claim uses) and hands its result to the caller, an
-- alternative entry point onto that queue for the "deliver" role alongside
-- its own independent polling (see that table's header comment and each
-- worker runtime's deliver.source config); actually sending is a fully
-- independent role/pipeline - see
-- plugins/notification_channels/services/delivery_queue.lua. Lives once,
-- server-side - the embedded worker calls this directly (no HTTP, same
-- precedent as job_manager/worker_manager in observe_pending_worker.lua);
-- the standalone worker calls it via PUT /api/scheduler/fire-due and
-- .../claim (see plugin.lua).
local db = require("lapis.db")
local route_helpers = require("lib.routes")
local cron = require("watchtower_worker_core.cron")

local M = {}

local TASK_TYPES = { observe = true, analyze = true, notify = true, deliver = true }
local OBSERVABLE_SCOPED_TYPES = { observe = true, analyze = true }

-- The next time (UTC "YYYY-MM-DD HH:MM:SS", the format next_run_at is stored
-- in) `cron_expression` matches after `from` (epoch seconds), or (nil, err)
-- if it can never match again.
local function next_run_after(cron_expression, from)
  local next_ts, err = cron.next_after(cron_expression, from)
  if not next_ts then
    return nil, err
  end
  return os.date("!%Y-%m-%d %H:%M:%S", next_ts)
end

-- observable_type_manager/policy_manager/delivery_queue_service: all
-- optional - only needed by the operations that actually use them.
-- :create/:update need observable_type_manager (observable-scoped tasks) and
-- policy_manager (notify tasks); :claim_next_batch's deliver branch needs
-- delivery_queue_service (alert_deliveries/notification_channels are
-- otherwise reached via raw SQL table names, same as alerts/observations/
-- observables already are below - no model dependency needed for those;
-- delivery_queue_service is the one exception, reused rather than duplicated
-- since it already does its own channel/alert enrichment - see
-- plugins/notification_channels/services/delivery_queue.lua). The embedded
-- worker's own instance (server/workers/observe_pending_worker.lua) only ever
-- calls :fire_due/:claim_next_batch, never :create/:update, so it constructs
-- whichever subset it actually needs - same "constructed twice, once per
-- Lua runtime" precedent as job_manager/worker_manager.
function M.new(task_model, observables_model, observable_type_manager, policy_manager, delivery_queue_service)
  return setmetatable({
    _model = task_model,
    _observables = observables_model,
    _observable_types = observable_type_manager,
    _policies = policy_manager,
    _delivery_queue = delivery_queue_service,
  }, { __index = M })
end

-- Validates+derives a create/update payload into a row ready for
-- Model:create()/item:update(). `existing` is nil on create, the current
-- row on update (`type`/observable_type_id are immutable after creation -
-- see plugins/entities/observables_routes.lua's identical precedent for
-- observable_type_id). Returns (row, nil) | (nil, err_string).
function M:_derive(params, existing)
  local name = params.name or (existing and existing.name)
  if type(name) ~= "string" or name == "" then
    return nil, "name is required"
  end

  local task_type
  if existing then
    if params.type and params.type ~= existing.type then
      return nil, "type is immutable after creation"
    end
    task_type = existing.type
  else
    task_type = params.type or "observe"
    if not TASK_TYPES[task_type] then
      return nil, "type must be one of observe, analyze, notify, deliver"
    end
  end

  local observable_type_id = db.NULL
  local observable_ids_col = db.NULL
  local notify_policy_ids_col = db.NULL

  if OBSERVABLE_SCOPED_TYPES[task_type] then
    if existing then
      if params.observable_type_id and tonumber(params.observable_type_id) ~= existing.observable_type_id then
        return nil, "observable_type_id is immutable after creation"
      end
      observable_type_id = existing.observable_type_id
    else
      observable_type_id = tonumber(params.observable_type_id)
      if not observable_type_id then
        return nil, "observable_type_id is required"
      end
      if not self._observable_types or not self._observable_types:find(observable_type_id) then
        return nil, "Observable type not found: " .. tostring(params.observable_type_id)
      end
    end

    -- Three cases (see this file's own header / CLAUDE.md task write-up):
    -- absent from the payload entirely (params.observable_ids == nil) must
    -- fall back to the existing row's own observable_ids, same as
    -- cron_expression/schedule_type below - otherwise any partial update
    -- that simply doesn't mention this field (a rename, an enabled flip,
    -- ...) would silently widen the task back to the NULL wildcard ("every
    -- enabled observable"). Present-but-empty ({}) is a distinct, deliberate
    -- "reset to wildcard" request and must still resolve to db.NULL, not to
    -- the existing value.
    if params.observable_ids ~= nil then
      if type(params.observable_ids) == "table" and #params.observable_ids > 0 then
        local ids = {}
        for _, v in ipairs(params.observable_ids) do
          table.insert(ids, tonumber(v))
        end
        local count = self._observables:count("observable_type_id = ? and id = any(?)", observable_type_id, db.array(ids))
        if count ~= #ids then
          return nil, "observable_ids must all exist and belong to observable_type_id"
        end
        observable_ids_col = db.array(ids)
      end
      -- else: present but empty - explicit reset, leave observable_ids_col as db.NULL.
    elseif existing and existing.observable_ids and #existing.observable_ids > 0 then
      observable_ids_col = db.array(existing.observable_ids)
    end
  elseif task_type == "notify" then
    -- Same three-case handling as observable_ids above.
    if params.notify_policy_ids ~= nil then
      if type(params.notify_policy_ids) == "table" and #params.notify_policy_ids > 0 then
        local ids = {}
        for _, v in ipairs(params.notify_policy_ids) do
          table.insert(ids, tonumber(v))
        end
        for _, id in ipairs(ids) do
          if not self._policies or not self._policies:find(id) then
            return nil, "Notification policy not found: " .. tostring(id)
          end
        end
        notify_policy_ids_col = db.array(ids)
      end
      -- else: present but empty - explicit reset, leave notify_policy_ids_col as db.NULL.
    elseif existing and existing.notify_policy_ids and #existing.notify_policy_ids > 0 then
      notify_policy_ids_col = db.array(existing.notify_policy_ids)
    end
  end

  local schedule_type = params.schedule_type or (existing and existing.schedule_type)
  if schedule_type ~= "cron" and schedule_type ~= "one_shot" then
    return nil, "schedule_type must be 'cron' or 'one_shot'"
  end

  local cron_expression, run_at, next_run_at
  if schedule_type == "cron" then
    cron_expression = params.cron_expression or (existing and existing.cron_expression)
    if type(cron_expression) ~= "string" or cron_expression == "" then
      return nil, "cron_expression is required when schedule_type is 'cron'"
    end
    local ok_cron, cron_err = cron.validate(cron_expression)
    if not ok_cron then
      return nil, "cron_expression: " .. cron_err
    end
    run_at = db.NULL

    -- Only recompute next_run_at from now() on a genuine create or an
    -- actual schedule change (cron_expression, or switching schedule_type
    -- into "cron" from something else) - or an explicit run_now, handled
    -- below. An update that leaves the schedule itself untouched must
    -- preserve the existing next_run_at as-is, even if it's already
    -- due/overdue: recomputing here would silently jump a due firing
    -- forward past "now", permanently skipping it with no jobs row ever
    -- queued for it (see this file's own header / CLAUDE.md task write-up).
    local schedule_changed = not existing
      or existing.schedule_type ~= "cron"
      or existing.cron_expression ~= cron_expression
    if schedule_changed then
      local next_err
      next_run_at, next_err = next_run_after(cron_expression, os.time())
      if not next_run_at then
        return nil, "cron_expression: " .. next_err
      end
    else
      next_run_at = existing.next_run_at
    end
  else
    run_at = (params.run_at and params.run_at ~= "") and params.run_at
      or (existing and (existing.run_at or existing.next_run_at))
      or db.format_date()
    next_run_at = run_at
    cron_expression = db.NULL
  end

  if params.run_now then
    next_run_at = db.format_date()
  end

  -- `existing.enabled or true` would incorrectly force a disabled
  -- (enabled=false) task back to true on any update that omits `enabled` -
  -- Lua's `or` can't distinguish "false" from "absent". A one-shot task
  -- that fire_due already disabled after firing must stay disabled across
  -- an unrelated update (e.g. a bare run_now, or a name change).
  local enabled = params.enabled
  if enabled == nil then
    if existing then
      enabled = existing.enabled
    else
      enabled = true
    end
  end

  return {
    name = name,
    type = task_type,
    observable_type_id = observable_type_id,
    observable_ids = observable_ids_col,
    notify_policy_ids = notify_policy_ids_col,
    schedule_type = schedule_type,
    cron_expression = cron_expression,
    run_at = run_at,
    enabled = enabled,
    next_run_at = next_run_at,
  }, nil
end

function M:create(params)
  local row, err = self:_derive(params, nil)
  if not row then
    return nil, err
  end
  return self._model:create(row), nil
end

function M:update(id, params)
  local existing = self._model:find({ id = id })
  if not existing then
    return nil, "Scheduler task not found"
  end
  local row, err = self:_derive(params, existing)
  if not row then
    return nil, err
  end
  row.updated_at = db.format_date()
  local ok = existing:update(row)
  if not ok then
    return nil, "Update failed"
  end
  return self._model:find({ id = id }), nil
end

-- Static (not :self) - no DB write, usable directly from the preview-cron
-- route without constructing a service instance, mirrors
-- plugins/rules/services/rule_engine.lua's M.test_expression.
function M.preview_cron(cron_expression, count)
  count = math.min(tonumber(count) or 5, 20)
  local ok, err = cron.validate(cron_expression)
  if not ok then
    return nil, err
  end
  local runs = {}
  local from = os.time()
  for _ = 1, count do
    local next_ts, next_err = cron.next_after(cron_expression, from)
    if not next_ts then
      if #runs == 0 then
        return nil, next_err
      end
      break
    end
    table.insert(runs, os.date("!%Y-%m-%dT%H:%M:%SZ", next_ts))
    from = next_ts
  end
  return runs, nil
end

-- Resolves the current observable set for one observe/analyze task: wildcard
-- (observable_ids NULL/empty) = every enabled Observable of observable_type_id;
-- explicit list = those ids, re-checked (still exist, still belong to
-- observable_type_id, still enabled) since an Observable can change after this
-- row was saved. Called only at claim time (by whichever worker claims the
-- task's queued job) - fire_due itself never resolves or depends on the
-- observable set (see queue_pending_job/fire_due below), so this always reflects
-- the observable set as of the claim, not as of the firing.
function M:_resolve_observables(task)
  if task.observable_ids and #task.observable_ids > 0 then
    return self._observables:select(
      "where observable_type_id = ? and enabled = true and id = any(?)",
      task.observable_type_id, db.array(task.observable_ids)
    )
  end
  return self._observables:select("where observable_type_id = ? and enabled = true", task.observable_type_id)
end

-- Queues (or reuses) a pending `jobs` row: `ON CONFLICT (type, ref_id)
-- WHERE status = 'pending'` targets the jobs_pending_unique_idx partial
-- index, so re-firing a recurring task before its previous pending job has
-- been claimed reuses that same row (DO UPDATE is a no-op touch, just so
-- RETURNING always yields the row's id either way) instead of stacking a
-- duplicate. worker_id stays NULL - unclaimed until :claim_next_batch picks
-- it up. from_scheduler=true marks this row as scheduler-fired (ref_id is a
-- scheduler_tasks.id, not an observables.id) - see config/dataset/init.sql's
-- comment on jobs.from_scheduler. Used for exactly one row per task firing.
local function queue_pending_job(type_, ref_id)
  local rows = db.query([[
    INSERT INTO jobs (type, ref_id, status, from_scheduler)
    VALUES (?, ?, 'pending', true)
    ON CONFLICT (type, ref_id) WHERE status = 'pending' DO UPDATE SET updated_at = NOW()
    RETURNING id
  ]], type_, ref_id)
  return rows[1].id
end

-- The scheduling algorithm itself: finds every due task (enabled,
-- next_run_at <= NOW()), queues a single pending `jobs` row for the firing
-- itself (see queue_pending_job above - type=task.type, ref_id=task.id),
-- and advances next_run_at (cron) or disables (one_shot). Deliberately does
-- NOT resolve the task's target here (observable set, or notify dispatch plan) -
-- fire_due doesn't depend on, or need to know, what that target currently
-- is; that's resolved lazily by whichever worker claims the job (see
-- :claim_next_batch above). Runs at most `max_tasks` per call (default 100)
-- to bound one tick's work. One task's failure is logged and skipped, never
-- aborting the rest of the batch (same skip-and-report philosophy as
-- plugins/rules/services/rules.lua's commit_import). Called directly by the
-- embedded worker's own tick, and via PUT /api/scheduler/fire-due for the
-- standalone worker's tick.
function M:fire_due(max_tasks)
  max_tasks = max_tasks or 100
  local due = self._model:select(
    "where enabled = true and next_run_at <= NOW() order by next_run_at asc limit ?", max_tasks
  )

  local fired = 0

  for _, task in ipairs(due) do
    local ok, err = pcall(function()
      return route_helpers.with_transaction(function()
        queue_pending_job(task.type, task.id)

        local update = { last_run_at = db.format_date(), updated_at = db.format_date() }
        if task.schedule_type == "one_shot" then
          update.enabled = false
        else
          local next_run_at, next_err = next_run_after(task.cron_expression, os.time())
          if not next_run_at then
            -- Pathological expression that can never match again - disable
            -- rather than re-attempting this same expensive scan forever.
            update.enabled = false
            if ngx then
              ngx.log(ngx.ERR, "[scheduler] disabling task " .. tostring(task.id) .. ": " .. tostring(next_err))
            end
          else
            update.next_run_at = next_run_at
          end
        end
        task:update(update)
      end)
    end)

    if ok then
      fired = fired + 1
    elseif ngx then
      ngx.log(ngx.ERR, "[scheduler] fire_due failed for task " .. tostring(task.id) .. ": " .. tostring(err))
    end
  end

  return { fired = fired }
end

-- Atomically claims the single oldest pending `jobs` row of `type_` queued
-- by fire_due (ref_id = a scheduler_tasks.id - fire_due is the only thing
-- that ever creates a status='pending' from_scheduler=true row; ordinary
-- per-observable interval-polling reports go straight to 'triggering' via
-- plugins/jobs/services/jobs.lua's report(), so this can never accidentally
-- pick up an interval-polled observable's row instead), assigning it to worker_id
-- and advancing it to 'triggering'. Resolves the claimed task's current
-- target before returning: observe/analyze get the resolved observable set
-- ({job_id, task_id, type, observables}); notify gets the task's policy
-- scope ({job_id, task_id, type, notify_policy_ids} - nil/absent means every
-- enabled policy), which the caller's own matcher then evaluates against
-- candidate alerts (this claim evaluates nothing - see the header comment);
-- deliver has no scheduler_tasks-owned target at all, so its branch skips
-- loading the task row entirely and just forwards to delivery_queue_service:
-- claim_batch, returning the same {groups = [...]} shape PUT
-- /api/alert_deliveries/claim already returns ({job_id, task_id, type,
-- groups}) - the caller (the "deliver" role) sends via
-- shared/watchtower_worker_core/notification_senders.lua exactly as it would
-- for a direct alert_deliveries claim, then reports both the deliveries
-- outcome (via delivery_queue_service:report, unchanged) and this wrapping
-- job's own ack/error (skip_rollup=true, same as analyze/notify). Returns nil
-- when nothing is pending for `type_`.
function M:claim_next_batch(worker_id, type_)
  if not TASK_TYPES[type_] then
    error({ status = 400, message = "type must be one of observe, analyze, notify, deliver" })
  end

  local rows = db.query([[
    UPDATE jobs
       SET worker_id = ?, status = 'triggering', taken_at = NOW(), updated_at = NOW()
     WHERE id = (
       SELECT id FROM jobs
        WHERE status = 'pending' AND type = ?
        ORDER BY created_at ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED
     )
    RETURNING id, ref_id
  ]], worker_id, type_)

  local row = rows[1]
  if not row then
    return nil
  end

  if type_ == "deliver" then
    local claimed = self._delivery_queue:claim_batch(worker_id)
    return { job_id = row.id, task_id = row.ref_id, type = type_, groups = claimed and claimed.groups or {} }
  end

  local task = self._model:find({ id = row.ref_id })

  if type_ == "notify" then
    local policy_ids = task and task.notify_policy_ids
    return {
      job_id = row.id,
      task_id = row.ref_id,
      type = type_,
      notify_policy_ids = policy_ids and #policy_ids > 0 and policy_ids or nil,
    }
  end

  local observables = task and self:_resolve_observables(task) or {}
  return { job_id = row.id, task_id = row.ref_id, type = type_, observables = observables }
end

return M
