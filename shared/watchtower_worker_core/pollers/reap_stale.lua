-- Periodic housekeeping tick, run by a worker that declares the "scheduler"
-- role (see processors.lua's build_tasks and the embedded worker's
-- start_stale_job_reap): asks the server to reset any `jobs` row stuck in
-- 'triggering' past `timeout_seconds` back to 'error' (see
-- server/plugins/jobs/services/jobs.lua's reap_stale) - a claim whose
-- worker crashed, hung, or lost connectivity mid-observe would otherwise sit
-- in 'triggering' forever, permanently blocking any future claim for that
-- same (worker_id, type, ref_id) via jobs_active_unique_idx (a partial
-- unique index on jobs(worker_id, type, ref_id) WHERE status='triggering').
--
-- Same shape as pollers/scheduler.lua (a single injected function, no
-- claim/report split - the server does all the work in one call), given its
-- own dedicated module for the same reason: every worker-facing operation
-- gets one independently-requireable poller, used identically (modulo
-- transport) by both the embedded worker (calls the jobs service directly)
-- and the standalone worker (PUT /api/jobs/reap-stale).
--
-- `deps` supplies the transport each worker runtime already has:
--   reap_stale_jobs(timeout_seconds) -> {reaped = N, items = [...]}
local M = {}

-- Returns two values: (ok, reaped) - ok is false if reap_stale_jobs raised
-- or returned `nil, err` (the standalone provider reports HTTP failures that
-- way rather than raising), true otherwise (with `reaped` defaulting to 0
-- when the result didn't carry one). A reap event (reaped > 0) is itself a
-- signal something upstream hung, so it's logged even on success - unlike
-- most pollers here, which stay silent when there's simply nothing to do.
function M.poll_and_run(deps, logger, timeout_seconds)
  local ok, result, err = pcall(deps.reap_stale_jobs, timeout_seconds)
  if not ok or result == nil then
    logger.warn("reap_stale_poller: reap_stale_jobs failed: " .. tostring(ok and err or result))
    return false, 0
  end

  local reaped = (result and result.reaped) or 0
  if reaped > 0 then
    logger.warn("reap_stale_poller: reaped " .. reaped .. " stale triggering job(s)")
  end
  return true, reaped
end

return M
