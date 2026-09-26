-- The "scheduler" role's tick: asks the server to evaluate every due
-- scheduler_tasks row and queue the resulting pending `jobs` rows (see
-- plugins/scheduler/services/scheduler.lua's fire_due). Unlike the claim-
-- based pollers in this directory (observe/analyze/evaluate/notify), there
-- is no claim/process/report split -
-- fire_due already does all of its work (find due tasks, queue a job per
-- firing, advance next_run_at) server-side in one call, so this poller's
-- only job is to invoke it and account for how many tasks fired.
--
-- `deps` supplies the transport each worker runtime already has:
--   fire_due_tasks() -> {fired = N}
--
-- Given its own dedicated module (mirroring pollers/observe.lua,
-- pollers/analyze.lua, pollers/evaluate.lua, pollers/notify.lua) so every
-- one of the five worker roles is an independently-requireable unit with
-- the same poll_and_run(deps, logger) shape, even though this one's `deps`
-- has only a single function.

local M = {}

-- Returns two values: (ok, fired) - ok is false if fire_due_tasks raised or
-- returned `nil, err` (the standalone provider reports HTTP failures that
-- way rather than raising), true otherwise (with `fired` defaulting to 0
-- when the result didn't carry one). Callers that only care about
-- success/failure (as watchtower_worker_core.processors' do_fire_due_tasks
-- does) can ignore the second value.
function M.poll_and_run(deps, logger)
  local ok, result, err = pcall(deps.fire_due_tasks)
  if not ok or result == nil then
    logger.warn("scheduler_poller: fire_due_tasks failed: " .. tostring(ok and err or result))
    return false, 0
  end
  return true, (result and result.fired) or 0
end

return M
