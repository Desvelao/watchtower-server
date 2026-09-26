-- Heartbeat and the ad-hoc scraper-test poller both moved out of this
-- module: heartbeat is now watchtower_worker_core.lifecycle's own
-- M._run_heartbeat (kernel-intrinsic, scheduled directly by
-- lifecycle.build, not a per-role task), and the test poller is now the
-- watchtower_observer_web_scraper plugin's own task (see that package's
-- plugin.lua) - it's specific to the web_scraper observer type, not
-- generic worker-core behavior.

-- Best-effort scheduler tick - the embedded worker instead runs this via
-- its own ngx.timer.every (see server/workers/observe_pending_worker.lua's
-- poll_and_fire_due_tasks). Only scheduled for the "scheduler" role, on
-- ctx.config.scheduler.interval (see build_tasks). Decoupled from the
-- observer/analyzer roles entirely - this is the "scheduler" role's ONLY
-- job (plus reaping stale jobs, below).
local function do_fire_due_tasks(ctx, http_provider, utils)
  local scheduler_poller = require("watchtower_worker_core.pollers.scheduler")
  local ok, fired = scheduler_poller.poll_and_run({
    fire_due_tasks = function() return http_provider:fire_due_tasks() end,
  }, utils.logger)
  if ok then
    ctx._jobs_fired_total = (ctx._jobs_fired_total or 0) + fired
  end
  return ok
end

-- Best-effort periodic housekeeping tick: resets any `jobs` row stuck in
-- 'triggering' past ctx.config.scheduler.reap_stale.timeout_seconds back to
-- 'error' - see shared/watchtower_worker_core/pollers/reap_stale.lua and
-- server/plugins/jobs/services/jobs.lua's reap_stale. Only scheduled for the
-- "scheduler" role, on ctx.config.scheduler.reap_stale.interval - a worker
-- that evaluates scheduler_tasks is also the one responsible for keeping the
-- shared `jobs` queue healthy. Redundant reaps across multiple
-- scheduler-role workers are harmless no-ops (nothing to reap once the first
-- one runs), the same idempotency precedent fire_due's own pending-row dedup
-- relies on. The embedded worker instead runs this via its own
-- ngx.timer.every (see server/workers/observe_pending_worker.lua's
-- start_stale_job_reap).
local function do_reap_stale_jobs(ctx, http_provider, utils)
  local reap_stale_poller = require("watchtower_worker_core.pollers.reap_stale")
  local ok = reap_stale_poller.poll_and_run({
    reap_stale_jobs = function(timeout_seconds) return http_provider:reap_stale_jobs(timeout_seconds) end,
  }, utils.logger, ctx.config.scheduler.reap_stale.timeout_seconds)
  return ok
end

-- Best-effort periodic housekeeping tick, the "evaluator" role's
-- counterpart to do_reap_stale_jobs above: resets any `alert_deliveries`
-- row stuck in 'triggering' past ctx.config.evaluator.reap_stale.timeout_seconds
-- back to 'error' - see shared/watchtower_worker_core/pollers/reap_stale_deliveries.lua
-- and server/plugins/notification_channels/services/delivery_queue.lua's
-- reap_stale. "evaluator" owns this (not "deliver") because it's the role
-- that *produces* this queue's rows via its own enqueue pass, mirroring why
-- "scheduler" - not "observer"/"analyzer" - owns jobs' own reap_stale.
local function do_reap_stale_deliveries(ctx, http_provider, utils)
  local reap_stale_poller = require("watchtower_worker_core.pollers.reap_stale_deliveries")
  local ok = reap_stale_poller.poll_and_run({
    reap_stale_deliveries = function(timeout_seconds) return http_provider:reap_stale_deliveries(timeout_seconds) end,
  }, utils.logger, ctx.config.evaluator.reap_stale.timeout_seconds)
  return ok
end

