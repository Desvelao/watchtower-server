-- Thin wrapper around the `wake_events` lua_shared_dict (declared in
-- server/nginx.conf) - a small, fixed set of "go poll now" counters, one per
-- claim-based worker role (observe/analyze/notify/deliver/observer_test).
-- Bumped wherever a route creates a new claimable row (see
-- plugins/observer_configs/plugin.lua's test routes,
-- plugins/scheduler/services/scheduler.lua's queue_pending_job,
-- plugins/notification_channels/services/delivery_queue.lua's M:enqueue),
-- read by GET /api/workers/:id/events (plugins/workers/plugin.lua) and by
-- the embedded worker's own cross-process fan-in
-- (server/workers/observe_pending_worker.lua) - a lua_shared_dict is shared
-- across every nginx worker process on this host, so it doesn't matter which
-- process bumped a key vs. which is reading it. Deliberately carries no
-- payload of its own beyond a monotonic counter - every consumer still
-- claims through its own existing endpoint; this only ever signals
-- "something changed for this key", never what, keeping every evaluation/
-- claim decision exactly where it already lives.
local M = {}

function M.bump(key)
  ngx.shared.wake_events:incr(key, 1, 0)
end

function M.get(key)
  return ngx.shared.wake_events:get(key) or 0
end

return M
