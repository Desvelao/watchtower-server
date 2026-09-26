-- Executes one pending scheduler-fired "notify" batch job per call: claims
-- the single job a scheduler_tasks firing queued (see
-- plugins/scheduler/services/scheduler.lua's fire_due/claim_next_batch),
-- evaluates it, and reports the outcome. This is the entire
-- "evaluator" role's job. The claim itself only hands
-- out the task's policy scope (an API route never evaluates anything); the
-- alert/policy matching AND the enqueueing onto alert_deliveries are
-- `deps.evaluate` - the worker's own
-- shared/watchtower_worker_core/notification_policy_matcher.lua, in-process
-- for the embedded worker and over HTTP for the standalone one. Actually
-- sending a notification is a fully independent role/pipeline with its own
-- claim/report cycle against alert_deliveries directly - see
-- shared/watchtower_worker_core/pollers/notify.lua.
--
-- `deps` supplies the transport each worker runtime already has:
--   claim() -> {job_id, task_id, notify_policy_ids?} | nil
--     (notify_policy_ids absent/empty = every enabled policy)
--   evaluate(notify_policy_ids) -> {enqueued, alerts_matched}, ok
--     (`ok` false = the pass only partly completed; the outcome is what it
--     did accomplish)
--   report_result(task_id, message, result) -> ok, err
--   report_error(task_id, message)          -> ok, err
--
-- report_result/report_error must pass skip_rollup=true (see
-- plugins/jobs/services/jobs.lua's M:report header comment) since task_id
-- is a scheduler_tasks.id, not an observables.id.

local common = require("watchtower_worker_core.pollers.common")

local M = {}

-- The report message for a pass's outcome - one format for this poller and
-- the "interval" mode's log line (processors.lua).
function M.summarize(outcome)
  return string.format(
    "Enqueued %d delivery(ies) (%d alert(s) matched)", outcome.enqueued or 0, outcome.alerts_matched or 0
  )
end

-- Returns two values: (found, reported_ok) - see
-- shared/watchtower_worker_core/pollers/observe.lua's poll_and_run header comment for the
-- exact contract. Surfaced for shared/watchtower_worker_core/processors.lua's one-shot
-- run_once path; the persistent-loop caller ignores the 2nd value,
-- unchanged.
function M.poll_and_run(deps, logger)
  local batch = common.claim("batch_evaluate_poller", deps, logger)
  if not batch then
    return false, true
  end

  local eval_ok, outcome, complete = pcall(deps.evaluate, batch.notify_policy_ids)
  local report_ok, err
  if not eval_ok or type(outcome) ~= "table" then
    -- evaluate raised (outcome is the error), or returned no outcome at all.
    report_ok, err = deps.report_error(
      batch.task_id,
      "notify evaluation failed: " .. (eval_ok and "no outcome returned" or tostring(outcome))
    )
  elseif complete == false then
    report_ok, err = deps.report_error(
      batch.task_id,
      M.summarize(outcome) .. " - the pass did not complete (see the worker log)"
    )
  else
    report_ok, err = deps.report_result(batch.task_id, M.summarize(outcome), {
      enqueued = outcome.enqueued,
      alerts_matched = outcome.alerts_matched,
    })
  end
  common.check_report("batch_evaluate_poller", "result for task " .. tostring(batch.task_id), report_ok, err, logger)

  return true, report_ok
end

return M
