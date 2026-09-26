-- Executes one pending scheduler-fired "observe" batch job per call: claims
-- the single job a scheduler_tasks firing queued (see
-- plugins/scheduler/services/scheduler.lua's fire_due/claim_next_batch),
-- observes every Observable in its resolved set, and reports exactly ONE final
-- status + summary message on that one job - never a job per Observable. Kept
-- separate from processors.lua's process_observable (the observer.source =
-- "interval" flow), which processes one Observable per run and reports a
-- job per Observable - there's no natural place in that flow to suppress N
-- per-observable job reports in favor of one aggregate report.
--
-- `deps` supplies the transport each worker runtime already has:
--   claim()                                      -> {job_id, task_id, observables} | nil
--   observe_observable(observable)                -> status, message, properties
--                                                    (shared/watchtower_worker_core/processors.lua's
--                                                    observe_observable)
--   post_observation(observable, properties)      -> ok, err
--                                                    (NOT job report - see below)
--   report_result(task_id, message, result) -> ok, err
--   report_error(task_id, message)          -> ok, err
--
-- `post_observation` deliberately does not report a per-observable job (unlike
-- the ordinary observer.source="interval" flow's process_observable/notifier -
-- see shared/watchtower_worker_core/provider_http.lua's M:post_observation and
-- server/workers/observe_pending_worker.lua's post_observation local) - the
-- whole point of this poller is that no per-observable `jobs` row is ever
-- created for a scheduler-fired batch. report_result/report_error must
-- pass skip_rollup=true (see plugins/jobs/services/jobs.lua's M:report
-- header comment) since task_id is a scheduler_tasks.id, not an observables.id.

local common = require("watchtower_worker_core.pollers.common")

local M = {}

-- Returns two values: (found, reported_ok).
-- found is true if a pending batch job was found (and handled, regardless
-- of individual observables' outcomes), false if there was nothing
-- pending. reported_ok is the success of the final report_result call
-- (always true when found is false, since there's nothing to report) -
-- surfaced so shared/watchtower_worker_core/processors.lua's one-shot run_once path can
-- tell a claimed-but-unreported batch apart from "nothing pending" for its
-- own process exit code; the persistent-loop caller in
-- do_run_pending_observe_batch's loop task ignores this 2nd value, unchanged.
function M.poll_and_run(deps, logger)
  local batch = common.claim("batch_observe_poller", deps, logger)
  if not batch then
    return false, true
  end

  local succeeded, failed = 0, {}

  for _, observable in ipairs(batch.observables) do
    local observe_ok, status, observe_message, properties = pcall(deps.observe_observable, observable)
    if observe_ok and status == "observed" then
      local post_ok, post_err = deps.post_observation(observable, properties)
      if post_ok then
        succeeded = succeeded + 1
      else
        table.insert(failed, { id = observable.id, name = observable.name, reason = post_err })
      end
    else
      local reason = (not observe_ok) and status or observe_message
      table.insert(failed, { id = observable.id, name = observable.name, reason = reason })
    end
  end

  local total = #batch.observables
  local message = common.summarize("Observed", succeeded, failed, total)
  local ok, err = deps.report_result(batch.task_id, message, {
    succeeded = succeeded,
    failed = #failed,
    total = total,
    failures = failed,
  })
  common.check_report("batch_observe_poller", "result for task " .. tostring(batch.task_id), ok, err, logger)

  return true, ok
end

return M
