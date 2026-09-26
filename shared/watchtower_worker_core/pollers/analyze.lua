-- Executes one pending scheduler-fired "analyze" batch job per call: claims
-- the single job a scheduler_tasks firing queued (see
-- plugins/scheduler/services/scheduler.lua's fire_due/claim_next_batch),
-- re-runs rule matching against each Observable in its resolved set (no
-- re-observe), and reports exactly ONE final status + summary message on
-- that one job - never a job per Observable. Mirrors
-- shared/watchtower_worker_core/pollers/observe.lua's shape exactly; see that module's header
-- comment for why this is a claim -> process -> one-final-report poller, not
-- the per-observable observer.source="interval" flow.
--
-- `deps` supplies the transport each worker runtime already has:
--   claim()                          -> {job_id, task_id, observables} | nil
--   analyze_observable(observable)   -> {matches, ok}
--                                       (embedded: server/plugins/entities/
--                                       services/reanalyze.lua, called
--                                       in-process; standalone:
--                                       client-side matching over HTTP -
--                                       see shared/watchtower_worker_core/provider_http.lua's
--                                       M:analyze_observable)
--   report_result(task_id, message, result) -> ok, err
--   report_error(task_id, message)          -> ok, err
--
-- report_result/report_error must pass skip_rollup=true (see
-- plugins/jobs/services/jobs.lua's M:report header comment) since task_id
-- is a scheduler_tasks.id, not an observables.id.

local common = require("watchtower_worker_core.pollers.common")

local M = {}

-- Returns two values: (found, reported_ok) - see
-- shared/watchtower_worker_core/pollers/observe.lua's poll_and_run header comment for the
-- exact contract (found is whether a pending batch job existed, reported_ok
-- is the final report_result call's success; always true when found is
-- false). Surfaced for shared/watchtower_worker_core/processors.lua's one-shot run_once
-- path; the persistent-loop caller ignores the 2nd value, unchanged.
function M.poll_and_run(deps, logger)
  local batch = common.claim("batch_analyze_poller", deps, logger)
  if not batch then
    return false, true
  end

  local succeeded, failed, matches_total = 0, {}, 0

  for _, observable in ipairs(batch.observables) do
    local ok, result, err = pcall(deps.analyze_observable, observable)
    if ok and result and result.ok then
      succeeded = succeeded + 1
      matches_total = matches_total + (result.matches or 0)
    else
      local reason = ok and (err and tostring(err) or "analysis failed") or tostring(result)
      table.insert(failed, { id = observable.id, name = observable.name, reason = reason })
    end
  end

  local total = #batch.observables
  local message = common.summarize("Analyzed", succeeded, failed, total)
  local report_ok, err = deps.report_result(batch.task_id, message, {
    succeeded = succeeded,
    failed = #failed,
    total = total,
    failures = failed,
    matches = matches_total,
  })
  common.check_report("batch_analyze_poller", "result for task " .. tostring(batch.task_id), report_ok, err, logger)

  return true, report_ok
end

return M
