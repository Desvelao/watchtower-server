-- Routes an Observable to the observer implementation registered for its
-- observable type: a plain `type string -> handler` Lua table, populated
-- from a flat, worker-local config array of
-- `{id, type, ...type-specific fields}`.
--
-- An observer TYPE (the builder_fn behind one `type` string, e.g.
-- "web_scraper") is registered via M.register_type(name, builder_fn),
-- called by that type's own module at require time - see M.register_type
-- below. This is the extension seam an external consumer uses to plug in
-- an entirely new kind of observer (an RSS poller, an API poller, ...)
-- without touching this module or any of the generic pipeline/poller code
-- that calls into it.
--
-- Unlike a boolean-rule-matching fan-out (`routes[].match`, useful when one
-- alert can reasonably go to several destinations), dispatch here is
-- simpler: an Observable belongs to exactly one Observable Type, so
-- `observer_config.observable_type` (a server-side observable_types.name)
-- is itself the registry key - no rule expression needed.
--
-- An observer instance's full contract: `:run(observable, observable_type)`
-- (required), and two optional methods aggregated generically across every
-- registered observer, with no self-registration table of their own -
-- `:capabilities()` (see M:capabilities below) and
-- `:reportable_config(observer_config)` (see M:reportable_observers below,
-- consumed by watchtower_worker_core.config_report for heartbeat
-- self-reporting). An observer type that implements neither just gets a
-- generic fallback for each.
local M = {}

local BASE_OBSERVER_FIELDS = { "id", "type", "observable_type" }

local function pick(tbl, keys)
  if type(tbl) ~= "table" then
    return nil
  end
  local result = {}
  for _, key in ipairs(keys) do
    if tbl[key] ~= nil then
      result[key] = tbl[key]
    end
  end
  return result
end

-- Self-registration: an observer-type module (e.g. watchtower_observer_web_scraper.observers.web_scraper)
-- calls M.register_type(name, builder_fn) once, at its own require time,
-- instead of every worker entry point hand-building a {type_name -> builder_fn}
-- table. Mirrors watchtower_observer_web_scraper.scraper_creator's own webscraper.sites:register(name, fn)
-- pattern already used elsewhere in this codebase. Re-registering the same
-- name silently overwrites (last-wins) - same precedent, no duplicate error.
M._registered_types = {}

function M.register_type(name, builder_fn)
  M._registered_types[name] = builder_fn
end

-- Sorted list of every self-registered type name - for discovery/debugging
-- or a heartbeat-style self-report of what this worker process can handle.
function M.registered_types()
  local names = {}
  for name in pairs(M._registered_types) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

-- A per-build alternative to the module-global self-registration above:
-- watchtower_worker_core.lifecycle.build creates one of these per
-- Lifecycle.build call and hands it to every plugin via context.observer_types,
-- so a plugin registers its observer type explicitly, inside its own
-- setup(context, deps) call (`context.observer_types:register_type(name,
-- builder_fn)`), instead of relying on a require-time side effect on the
-- shared M._registered_types table above - each build gets its own
-- independent {type -> builder} table, exactly the shape M.new's own
-- `observer_type_builders` parameter already accepts.
function M.new_type_registry()
  local builders = {}
  return {
    register_type = function(_, name, builder_fn)
      builders[name] = builder_fn
    end,
    builders = function()
      return builders
    end,
  }
end

