-- The fixed "go poll now" wake-key set (see server/lib/wake_events.lua's own
-- header comment) and the task-role name each maps to. A wake key isn't
-- always spelled the same as the worker role that owns it - e.g. "observe"
-- wakes the "observer" role's own task, "notify" wakes "evaluator"'s -
-- watchtower_worker_core.lifecycle's Lifecycle:tasks_by_role keys off a
-- task's own `role` field, which every built-in role plugin
-- (plugins/observer.lua, .../analyzer.lua, .../evaluator.lua,
-- .../deliver.lua) sets to the WORKER role name, not the wake key; only
-- "deliver" happens to be spelled the same both ways. "observer_test" has no
-- worker role at all (it's a task tag - see plugins/events.lua's own header
-- comment), so it maps to itself.
--
-- Shared by watchtower_worker_core.plugins.events (the standalone worker's
-- long-poll task) and server/workers/observe_pending_worker.lua's own
-- cross-process fan-in (the embedded worker never polls itself, but still
-- needs to know the same key set and the same role mapping), so this is
-- defined exactly once.
local has_role = require("watchtower_worker_core.roles").has_role

local M = {}

M.TASK_ROLE_FOR_KEY = {
  observe = "observer",
  analyze = "analyzer",
  notify = "evaluator",
  deliver = "deliver",
  observer_test = "observer_test",
}

-- The task role name that owns wake key `key` - see TASK_ROLE_FOR_KEY above.
function M.task_role_for(key)
  return M.TASK_ROLE_FOR_KEY[key] or key
end

-- The wake keys a worker built from `config` (watchtower_worker_core.runner's
-- build_config output) cares about - derived from which roles it declared
-- and which `source` mode each is in. Only "queue"-sourced roles (and the
-- independent observer_test poller, which has never depended on the
-- "observer" role at all) ever gain anything from a wake; "interval"-sourced
-- roles sweep unconditionally on their own cadence regardless, so waking
-- them would find nothing new to do.
function M.for_config(config)
  local keys = {}
  if has_role(config.roles, "observer") and config.observer.source == "queue" then
    table.insert(keys, "observe")
  end
  if has_role(config.roles, "analyzer") and config.analyzer.source == "queue" then
    table.insert(keys, "analyze")
  end
  if has_role(config.roles, "evaluator") and config.evaluator.source == "queue" then
    table.insert(keys, "notify")
  end
  if has_role(config.roles, "deliver") and config.deliver.source == "deliveries" then
    table.insert(keys, "deliver")
  end
  if config.observer.test_poll and config.observer.test_poll.enabled then
    table.insert(keys, "observer_test")
  end
  return keys
end

return M