-- Resolves the Observable's observable type (ctx.observable_types, a
-- shared/watchtower_worker_core/observable_type_cache.lua instance) and dispatches the actual observe
-- through ctx.observer_registry (shared/watchtower_worker_core/observer_registry.lua), which routes
-- by observable-type name to whatever observer implementation is configured
-- for it (e.g. watchtower_observer_web_scraper.observers.web_scraper). Returns (status, message,
-- properties) - status is "observed" (properties populated) or "error"
-- (message populated). Shared by process_observable below (the ordinary
-- observer.source="interval" flow) and shared/watchtower_worker_core/pollers/observe.lua (a
-- scheduler-fired batch, which observes each Observable in its resolved set
-- and reports one aggregate result instead of a job per Observable) - the
-- only place the actual observe-dispatch logic lives. Declared before
-- do_run_pending_observe_batch below, which closes over it, since a Lua
-- closure can only capture a local that's already in scope at the point the
-- function literal is created.
local function observe_observable(observable, ctx, utils)
  local observable_type, observable_type_err = ctx.observable_types:get(observable.observable_type_id)

  if not observable_type then
    return "error", string.format(
      "failed to resolve observable type %s: %s",
      tostring(observable.observable_type_id),
      tostring(observable_type_err)
    )
  end

  -- pcall's 2nd/3rd return slots double as (a) the single error value
  -- when ok == false, or (b) observer_registry:run's own (properties, err)
  -- pair when ok == true.
  local ok, result, run_err = pcall(function()
    return ctx.observer_registry:run(observable, observable_type)
  end)

  if not ok then
    return "error", tostring(result)
  elseif not result then
    return "error", run_err or "observe ran but no properties were extracted"
  end
  return "observed", nil, result
end