-- observers_config: array of {id, type, observable_type, ...type-specific fields}
--   (WORKER_CONFIG_FILE's `observers` key)
-- observer_type_builders: optional plain table {type_name = function(observer_config, deps) -> instance},
--   checked before the self-registered types above - lets a caller override/shadow
--   a globally-registered type for one particular registry instance (e.g. tests).
--   Pass nil to rely entirely on self-registered types.
-- deps: passed through to every builder as builder(observer_config, deps) -
--   e.g. `fetch_remote_sites` (a sites_source = "remote" observer's site-list
--   loader) and `scraper_transport` (the embedded worker's non-blocking
--   fetch); see watchtower_observer_web_scraper.observers.web_scraper for what it reads.
--
-- An unknown `type` or a duplicate `observable_type` mapping is a construction-
-- time config mistake and raises immediately (fail fast on bad config, not
-- at first use) - unlike a missing
-- observer at dispatch time (see :run below), which is expected/routine.
function M.new(observers_config, observer_type_builders, deps)
  local by_observable_type = {}
  local observers_ordered = {}

  for _, observer_config in ipairs(observers_config or {}) do
    local builder = (observer_type_builders and observer_type_builders[observer_config.type])
      or M._registered_types[observer_config.type]
    if not builder then
      error(string.format(
        "observer_registry: unknown observer type '%s' (observer id '%s')",
        tostring(observer_config.type),
        tostring(observer_config.id)
      ))
    end

    if by_observable_type[observer_config.observable_type] then
      error(string.format(
        "observer_registry: observable_type '%s' already has an observer registered (duplicate observer id '%s')",
        tostring(observer_config.observable_type),
        tostring(observer_config.id)
      ))
    end

    local instance = builder(observer_config, deps)
    by_observable_type[observer_config.observable_type] = instance
    table.insert(observers_ordered, { config = observer_config, instance = instance })
  end

  return setmetatable({ _by_observable_type = by_observable_type, _observers = observers_ordered }, { __index = M })
end

-- Returns (properties, nil) | (nil, err). A missing registration for
-- observable_type.name is a soft-fail (logged/reported as a per-observable error by
-- the caller, not a crash), since an observable type an
-- operator hasn't configured an observer for yet (it can be created via the
-- UI at any time) shouldn't take down observing for every other type this
-- worker does handle.
function M:run(observable, observable_type)
  local observer = observable_type and self._by_observable_type[observable_type.name]
  if not observer then
    return nil, string.format(
      "no observer registered for observable type '%s'",
      observable_type and observable_type.name or tostring(observable.observable_type_id)
    )
  end
  return observer:run(observable, observable_type)
end

-- Aggregated across every registered observer that implements
-- :capabilities(), for heartbeat self-reporting.
function M:capabilities()
  local all = {}
  for _, observer in pairs(self._by_observable_type) do
    if observer.capabilities then
      for _, c in ipairs(observer:capabilities()) do
        table.insert(all, c)
      end
    end
  end
  table.sort(all)
  return all
end

-- Aggregated across every registered observer, in the order given to
-- M.new - the safe-to-report subset of each one's own config, for
-- heartbeat self-reporting (see watchtower_worker_core.config_report's
-- apply_registry/build_reportable_config). An observer type opts in by
-- implementing :reportable_config(observer_config) (see e.g.
-- watchtower_observer_web_scraper's "web_scraper" type); one that doesn't
-- falls back to a generic, minimal allow-list (BASE_OBSERVER_FIELDS)
-- rather than reporting nothing for it.
function M:reportable_observers()
  local result = {}
  for _, entry in ipairs(self._observers) do
    if entry.instance.reportable_config then
      table.insert(result, entry.instance:reportable_config(entry.config))
    else
      table.insert(result, pick(entry.config, BASE_OBSERVER_FIELDS))
    end
  end
  return result
end

-- Aggregated across every registered observer that implements
-- :maintenance_tasks() - the per-INSTANCE counterpart to a
-- watchtower_worker_core.lifecycle plugin's own per-TYPE `tasks`: an
-- observer instance's own periodic upkeep, scoped to exactly the
-- instance(s) actually configured (e.g. watchtower_observer_web_scraper's
-- sites_source="remote" site-list refresh, one task per "remote" instance,
-- each on that instance's own remote_sites_refresh_interval). An observer
-- type that doesn't implement it contributes nothing - not every type has
-- per-instance upkeep to do. Same optional-instance-method,
-- no-self-registration-table pattern as :capabilities()/:reportable_config()
-- above, consumed by watchtower_worker_core.lifecycle.build.
function M:maintenance_tasks()
  local all = {}
  for _, entry in ipairs(self._observers) do
    if entry.instance.maintenance_tasks then
      for _, task in ipairs(entry.instance:maintenance_tasks()) do
        table.insert(all, task)
      end
    end
  end
  return all
end

return M
