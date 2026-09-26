-- Resolves a task's configured "interval" - a plain number of seconds, or a
-- cron expression string (same 5-field grammar as scheduler_tasks.cron_expression,
-- see watchtower_worker_core.cron) - into a concrete next-due unix timestamp.
-- Shared by shared/watchtower_worker_core/loop.lua (standalone worker's
-- persistent loop) and server/workers/observe_pending_worker.lua (embedded
-- worker's per-task ngx.timer scheduling), so the two runtimes can't drift.
local cron = require("watchtower_worker_core.cron")

local M = {}

local function jittered(seconds)
  return seconds * (0.8 + math.random() * 0.4)
end

-- M.validate(value) -> true, nil | false, err_string
function M.validate(value)
  if type(value) == "number" then
    if value <= 0 then
      return false, "must be a positive number of seconds"
    end
    return true, nil
  elseif type(value) == "string" then
    return cron.validate(value)
  end
  return false, "must be a number of seconds or a cron expression string"
end

-- M.next_due(value, from_time, opts) -> unix_time, nil | nil, err_string
-- opts.jitter (default true) applies only to a numeric value - a cron
-- expression is a wall-clock contract (e.g. "run at 03:00"), so it's never
-- jittered.
function M.next_due(value, from_time, opts)
  opts = opts or {}
  if type(value) == "number" then
    local delay = value
    if opts.jitter ~= false then
      delay = jittered(delay)
    end
    return from_time + delay, nil
  elseif type(value) == "string" then
    return cron.next_after(value, from_time)
  end
  return nil, "must be a number of seconds or a cron expression string"
end

return M