-- The claim-based batch tasks below (observe/analyze/evaluate/notify) all
-- run one pollers/*.lua tick the same way - this is that shared shape.
--
-- run_claim_poller requires `poller_module`, runs its poll_and_run(deps,
-- logger) under pcall, and reduces the outcome to the boolean a loop task
-- returns: false if the poll raised, or a batch was found but its final
-- report failed to reach the server; true if there was nothing pending, or a
-- batch was found and successfully reported. `name` (the calling function's
-- own) prefixes the warning.
local function run_claim_poller(name, poller_module, deps, utils)
  local poller = require(poller_module)
  local ok, found, reported_ok = pcall(poller.poll_and_run, deps, utils.logger)
  if not ok then
    utils.logger.warn(name .. ": poll failed: " .. tostring(found))
    return false
  end
  return (not found) or reported_ok
end

-- The claim/report_result/report_error transport for a scheduler-fired batch
-- job of `type_` (a scheduler_tasks type: observe/analyze/notify), each
-- ack'd with `action`. Reports carry skip_rollup=true (see
-- http_provider:report_batch_result) since the job's ref_id is a
-- scheduler_tasks.id. `on_result(result)` (optional) sees every successful
-- report's structured result before it's sent.
local function batch_transport(http_provider, type_, action, on_result)
  return {
    claim = function() return http_provider:claim_batch(type_) end,
    report_result = function(task_id, message, result)
      if on_result then
        on_result(result)
      end
      return http_provider:report_batch_result(type_, task_id, action, message, result)
    end,
    report_error = function(task_id, message)
      return http_provider:report_batch_error(type_, task_id, message)
    end,
  }
end

-- Best-effort scheduler-batch poll - the embedded worker instead runs this
-- via its own ngx.timer.every (see server/workers/observe_pending_worker.lua's
-- poll_pending_observe_batch). Only scheduled for the "observer" role AND
-- config.observer.source == "queue" (see build_tasks) - a scheduler-only or
-- interval-mode worker never claims these - on
-- ctx.config.observer.interval. Returns false if the poll itself
-- errored, or a batch was found but its final report failed to reach the
-- server; true if there was nothing pending, or a batch was found and
-- successfully reported.
--
-- Waits for a successful heartbeat first (`ctx._worker_registered`), same
-- guard and same reason as do_run_interval_observe below: claiming a batch
-- assigns it to this worker (jobs.worker_id, an FK to `workers`), and
-- deps.post_observation ultimately posts to /api/observations, whose
-- `worker` column is also an FK to `workers` - either write can fail before
-- the server has ever seen this worker. Returning true (a no-op success)
-- rather than claiming and losing the batch's scrape work to a doomed
-- post_observation lets the loop simply retry at the next normal
-- interval, exactly like the interval path.
local function do_run_pending_observe_batch(ctx, http_provider, utils)
  if not ctx._worker_registered then
    return true
  end
  local deps = batch_transport(http_provider, "observe", "observed")
  deps.observe_observable = function(observable) return observe_observable(observable, ctx, utils) end
  deps.post_observation = function(observable, observation_result)
    return http_provider:post_observation(observable, observation_result)
  end
  return run_claim_poller("do_run_pending_observe_batch", "watchtower_worker_core.pollers.observe", deps, utils)
end

-- Best-effort scheduler-batch poll for the "analyzer" role when
-- analyzer.source == "queue" (the default) - the embedded worker instead runs
-- this via its own ngx.timer.every (see server/workers/observe_pending_worker.lua's
-- poll_pending_analyze_batch). Runs on ctx.config.analyzer.interval (see
-- build_tasks). See do_run_interval_analyze_all below for the
-- analyzer.source == "interval" sibling - an explicit either/or, mirroring
-- observer.source.
--
-- do_run_pending_analyze_batch is also called directly by run_once below
-- for a one-shot pass (only when the "analyzer" role is declared and
-- analyzer.source == "queue"). Same return-value contract as
-- do_run_pending_observe_batch above.
--
-- Same ctx._worker_registered guard as do_run_pending_observe_batch above,
-- for the same reason: claiming a batch assigns it to this worker
-- (jobs.worker_id, an FK to `workers`) before the server is guaranteed to
-- have ever seen it.
local function do_run_pending_analyze_batch(ctx, http_provider, utils)
  if not ctx._worker_registered then
    return true
  end
  local deps = batch_transport(http_provider, "analyze", "analyzed")
  deps.analyze_observable = function(observable) return http_provider:analyze_observable(observable) end
  return run_claim_poller("do_run_pending_analyze_batch", "watchtower_worker_core.pollers.analyze", deps, utils)
end

-- The action for analyzer.source = "interval" (both run_once and the
-- persistent loop): drains every currently enabled observable exactly once
-- via http_provider's own independent pager (NOT M.next's cursor - see
-- shared/watchtower_worker_core/provider_http.lua's new_enabled_observables_pager), calling
-- :analyze_observable(observable) per observable. Re-running rule matching has no
-- per-observable jobs row to report, so a plain loop with a log-only
-- summary is enough. Unlike observer.source = "interval" (which processes
-- one observable per run, since it's observing a live external site), this
-- does a complete pass every call - analyze only re-runs rule matching
-- against already-stored rows, which is cheap, idempotent, and has no
-- external rate limit to respect.
local function do_run_interval_analyze_all(ctx, http_provider, utils)
  local pager = http_provider:new_enabled_observables_pager()
  local succeeded, failed, matches_total, total = 0, 0, 0, 0

  while true do
    local page, page_err = pager()
    if not page then
      if page_err then
        utils.logger.warn("do_run_interval_analyze_all: failed to fetch observables: " .. tostring(page_err))
        return false
      end
      break
    end
    for _, observable in ipairs(page) do
      total = total + 1
      local ok, result, err = pcall(function() return http_provider:analyze_observable(observable) end)
      if ok and result and result.ok then
        succeeded = succeeded + 1
        matches_total = matches_total + (result.matches or 0)
      else
        failed = failed + 1
        utils.logger.warn(string.format(
          "do_run_interval_analyze_all: observable %s failed: %s",
          tostring(observable.id), ok and (err and tostring(err) or "analysis failed") or tostring(result)
        ))
      end
    end
  end

  utils.logger.info(string.format(
    "do_run_interval_analyze_all: analyzed %d/%d observables (%d failed, %d matches)",
    succeeded, total, failed, matches_total
  ))
  return failed == 0
end

-- Best-effort scheduler-batch poll for the
-- "evaluator" role, same shape as
-- do_run_pending_analyze_batch. The claim only hands out the notify task's
-- policy scope (an API route never evaluates anything); the matching and the
-- enqueueing onto alert_deliveries are http_provider's own
-- evaluate_notify_policies - client-side, see
-- shared/watchtower_worker_core/notification_policy_matcher.lua. This tick
-- never sends anything itself (see the "deliver" role's own, fully
-- independent do_run_pending_notify_batch below).
--
-- do_run_pending_evaluate_batch is also called directly by run_once below
-- for a one-shot pass (only when the "evaluator"
-- role is declared). Same return-value contract as
-- do_run_pending_observe_batch above.
--
-- Same ctx._worker_registered guard as do_run_pending_observe_batch above,
-- for the same reason: claiming a batch assigns it to this worker
-- (jobs.worker_id, an FK to `workers`) before the server is guaranteed to
-- have ever seen it.
local function do_run_pending_evaluate_batch(ctx, http_provider, utils)
  if not ctx._worker_registered then
    return true
  end
  local deps = batch_transport(http_provider, "notify", "evaluated", function(result)
    ctx._deliveries_enqueued_total = (ctx._deliveries_enqueued_total or 0) + (result.enqueued or 0)
  end)
  deps.evaluate = function(policy_ids) return http_provider:evaluate_notify_policies(policy_ids) end
  return run_claim_poller("do_run_pending_evaluate_batch", "watchtower_worker_core.pollers.evaluate", deps, utils)
end

-- "evaluator" role, "interval" mode - same either/or
-- as do_run_interval_analyze_all/do_run_pending_analyze_batch above,
-- mirroring analyzer.source's own split exactly. The same client-side pass
-- do_run_pending_evaluate_batch runs per claimed task, just over every
-- enabled policy with no scheduler_tasks/jobs row involved.
local function do_run_interval_evaluate_notify(ctx, http_provider, utils)
  local outcome, complete = http_provider:evaluate_notify_policies()
  if not outcome then
    utils.logger.warn("do_run_interval_evaluate_notify: failed: " .. tostring(complete))
    return false
  end
  ctx._deliveries_enqueued_total = (ctx._deliveries_enqueued_total or 0) + (outcome.enqueued or 0)
  utils.logger.info("do_run_interval_evaluate_notify: " .. require("watchtower_worker_core.pollers.evaluate").summarize(outcome))
  return complete ~= false
end

-- Best-effort alert_deliveries-queue drain for the "deliver" role, on
-- ctx.config.deliver.interval, same shape as do_run_pending_analyze_batch.
-- ctx.config.deliver.source picks which of two ways this role gets its
-- work, mirroring ctx.config.observer.source's "queue"|"interval" split
-- for the observer role (see shared/watchtower_worker_core/runner.lua's
-- build_config):
--   "deliveries" (default): claims/reports directly against the
--     alert_deliveries queue (PUT /api/alert_deliveries/claim|report - see
--     plugins/notification_channels/services/delivery_queue.lua), fully
--     independent of scheduler_tasks/jobs - the mode that lets multiple
--     deliver workers drain the queue concurrently (FOR UPDATE SKIP
--     LOCKED).
--   "queue": claims a scheduler_tasks type='deliver' job instead
--     (PUT /api/scheduler/claim, the same route/claim_next_batch the other
--     three scheduler-fired roles already use) - claim_next_batch's
--     'deliver' branch internally calls that same delivery_queue claim_batch
--     and returns its {groups = [...]} straight through, so `send` below
--     needs no branch at all; only claim/report do. Reports twice: the
--     individual alert_deliveries outcomes via the same report_deliveries
--     call as "deliveries" mode, plus the wrapping job's own ack/error
--     (skip_rollup=true, via report_batch_result/report_batch_error - the
--     same two-report pattern analyze/notify-evaluator batch jobs already
--     use).
-- `send` is shared/watchtower_worker_core/notification_senders.lua -
-- identical, DB-free code on both worker runtimes and both source modes,
-- since all policy matching already happened server-side, earlier, inside
-- the evaluator's own claim.
--
-- do_run_pending_notify_batch is also called directly by run_once below
-- for a one-shot pass (only when the "deliver" role is declared). Same
-- return-value contract as do_run_pending_observe_batch above.
local function do_run_pending_notify_batch(ctx, http_provider, utils)
  local notification_senders = require("watchtower_worker_core.notification_senders")
  -- ctx.notification_sender, if the runtime supplies one (the embedded
  -- worker injects one built on cosocket-based transports, since LuaSocket
  -- can't run inside an nginx worker). Otherwise a configured instance so
  -- email channels see this worker's own resolved SMTP relay
  -- (ctx.config.deliver.smtp, see shared/watchtower_worker_core/runner.lua's
  -- build_config) - no transport override here, so email falls through to
  -- pling.notifiers.email's own LuaSocket/LuaSec path, same as the standalone
  -- worker's plain Lua 5.1 process already uses for webhook/discord's
  -- default transport. Built once per ctx, not per tick: the config it
  -- captures never changes at runtime.
  if not ctx.notification_sender then
    ctx.notification_sender =
      notification_senders.new(nil, ctx.config and ctx.config.deliver and ctx.config.deliver.smtp)
  end
  local sender = ctx.notification_sender

  -- Adds this batch's successes to the heartbeat's deliveries_sent counter
  -- and returns whether EVERY delivery in it succeeded.
  local function tally(channel_results)
    local all_ok = true
    for _, r in ipairs(channel_results or {}) do
      if r.ok then
        ctx._deliveries_sent_total = (ctx._deliveries_sent_total or 0) + 1
      else
        all_ok = false
      end
    end
    return all_ok
  end

  local claim, report
  if ctx.config.deliver.source == "queue" then
    local job_id
    claim = function()
      local item, err = http_provider:claim_batch("deliver")
      if item then
        job_id = item.task_id
      end
      return item, err
    end
    report = function(channel_results)
      local batch_ok = tally(channel_results)
      local report_ok, report_err = http_provider:report_deliveries(channel_results)
      if job_id then
        local job_ok, job_err
        if batch_ok then
          job_ok, job_err = http_provider:report_batch_result(
            "deliver", job_id, "delivered", "delivered batch",
            { sent = #(channel_results or {}) }
          )
        else
          job_ok, job_err = http_provider:report_batch_error(
            "deliver", job_id, "one or more deliveries in this batch failed"
          )
        end
        if not job_ok then
          utils.logger.warn(
            "do_run_pending_notify_batch: failed to report deliver job "
              .. tostring(job_id) .. ": " .. tostring(job_err)
          )
          return false, report_err or job_err
        end
      end
      return report_ok, report_err
    end
  else
    claim = function() return http_provider:claim_deliveries() end
    report = function(channel_results)
      tally(channel_results)
      return http_provider:report_deliveries(channel_results)
    end
  end

  return run_claim_poller(
    "do_run_pending_notify_batch",
    "watchtower_worker_core.pollers.notify",
    { claim = claim, send = sender.send, report = report },
    utils
  )
end

-- The observer.source = "interval" per-observable flow: observe via
-- observe_observable, then post the resulting observation via
-- ctx.post_observation - the same no-job-report primitive
-- do_run_pending_observe_batch (observer.source = "queue") already uses
-- for each observable in its claimed batch, see
-- shared/watchtower_worker_core/provider_http.lua's M:post_observation and
-- server/workers/observe_pending_worker.lua's embedded_provider:post_observation.
-- No per-observable `jobs` row is ever created or updated here (same
-- "no per-observable jobs row to report" precedent as
-- do_run_interval_analyze_all above). Shared by do_run_interval_observe
-- below (standalone) and the embedded worker's own interval tick
-- (server/workers/observe_pending_worker.lua's poll_pending_observe_interval).
-- Returns true only if the observation was actually posted.
local function process_observable(observable, ctx, utils)
  local logger = utils.logger
  local id = tostring(observable.id)

  local status, message, properties = observe_observable(observable, ctx, utils)
  if status ~= "observed" then
    logger.warn(string.format("[id=%s] - Observe failed: %s", id, tostring(message)))
    return false
  end

  local post_ok, post_err = ctx.post_observation(observable, properties)
  if not post_ok then
    logger.warn(string.format("[id=%s] - Failed to post observation: %s", id, tostring(post_err)))
    return false
  end
  logger.info(string.format("[id=%s] - [action=observed]", id))
  return true
end

-- Standalone "observer" role, observer.source = "interval": observes ONE
-- observable per call (http_provider:next()'s stalest-first paging), and
-- returns (true, true) so the loop calls it again straight away while
-- observables remain, or (true, false) once the sweep is exhausted (next()
-- returns nil and restarts from the top on its following call), at which
-- point the task waits observer.interval. run_once repeats it the same
-- way until `more` is false, which turns it into one bounded full pass.
-- A single observable failing is logged by process_observable and does not
-- fail the task (same best-effort philosophy as before); only a failure to
-- FETCH the next observable does.
--
-- Waits for a successful heartbeat first (`ctx._worker_registered`):
-- ctx.post_observation ultimately posts to /api/observations, whose
-- `worker` column has an FK to `workers`, so posting from a worker the
-- server has never seen would fail.
local function do_run_interval_observe(ctx, http_provider, utils)
  if not ctx._worker_registered then
    return true, false
  end
  local observable, next_err = http_provider:next()
  if not observable then
    if next_err then
      utils.logger.warn("do_run_interval_observe: failed to fetch next observable: " .. tostring(next_err))
      return false
    end
    return true, false
  end
  process_observable(observable, ctx, utils)
  return true, true
end

return {
  process_observable = process_observable,
  observe_observable = observe_observable,
  -- The per-role tick functions watchtower_worker_core/plugins/*.lua
  -- schedule, each (ctx, provider, utils) -> boolean (ctx/provider being
  -- whatever built the enclosing plugin's context/context.connector).
  -- Exported so a runtime that drives its own timers (the embedded worker's
  -- ngx.timer.every) runs the very same functions instead of
  -- re-implementing them - only `provider` (the transport: in-process
  -- services vs. HTTP) differs.
  do_fire_due_tasks = do_fire_due_tasks,
  do_reap_stale_jobs = do_reap_stale_jobs,
  do_reap_stale_deliveries = do_reap_stale_deliveries,
  do_run_pending_observe_batch = do_run_pending_observe_batch,
  do_run_interval_observe = do_run_interval_observe,
  do_run_pending_analyze_batch = do_run_pending_analyze_batch,
  do_run_interval_analyze_all = do_run_interval_analyze_all,
  do_run_pending_evaluate_batch = do_run_pending_evaluate_batch,
  do_run_interval_evaluate_notify = do_run_interval_evaluate_notify,
  do_run_pending_notify_batch = do_run_pending_notify_batch,
}
