-- Generic, worker-agnostic cooperative task loop: runs an ordered list of
-- tasks forever, each on its own interval, one at a time. This is what
-- drives the standalone worker (see runner.lua). Each task has its own
-- interval, so a role's interval can be shorter or longer than any
-- other role's (a single shared tick would force every role's interval up
-- to a multiple of it).
--
-- A task is `{ name, interval, retry_interval?, run_on_start?, run }`:
--   run()  -> ok, more
--     ok     truthy = success. falsy (or a raised error) = failure, logged at
--            warn, and rescheduled after `retry_interval or interval`.
--     more   truthy = "there is probably more work right now" - the task is
--            due again immediately instead of after `interval` (used by
--            observer.source="interval", which drains one observable per
--            run). Every other task that's already due still runs in
--            between, so a long drain can't starve e.g. the heartbeat.
--   interval - either a plain number of seconds (start-to-start: the next
--            run is due `interval` after this one STARTED, so a task that
--            takes longer than its interval is simply due again as soon as
--            it finishes), with +/-20% jitter so several workers on one
--            interval don't hit the server in lockstep - or a cron
--            expression string (watchtower_worker_core.cron's grammar),
--            pinning the task to actual wall-clock times instead, never
--            jittered. See watchtower_worker_core.schedule, which resolves
--            either form into a next-due timestamp.
--   retry_interval - seconds only (a retry delay is "N seconds from now",
--            not a wall-clock time, so cron doesn't apply here).
--   run_on_start - default true/absent: the task is due immediately at
--            boot, like every task always was before this field existed.
--            `false`: the task's FIRST run waits for `interval` (or the
--            next cron match) to elapse, computed via
--            watchtower_worker_core.schedule the same way every later
--            reschedule already is - see M.run below.
--
-- Everything runs sequentially in one thread: a slow task delays the others
-- (accepted trade-off), but no task is ever skipped or run twice at once.
-- Every task is due at start, in declared order (so put the heartbeat
-- first), unless it sets run_on_start = false.
--
-- opts (all optional):
--   clock()        -> seconds, default os.time. Pass socket.gettime for
--                     sub-second precision.
--   sleep(seconds) -> default ngx.sleep when running under OpenResty, else
--                     a shell `sleep`. Pass socket.sleep to avoid the fork.
--   logger         -> anything with :warn-style `.warn(msg)`.
--   jitter         -> default true.
--   should_stop()  -> checked once per iteration; a truthy return ends the
--                     loop (for tests - the worker itself runs forever).

local schedule = require("watchtower_worker_core.schedule")

local M = {}

-- How far out to push a task whose scheduling failed at runtime (see
-- M.run below), so it stops being picked without needing a real "disabled"
-- state on top of the states array - 1 year is far longer than any process
-- is expected to run uninterrupted.
local MAX_BACKOFF_SECONDS = 365 * 24 * 3600

local function default_sleep(seconds)
  if ngx and ngx.sleep then
    ngx.sleep(seconds)
  else
    os.execute(string.format("sleep %s", tonumber(seconds) or 1))
  end
end

function M.run(tasks, opts)
  opts = opts or {}
  local clock = opts.clock or os.time
  local sleep = opts.sleep or default_sleep
  local logger = opts.logger
  local jitter = opts.jitter ~= false

  if not tasks or #tasks == 0 then
    error("watchtower_worker_core.loop: at least one task is required")
  end

  local function warn(message)
    if logger and logger.warn then
      logger.warn(message)
    end
  end

  local start = clock()
  local states = {}
  for i, task in ipairs(tasks) do
    local next_due = start
    if task.run_on_start == false then
      local due, sched_err = schedule.next_due(task.interval, start, { jitter = jitter })
      if due then
        next_due = due
      else
        warn(string.format(
          "loop: task '%s' initial scheduling failed: %s - running at start instead",
          task.name, tostring(sched_err)
        ))
      end
    end
    states[i] = { task = task, next_due = next_due }
  end

  while not (opts.should_stop and opts.should_stop()) do
    local now = clock()

    -- Earliest-due task wins; declared order breaks ties (strict `<`).
    local picked
    local earliest
    for _, state in ipairs(states) do
      if not earliest or state.next_due < earliest then
        earliest = state.next_due
      end
      if state.next_due <= now and (not picked or state.next_due < picked.next_due) then
        picked = state
      end
    end

    if not picked then
      sleep(earliest - now)
    else
      local task = picked.task
      local ok, result, more = pcall(task.run)
      local succeeded = ok and result and true or false
      if not ok then
        warn(string.format("loop: task '%s' raised: %s", task.name, tostring(result)))
      elseif not result then
        warn(string.format("loop: task '%s' failed, retrying in %ss", task.name, tostring(task.retry_interval or task.interval)))
      end

      if succeeded and more then
        -- Stamped with the time the run FINISHED, not `now`: any other task
        -- that became due while this one ran has a smaller next_due and so
        -- goes first - otherwise a long drain would keep winning ties.
        picked.next_due = clock()
      else
        local value = succeeded and task.interval or (task.retry_interval or task.interval)
        local next_due, sched_err = schedule.next_due(value, now, { jitter = jitter })
        if next_due then
          picked.next_due = next_due
        else
          -- A cron expression that passed validation at boot (see
          -- lifecycle.lua) can still fail here if it never matches within
          -- cron.lua's scan bound (e.g. "0 0 30 2 *" - Feb never has a
          -- 30th). Isolate the bad task rather than crashing the whole
          -- loop or busy-retrying forever: push it far out and move on.
          warn(string.format("loop: task '%s' scheduling failed: %s - task will not run again", task.name, tostring(sched_err)))
          picked.next_due = now + MAX_BACKOFF_SECONDS
        end
      end
    end
  end
end

-- Exported so other run styles needing the same OpenResty-or-shell fallback
-- (e.g. watchtower_worker_core.lifecycle's :run_sequence_interval) don't
-- duplicate it.
M.default_sleep = default_sleep

return M
