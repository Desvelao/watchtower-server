-- Built-in "events" plugin: long-polls GET /api/workers/:id/events (server
-- side: server/plugins/workers/plugin.lua, backed by server/lib/wake_events.lua)
-- and, on a wake, immediately runs whichever already-registered task(s) own
-- that wake key - see watchtower_worker_core.lifecycle's
-- Lifecycle:tasks_by_role (through watchtower_worker_core.wake_keys'
-- task_role_for mapping - a wake key isn't always spelled the same as the
-- task role that owns it, see that module's own header comment), which this
-- reuses rather than re-implementing any role's own claim/report logic.
-- Standalone (HTTP) only - the embedded worker has no polling loop of its
-- own to add a task to, so it instead reads the same server-side wake
-- counters directly via its own cross-process fan-in (see
-- server/workers/observe_pending_worker.lua).
--
-- Purely a latency optimization: every woken role's own task still runs on
-- its normal interval regardless (this plugin never touches that
-- scheduling), so a dropped/missed wake just means "back to today's polling
-- latency", never "the work is lost".
local phases = require("watchtower_worker_core.phases")
local wake_keys = require("watchtower_worker_core.wake_keys")

local Plugin = { name = "events" }

function Plugin.setup(context)
  -- context.connector.poll_events only exists on provider_http.lua - the
  -- embedded worker's own connector has no HTTP transport at all (see this
  -- file's own header comment), so this plugin simply registers nothing for
  -- it, same "a plugin decides for itself whether it has anything to
  -- register" convention every other built-in role plugin already follows.
  if not (context.connector and context.connector.poll_events) then
    return nil
  end
  -- Explicit off-switch (config.events.enabled, see runner.lua's own
  -- header comment on it) - checked before even deriving the key list
  -- below, since there's no point computing it for a worker that's opted
  -- out entirely.
  if context.config.events and context.config.events.enabled == false then
    return nil
  end

  local keys = wake_keys.for_config(context.config)
  if #keys == 0 then
    return nil
  end

  local since = {}
  local events_config = context.config.events or {}
  local wait_seconds = events_config.wait or 25

  return {
    tasks = {
      {
        name = "events_poll",
        phase = phases.DEFAULT,
        -- Only ever consulted after a failed poll (loop.lua's own
        -- retry_interval handling) - a successful poll always returns
        -- (true, true) below, so the loop re-issues it immediately
        -- regardless of this value; the long-poll's own `wait` is what
        -- paces this task under normal operation, not its interval.
        interval = events_config.retry_interval or 5,
        run = function()
          local key, seq, err = context.connector:poll_events(keys, since, wait_seconds)
          if err then
            context.logger.warn("events_poll: " .. tostring(err))
            return false
          end
          if key then
            since[key] = seq
            -- Reuses whatever task(s) already own this role - e.g. the exact
            -- same do_run_pending_notify_batch closure deliver.lua's own
            -- task already runs on its normal interval. Wrapped in pcall
            -- (mirroring loop.lua's own per-task pcall) since this is an
            -- out-of-band invocation loop.lua itself never sees.
            for _, task in ipairs(context.lifecycle:tasks_by_role(wake_keys.task_role_for(key))) do
              local ok, result = pcall(task.run)
              if not ok then
                context.logger.warn(
                  string.format("events_poll: woken task '%s' raised: %s", task.name, tostring(result))
                )
              end
            end
            -- A real wake fired - loop back immediately in case more than
            -- one is already queued. On a plain long-poll timeout (key ==
            -- nil), do NOT request "more": under loop.lua's interleaved
            -- dispatcher that would be harmless (every other due task still
            -- gets its turn), but Lifecycle:run_once's `attempt()` helper
            -- busy-loops a task synchronously as long as it returns
            -- `more`, with no interleaving - always requesting "more" here
            -- would starve every other task (heartbeat, observe, test_poll,
            -- ...) forever under mode="sequence"/"sequence-interval".
            return true, true
          end
          return true, false
        end,
      },
    },
  }
end

return Plugin
