-- Worker-side plugin/task lifecycle: mirrors server/lib/plugins-service.lua's
-- {name, dependencies, setup(app, deps)} shape and topological-sort/DI
-- semantics (a plugin's `setup` return value is handed to whichever later
-- plugin declares it as a dependency, via `deps[dep_name]`), reimplemented
-- standalone here - the standalone worker container has no access to
-- server/lib/, so this is a small, self-contained port of the same
-- algorithm, not a shared `require` - and extended with a second, recurring
-- concept the server's plugin system doesn't need: a plugin's setup() may
-- also register tasks.
--
-- A plugin is { name, dependencies?, setup(context, deps) -> result? }.
-- `context` is the one shared table every plugin/task closes over: config
-- (watchtower_worker_core.runner.build_config's output), connector (the
-- one runtime-transport object - http_provider standalone, embedded_provider
-- embedded - implementing BOTH the wide claim/report interface the role-
-- plugin tasks call (scheduler/observer/analyzer/evaluator/deliver) AND the
-- narrow {heartbeat(fields) -> ok, err; started_at?} contract M._run_heartbeat
-- below calls unconditionally, regardless of which roles are configured -
-- also carries its own connection_type, "http"/"embedded", read by
-- M._run_heartbeat below and by watchtower_observer_web_scraper.plugin's
-- own transport selection), observable_types, post_observation,
-- observer_registry (set by M.build itself, see below - not available
-- until every plugin's setup has run), logger, and whatever else a caller
-- needs downstream tasks to see.
--
-- `result` (all fields optional):
--   tasks                 - array of { name, role?, interval,
--                            retry_interval?, once?, run_on_start?, run,
--                            phase? }, the exact shape
--                            watchtower_worker_core.loop.lua already accepts
--                            (run() -> ok, more; run_on_start, default true,
--                            only meaningful for :run_loop - see loop.lua's
--                            own header comment), plus
--                            `phase` (see watchtower_worker_core.phases -
--                            defaults to phases.DEFAULT when absent):
--                            M.build sorts the whole assembled task list by
--                            it before :run_once/:run_sequence_interval/
--                            :run_loop (or :run, which just dispatches to
--                            one of those three by opts.mode) ever see it,
--                            so a worker with every role enabled
--                            still produces a real
--                            observe -> analyze -> evaluate -> deliver
--                            chain from one :run_once pass, regardless of
--                            plugin registration order. `role` is metadata
--                            only - used by :run_once's roles_filter/
--                            :tasks_by_role, never as an enablement gate: a
--                            plugin decides for ITSELF, via
--                            context.config.roles/has_role, whether it has
--                            anything to register at all.
--   observer_deps          - merged into the one `deps` table passed to
--                            watchtower_worker_core.observer_registry.new
--                            (e.g. fetch_remote_sites/scraper_transport) -
--                            lets an observer-type plugin contribute its own
--                            construction-time deps without this module
--                            needing to know their names.
--   heartbeat_properties    - optional () -> table, merged into the
--                            heartbeat's `properties` payload - replaces
--                            what used to be hardcoded per-role `if
--                            has_role(...)` branches; each plugin now
--                            reports its own counters.
local Logger = require("watchtower_worker_core.logger")
local roles_module = require("watchtower_worker_core.roles")
local schedule = require("watchtower_worker_core.schedule")
local has_role = roles_module.has_role
local KNOWN_ROLES = roles_module.ROLES
local phases = require("watchtower_worker_core.phases")

local M = {}

-- Kahn's-algorithm topological sort, mirroring server/lib/plugins-service.lua
-- exactly: a plugin naming a dependency that isn't registered is a
-- construction-time config mistake (errors immediately, fail fast), as is a
-- dependency cycle.
local function resolve_order(plugins)
  local graph = {}
  local in_degree = {}
  local by_name = {}

  for _, plugin in ipairs(plugins) do
    if by_name[plugin.name] then
      error("lifecycle: duplicate plugin name '" .. tostring(plugin.name) .. "'")
    end
    by_name[plugin.name] = plugin
    graph[plugin.name] = {}
    in_degree[plugin.name] = 0
  end

  for _, plugin in ipairs(plugins) do
    for _, dep in ipairs(plugin.dependencies or {}) do
      if not by_name[dep] then
        error(string.format("lifecycle: plugin '%s' requires missing plugin '%s'", plugin.name, dep))
      end
      table.insert(graph[dep], plugin.name)
      in_degree[plugin.name] = in_degree[plugin.name] + 1
    end
  end

  local queue = {}
  for _, plugin in ipairs(plugins) do
    if in_degree[plugin.name] == 0 then
      table.insert(queue, plugin.name)
    end
  end

  local order = {}
  while #queue > 0 do
    local name = table.remove(queue, 1)
    table.insert(order, name)
    for _, downstream in ipairs(graph[name]) do
      in_degree[downstream] = in_degree[downstream] - 1
      if in_degree[downstream] == 0 then
        table.insert(queue, downstream)
      end
    end
  end

  if #order ~= #plugins then
    error("lifecycle: cycle detected in plugin dependencies")
  end

  return order, by_name
end

-- Sorts `tasks` by (task.phase or phases.DEFAULT), ascending, breaking ties
-- by original registration order - a plain `table.sort` isn't guaranteed
-- stable, and two tasks sharing a phase (e.g. scheduler's fire_due_tasks/
-- reap_stale_jobs, both phases.SCHEDULE) should still run in the order
-- they were registered in. Returns a new array; does not mutate `tasks`.
local function sort_by_phase(tasks)
  local decorated = {}
  for i, task in ipairs(tasks) do
    table.insert(decorated, { task = task, phase = task.phase or phases.DEFAULT, index = i })
  end
  table.sort(decorated, function(a, b)
    if a.phase ~= b.phase then
      return a.phase < b.phase
    end
    return a.index < b.index
  end)
  local sorted = {}
  for _, entry in ipairs(decorated) do
    table.insert(sorted, entry.task)
  end
  return sorted
end

local Lifecycle = {}
Lifecycle.__index = Lifecycle

function Lifecycle:tasks()
  return self._tasks
end

function Lifecycle:task(name)
  for _, task in ipairs(self._tasks) do
    if task.name == name then
      return task
    end
  end
  return nil
end

function Lifecycle:tasks_by_role(role)
  local result = {}
  for _, task in ipairs(self._tasks) do
    if task.role == role then
      table.insert(result, task)
    end
  end
  return result
end

-- Merges every plugin's own heartbeat_properties() contribution into one
-- table (last-registered-plugin wins on a key collision, same precedent as
-- observer_registry.new's duplicate-mapping/self-registration rules
-- elsewhere in this codebase - in practice each plugin owns disjoint keys).
function Lifecycle:heartbeat_properties()
  local properties
  for _, fn in ipairs(self._heartbeat_property_fns) do
    local ok, contributed = pcall(fn)
    if ok and contributed then
      properties = properties or {}
      for k, v in pairs(contributed) do
        properties[k] = v
      end
    end
  end
  return properties
end

-- The standalone worker's persistent loop: watchtower_worker_core.loop.lua's
-- earliest-due-next cooperative scheduler, driving every registered task
-- forever, one at a time. loop.lua itself is unchanged/generic; this is just
-- where the standalone worker gets it from now.
function Lifecycle:run_loop(opts)
  return require("watchtower_worker_core.loop").run(self._tasks, opts)
end

-- Single externally-scheduled pass (cron/systemd timer/k8s CronJob): runs
-- every `once ~= false` task exactly once - a task returning `more` is
-- repeated until it's done, i.e. one full drain. `opts.roles_filter`
-- (optional array of role names) further restricts which roles' tasks run
-- this pass, on top of whichever roles this worker's plugins already
-- registered tasks for - lets one WORKER_CONFIG_FILE back several separate
-- cron entries, one per role. Returns true if every attempted action
-- succeeded (or there was nothing to do), false otherwise.
function Lifecycle:run_once(opts)
  opts = opts or {}
  local logger = opts.logger or self._logger
  local roles_filter = opts.roles_filter
  local clock = opts.clock or os.time
  -- Optional task_due(task, now) -> bool, supplied only by
  -- Lifecycle:run_sequence_interval below (the one caller with in-memory
  -- state that persists across repeated passes). Absent here (mode =
  -- "sequence", --once, cron/systemd/k8s CronJob) every eligible task runs,
  -- unconditionally, exactly as before this option existed - each of those
  -- invocations is its own fresh process with nothing to track due-times
  -- across anyway.
  local task_due = opts.task_due
  local all_ok = true
  local ran = {}

  local function attempt(name, fn)
    table.insert(ran, name)
    local ok, result, more = pcall(fn)
    while ok and result and more do
      ok, result, more = pcall(fn)
    end
    if not ok then
      logger.warn(string.format("run_once: '%s' raised: %s", name, tostring(result)))
    end
    if not (ok and result) then
      all_ok = false
    end
  end

  local declared_roles = self._declared_roles

  local function role_selected(role)
    return declared_roles[role] and (not roles_filter or has_role(roles_filter, role))
  end

  -- A --role/--roles/WORKER_RUN_ONCE_ROLES entry that isn't a known role, or
  -- that this worker has no registered tasks for, would otherwise match
  -- nothing in role_selected above and leave the pass a silent no-op
  -- reporting all_ok=true (e.g. a typo in a cron entry). Fail the pass
  -- instead; the remaining, valid roles in the filter still run.
  if roles_filter then
    attempt("role_filter", function()
      local valid = true
      for _, role in ipairs(roles_filter) do
        if not has_role(KNOWN_ROLES, role) then
          logger.warn(string.format(
            "run_once: unknown role '%s' in role filter (known: %s)",
            role, table.concat(KNOWN_ROLES, ", ")
          ))
          valid = false
        elseif not declared_roles[role] then
          logger.warn(string.format(
            "run_once: role '%s' in role filter has no registered tasks on this worker",
            role
          ))
          valid = false
        end
      end
      return valid
    end)
  end

  for _, task in ipairs(self._tasks) do
    if task.once ~= false and (not task.role or role_selected(task.role)) then
      if not task_due or task_due(task, clock()) then
        attempt(task.name, task.run)
      end
    end
  end

  local summary = string.format("run_once: ran [%s], all_ok=%s", table.concat(ran, ", "), tostring(all_ok))
  if all_ok then
    logger.info(summary)
  else
    logger.warn(summary)
  end

  return all_ok
end

-- Repeated externally-unscheduled batching: runs a full :run_once pass, then
-- sleeps until the next due time computed from opts.interval (a plain number
-- of seconds or a cron expression - see watchtower_worker_core.schedule),
-- then repeats forever. Every task still gets attempted in phase order on
-- every pass (the exact same semantics :run_once already has) UNLESS its own
-- `interval` field says it isn't due yet - tracked here, in memory, across
-- passes (see task_due below), the same task.interval/retry_interval fields
-- :run_loop already reads for its own per-task scheduling. A task's own
-- interval can only ever make it run LESS often than the pass cadence
-- (opts.interval) - never more - since a pass, and hence any chance for that
-- task to run at all, only happens that often to begin with. A task with no
-- interval of its own (nil) is always due, unchanged from before this option
-- existed.
function Lifecycle:run_sequence_interval(opts)
  opts = opts or {}
  local logger = opts.logger or self._logger
  local clock = opts.clock or os.time
  local sleep = opts.sleep or require("watchtower_worker_core.loop").default_sleep
  local interval = opts.interval

  local valid, err = schedule.validate(interval)
  if not valid then
    error("lifecycle: run_sequence_interval requires a valid opts.interval (seconds or cron expression): " .. tostring(err))
  end

  local jitter = opts.jitter ~= false

  -- Mirrors loop.lua's own MAX_BACKOFF_SECONDS - not exported from there, so
  -- duplicated rather than plumbing an export just for this one constant.
  local MAX_BACKOFF_SECONDS = 365 * 24 * 3600

  -- Keyed by task table identity; lives only for this one :run_sequence_interval
  -- call's lifetime (in-process state, same as loop.lua's own `states`) - a
  -- worker restart simply starts every task due again, same as today. Named
  -- distinctly from the pass-level `next_due` local further below (a
  -- timestamp, not a table) to avoid any confusion between the two.
  local task_next_due = {}

  local function task_due(task, now)
    local due_at = task_next_due[task]
    if due_at and now < due_at then
      return false
    end
    local value = task.interval or interval
    local due, sched_err = schedule.next_due(value, now, { jitter = false })
    if due then
      task_next_due[task] = due
    else
      -- A cron expression that passed validation at boot can still fail
      -- here if it never matches (see loop.lua's own identical handling) -
      -- isolate the bad task rather than crashing the whole pass loop.
      logger.warn(string.format("run_sequence_interval: task '%s' scheduling failed: %s - will not run again", task.name, tostring(sched_err)))
      task_next_due[task] = now + MAX_BACKOFF_SECONDS
    end
    return true
  end

  while not (opts.should_stop and opts.should_stop()) do
    self:run_once({ roles_filter = opts.roles_filter, logger = logger, clock = clock, task_due = task_due })

    if opts.should_stop and opts.should_stop() then
      break
    end

    local now = clock()
    local next_due, sched_err = schedule.next_due(interval, now, { jitter = jitter })
    if not next_due then
      logger.warn("run_sequence_interval: scheduling failed, stopping: " .. tostring(sched_err))
      return false
    end
    sleep(next_due - now)
  end

  return true
end

-- Wraps all three run styles behind one entry point, keyed by opts.mode
-- ("sequence" | "sequence-interval" | "loop") - takes the same single `opts`
-- table every other Lifecycle:run_* method takes (rather than a separate
-- positional argument), so a caller builds one opts table (mode, plus
-- whichever of roles_filter/interval/clock/sleep/logger/should_stop the
-- chosen mode actually reads - see worker/lua/main.lua for how config.mode,
-- defaulting to "loop", flows into opts.mode) and hands it straight to
-- :run(opts).
local RUN_MODES = {
  sequence = "run_once",
  ["sequence-interval"] = "run_sequence_interval",
  loop = "run_loop",
}

function Lifecycle:run(opts)
  opts = opts or {}
  local method_name = RUN_MODES[opts.mode]
  if not method_name then
    error(string.format(
      "lifecycle: unknown mode '%s' (expected one of: %s)",
      tostring(opts.mode), table.concat({ "sequence", "sequence-interval", "loop" }, ", ")
    ))
  end
  return self[method_name](self, opts)
end

-- Recomputes context.config.capabilities/reportable_config_json from
-- context.observer_registry (see config_report.lua's own header comment -
-- an observer's own capabilities can change silently between heartbeats,
-- e.g. once a sites_source="remote" observer's own maintenance task
-- refreshes its site list), merges every plugin's heartbeat_properties()
-- plus context.extra_heartbeat_properties() (an optional escape hatch for a
-- runtime-specific counter no role/plugin owns - e.g. the embedded worker's
-- own observations_analyzed, bumped by its ingest-on-observe path), and
-- reports through context.connector - the one place both worker runtimes
-- heartbeat/self-register through now (previously two separately
-- maintained implementations: processors.lua's do_heartbeat for standalone,
-- observe_pending_worker.lua's send_heartbeat for embedded).
--
-- context._worker_registered starts false and flips true on the first
-- successful heartbeat - see e.g. plugins/observer.lua's observe_interval
-- task, which waits for it before posting an observation (observations.worker
-- has an FK to workers).
function M._run_heartbeat(context, lifecycle)
  if not (context.connector and context.connector.heartbeat) then
    return true
  end
  if context._worker_registered == nil then
    context._worker_registered = false
  end

  if context.observer_registry then
    require("watchtower_worker_core.config_report").apply_registry(context.config, context.observer_registry)
  end

  local now = os.time()
  local properties = lifecycle:heartbeat_properties()
  if context.extra_heartbeat_properties then
    local extra = context.extra_heartbeat_properties()
    if extra then
      properties = properties or {}
      for k, v in pairs(extra) do
        properties[k] = v
      end
    end
  end

  local ok, err = context.connector:heartbeat({
    connection_type = context.connector.connection_type or "http",
    version = context.config.version,
    capabilities = context.config.capabilities,
    uptime_seconds = now - (context.connector.started_at or now),
    config = context.config.reportable_config_json,
    roles = context.config.roles or { "observer" },
    properties = properties,
  })
  if ok then
    context._worker_registered = true
  else
    context.logger.warn("heartbeat failed, will retry next tick: " .. tostring(err))
  end
  return ok
end

-- Builds the Lifecycle: runs every plugin's setup(context, deps) in
-- dependency order (heartbeat is scheduled first - see below - so
-- registration precedes any job report), merges tasks/observer_deps/
-- heartbeat_properties, then builds context.observer_registry from the
-- merged observer_deps (plus context.config.observer.observers, the
-- standalone worker's own per-instance observer config array - unused/nil
-- for the embedded worker, which hardcodes its one instance's config
-- directly into whichever plugin registers it) and finally merges its own
-- :maintenance_tasks() (the per-INSTANCE counterpart to a plugin's own
-- per-TYPE `tasks` - see observer_registry.lua) into the task list too.
function M.build(plugins, context)
  if not context.config then
    error("lifecycle.build: context.config is required")
  end
  context.logger = context.logger or Logger.new(context.logger_name or "watchtower-worker", context.config and context.config.log_level)

  -- Forward-declared: the heartbeat task's `run` closure below captures
  -- this local by reference (a Lua upvalue), so it sees the fully-built
  -- Lifecycle by the time it's actually invoked, even though it's created
  -- before `lifecycle` itself is assigned, further down.
  local lifecycle

  local tasks = {}

  if context.connector and context.connector.heartbeat then
    table.insert(tasks, {
      name = "heartbeat",
      phase = phases.HEARTBEAT,
      interval = context.config.heartbeat_interval,
      -- A failed heartbeat retries after this backoff rather than waiting a
      -- full heartbeat_interval, so registration isn't delayed by a blip.
      -- Its own dedicated config field (always a plain number, never a
      -- cron expression - see config.interval/heartbeat_interval, which
      -- both allow cron and so can't be reused here without breaking the
      -- retry_interval validation below).
      retry_interval = context.config.heartbeat_retry_interval,
      run = function() return M._run_heartbeat(context, lifecycle) end,
    })
  end

  local observer_registry = require("watchtower_worker_core.observer_registry")

  -- A plugin registers its own observer type(s) explicitly, during its own
  -- setup() below (context.observer_types:register_type(name, builder_fn)),
  -- into a registry scoped to THIS build call - not
  -- watchtower_worker_core.observer_registry's own module-global
  -- self-registration table, so two Lifecycle.build calls in the same Lua
  -- VM never share/leak registrations, and a plugin's full contract lives
  -- entirely inside its own setup() call. See observer_registry.new_type_registry.
  context.observer_types = observer_registry.new_type_registry()

  local order, by_name = resolve_order(plugins)

  local results = {}
  local observer_deps = {}
  local heartbeat_property_fns = {}
  local declared_roles = {}

  for _, name in ipairs(order) do
    local plugin = by_name[name]
    local plugin_deps = {}
    for _, dep in ipairs(plugin.dependencies or {}) do
      plugin_deps[dep] = results[dep]
    end

    -- pcall'd: one buggy/misconfigured plugin (built-in or third-party)
    -- must not take down every other plugin's tasks along with it - the
    -- same "a construction-time failure degrades gracefully rather than
    -- aborting everything" philosophy as the observer_registry.new pcall
    -- below.
    local setup_ok, result = true, nil
    if plugin.setup then
      setup_ok, result = pcall(plugin.setup, context, plugin_deps)
      if not setup_ok then
        context.logger.warn(string.format("lifecycle: plugin '%s' setup failed: %s", name, tostring(result)))
        result = nil
      end
    end
    results[name] = result

    if result then
      for _, task in ipairs(result.tasks or {}) do
        table.insert(tasks, task)
        if task.role then
          declared_roles[task.role] = true
        end
      end
      if result.observer_deps then
        for k, v in pairs(result.observer_deps) do
          observer_deps[k] = v
        end
      end
      if result.heartbeat_properties then
        table.insert(heartbeat_property_fns, result.heartbeat_properties)
      end
    end
  end

  -- pcall'd: an observer type's constructor can raise on a construction-time
  -- fetch failure (e.g. watchtower_observer_web_scraper.observers.web_scraper's
  -- sites_source="remote", see its own header comment) - a config/network
  -- problem, not a reason to take down the whole worker (every other
  -- plugin's tasks would otherwise never get to run at all). Falls back to
  -- an empty registry (no observer types registered) rather than a nil
  -- context.observer_registry, so every task above that already closed over
  -- `context` still finds a well-formed (if empty) registry to call.
  local registry_ok, registry_or_err = pcall(
    observer_registry.new,
    context.config.observer and context.config.observer.observers,
    context.observer_types:builders(),
    observer_deps
  )
  if registry_ok then
    context.observer_registry = registry_or_err
  else
    context.logger.warn("failed to build observer registry, falling back to an empty one: " .. tostring(registry_or_err))
    context.observer_registry = observer_registry.new(nil, nil, {})
  end

  for _, task in ipairs(context.observer_registry:maintenance_tasks()) do
    table.insert(tasks, task)
  end

  -- Sorted by phase (see watchtower_worker_core.phases) before either
  -- :run_once or :run_loop (via loop.lua's own "declared order breaks
  -- ties" rule) ever sees this array - registration order alone (plugin
  -- setup order, then observer_registry:maintenance_tasks()) is otherwise
  -- unrelated to the order a fully-enabled worker's roles need to run in
  -- for one pass to produce a full observe -> analyze -> evaluate ->
  -- deliver chain.
  tasks = sort_by_phase(tasks)

  -- Each task's interval/retry_interval is either a number of seconds or
  -- (interval only - see watchtower_worker_core.schedule) a cron
  -- expression string. Validated once here, for every task from every
  -- plugin, rather than in each plugin's own setup() - covers both
  -- runtimes for free, since standalone's lifecycle:run_loop and the
  -- embedded worker's own timer-arming loop (observe_pending_worker.lua)
  -- both consume this same tasks array. A bad task is dropped with a
  -- logged warning rather than aborting the whole build, matching the
  -- degrade-gracefully convention already used above for plugin setup()
  -- failures and observer-registry construction failures.
  local valid_tasks = {}
  for _, task in ipairs(tasks) do
    local ok, err = schedule.validate(task.interval)
    local retry_ok, retry_err = true, nil
    if ok and task.retry_interval ~= nil then
      retry_ok = type(task.retry_interval) == "number" and task.retry_interval > 0
      retry_err = "retry_interval must be a positive number of seconds"
    end
    if ok and retry_ok then
      table.insert(valid_tasks, task)
    else
      context.logger.warn(string.format(
        "lifecycle: task '%s' has an invalid interval, dropping it: %s",
        task.name, tostring(err or retry_err)
      ))
    end
  end
  tasks = valid_tasks

  lifecycle = setmetatable({
    _tasks = tasks,
    _results = results,
    _heartbeat_property_fns = heartbeat_property_fns,
    _declared_roles = declared_roles,
    _logger = context.logger,
  }, Lifecycle)

  return lifecycle
end

return M
