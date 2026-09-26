# watchtower_worker_core (`watchtower-worker-core` rock)

A reusable, dependency-injected Lua worker runtime, extracted from
[watchtower-server](https://github.com/Desvelao/watchtower-server)'s own
standalone and embedded workers so the same orchestration
can be reused to build *other* external workers - including ones that
observe/analyze/notify on entirely different data than watchtower-server's own
"product" observable type.

Pure Lua 5.1+ (tested under LuaJIT/OpenResty and plain PUC-Lua alike). No
DB driver, no `ngx.*` API, and no observer-type-specific observing code
anywhere in this package - see each module's own header comment for the
exact API, and "What stayed out and why" below for what deliberately isn't
here.

## Modules

- **`watchtower_worker_core.lifecycle`** - the plugin/task kernel every
  worker entry point builds its whole runtime from now: `M.build(plugins,
  context)` runs each plugin's `setup(context, deps)` in dependency order
  (mirroring `server/lib/plugins-service.lua`'s own `{name, dependencies,
  setup}`/topological-sort/DI shape, reimplemented standalone here so this
  package stays independent of watchtower-server's own `server/lib/`),
  merges every plugin's contributed `tasks`/`observer_deps`/
  `heartbeat_properties`, builds `context.observer_registry` from the
  merged `observer_deps` (falling back to an empty registry, logged, if
  construction raises - a config/network problem must not take down the
  whole worker), and returns a `Lifecycle` exposing `:tasks()`/`:task(name)`/
  `:tasks_by_role(role)` (so a runtime that drives its own timers, like
  watchtower-server's embedded worker, can pull out and run one task
  independently of the others), `:run_loop(opts)` (the persistent scheduler,
  built on `watchtower_worker_core.loop` below), `:run_once(opts)` (a single
  externally-scheduled pass, for cron/systemd/a Kubernetes CronJob -
  `opts.roles_filter` narrows it to a subset of roles), and
  `:heartbeat_properties()`. Heartbeat itself is scheduled directly by
  `M.build` (not a plugin - every worker needs it unconditionally), reporting
  through `context.connector` (its `{heartbeat(fields) -> ok, err;
  started_at?}` half - the same object the role-plugin tasks call for
  claim/report, see `provider` below).
  See "Writing a new task plugin" below for the full plugin contract.
- **`watchtower_worker_core.phases`** - named, spaced-out numeric constants
  (`HEARTBEAT`/`SCHEDULE`/`OBSERVE`/`ANALYZE`/`EVALUATE`/`DELIVER`/`DEFAULT`,
  ascending = earlier) a plugin sets on its own task descriptors' `phase`
  field so `lifecycle.build` runs the whole assembled task list in a
  deterministic, pipeline-respecting order - see "Task order (`phase`)"
  below.
- **`watchtower_worker_core.plugins`** - the five built-in role plugins
  (`scheduler`, `analyzer`, `evaluator`, `deliver`,
  `observer`), bundled as one array (`watchtower_worker_core.plugins`'s
  `init.lua`) so a worker entry point does
  `local plugins = require("watchtower_worker_core.plugins")` and appends
  its own observer-type/task plugins before calling `lifecycle.build`. Each
  one self-gates on `context.config.roles` (via `watchtower_worker_core.roles`'s
  `has_role`) and, if enabled, registers that role's task(s) - thin wrappers
  around `processors`' existing `do_*` functions (see below), unchanged.
- **`watchtower_worker_core.loop`** - a generic, worker-agnostic task
  loop: `M.run(tasks, opts)` runs an ordered list of
  `{name, interval, retry_interval?, run}` tasks forever, each on its own
  interval (earliest-due first, jittered, sequential - a slow task delays the
  others but no task's interval is tied to another's). `run()` returns
  `ok, more`; `more` makes the task due again immediately. `opts.clock`/
  `opts.sleep` are injectable (defaults `os.time` and a shell/`ngx.sleep`).
  Used internally by `lifecycle:run_loop`; rarely needed directly.
- **`watchtower_worker_core.processors`** - the actual `do_*` tick bodies
  (`do_fire_due_tasks`, `do_run_pending_observe_batch`,
  `do_run_interval_analyze_all`, etc. - each `(ctx, provider, utils) ->
  ok, more`) the built-in plugins above wire into tasks, plus
  `process_observable`/`observe_observable` (the per-observable observe →
  post_observation flow for `observer.source = "interval"` - no
  per-observable `jobs` row is ever created/updated by this flow). Exported
  individually (not just consumed by `watchtower_worker_core.plugins`) so a
  runtime that drives its own timers instead of `lifecycle:run_loop` (e.g.
  watchtower-server's embedded worker) can still run the exact same
  functions - only `provider` (the transport: in-process services vs. HTTP)
  differs.
- **`watchtower_worker_core.observer_registry`** - *the* seam an external
  repo uses to plug in its own observer type instead of watchtower-server's
  own web-scraper one. `M.new(observers_config, observer_type_builders,
  deps)` builds a `type string -> handler` dispatch table from a plain
  config array (`{id, type, observable_type, ...}`); this module has no
  fixed idea of what an "observer" actually does - only that it implements
  `:run(observable, observable_type) -> (properties, nil) | (nil, err)`
  and, optionally, `:capabilities() -> array of strings`,
  `:reportable_config(observer_config)`, and `:maintenance_tasks() -> array
  of {name, interval, run}` (an instance's own periodic upkeep - e.g. a
  `sites_source="remote"` web_scraper instance's site-list refresh -
  aggregated by `registry:maintenance_tasks()` into
  `watchtower_worker_core.lifecycle`'s task list, the per-INSTANCE
  counterpart to a plugin's own per-TYPE `tasks`). An observer type's
  builder function can be supplied three ways: passed explicitly in
  `observer_type_builders` (a `{type_name = function(observer_config, deps)
  -> instance}` table); registered into a `M.new_type_registry()` instance
  (`registry:register_type(name, builder_fn)`/`registry:builders()`) - a
  fresh, independent `{type -> builder}` table per call, the shape
  `watchtower_worker_core.lifecycle.build` hands each plugin as
  `context.observer_types` so a plugin registers explicitly, inside its own
  `setup()`, rather than through a require-time side effect (see "Writing a
  new task plugin" below); or **self-registered** once, at the
  observer-type module's own require time, via `M.register_type(name,
  builder_fn)` - still valid for a bare, non-lifecycle consumer, though an
  explicit table (either form above) takes priority when given, so it can
  override/shadow a self-registered type per-instance.
  `M.registered_types()` lists every self-registered type name, sorted -
  useful for discovery/debugging. See "Writing a new observer type" below
  for the classic self-registration pattern.
- **`watchtower_worker_core.observable_type_cache`** - a tiny memoizing
  cache over observable types, `M.new(loader_fn)` where `loader_fn` is
  however the consumer resolves an observable type by id (an HTTP call, a
  direct DB read, anything).
- **`watchtower_worker_core.cron`** - a hand-rolled, dependency-free 5-field
  cron parser/evaluator (`M.validate(expr)`, `M.next_after(expr,
  from_time)`), useful to a consumer implementing its own admin-side task
  scheduling, not just a worker's tick.
- **`watchtower_worker_core.notification_senders`** - the "deliver" role's
  actual send logic: `M.new(transport, smtp_cfg)` builds a `{send(channel,
  alerts)}` instance that dispatches webhook/discord/email per the
  channel's own `type`, with the outbound HTTP/SMTP transport itself fully
  injectable (so, e.g., a cosocket-based transport can be used inside an
  OpenResty nginx worker process instead of the default blocking one). See
  "A note on `pling`" below - this module's one real runtime dependency
  beyond this package's own declared ones.
- **`watchtower_worker_core.config_report`** -
  `M.build_reportable_config(config)` builds the safe-to-report
  (secret-scrubbed, allow-listed) subset of a worker's config for
  self-reporting in heartbeats (`M.build_reportable_config_json` is its
  JSON-encoded form, and `M.apply_registry(config, registry)` publishes a
  rebuilt observer registry's capabilities plus that dump on `config`).
  An observer type's own field allow-list comes from the same
  optional-instance-method interface `observer_registry`'s own
  `:capabilities()` already uses - an observer instance implements
  `:reportable_config(observer_config)`, and `registry:reportable_observers()`
  aggregates it across every registered observer (falling back to a
  generic, minimal set of fields for a type that doesn't implement it).
  This module stays independent of `observer_registry` (no `require`
  between them) - it has no fixed idea of what fields any particular
  observer type's config carries, and no self-registration table of its
  own; `apply_registry` just publishes what the registry already computed.
- **`watchtower_worker_core.roles`** - the worker role names (`ROLES`) and
  `has_role(roles, name)`; the single definition the runner, the embedded
  worker and the server's heartbeat validation share.
- **`watchtower_worker_core.rule_matching`** - the DB-free orchestration both
  rule analyzers share (`shared/analyzer.lua`, SQL-backed, and
  `worker_rule_matcher`, HTTP-backed): match-context construction with a
  memoized `changed`-baseline fetcher, alert derivation, and
  already-alerted/cooldown suppression. Each analyzer supplies only its own
  I/O as `deps`.
- **`watchtower_worker_core.notification_policy_matcher`** - the
  `evaluator` role's worker-side matching pass (drain the
  candidate alerts, match policies, enqueue deliveries), dependency-injected
  so the embedded worker runs it in-process and the standalone one over HTTP.
- **`watchtower_worker_core.provider_http`** - the one concrete transport
  implementation this package ships (everything else above is DI-only, see
  "What stayed out and why" below): a plain-LuaSocket (`socket.http`/
  `ltn12`) HTTP client implementing the full `deps` surface every
  `pollers/*.lua`/`processors.lua` `do_*` function needs - claim/report per
  role, `post_observation`, observer-config/site reads,
  `new_enabled_observables_pager`/`new_needs_delivery_alerts_pager`
  keyset-paged cursors, rule/policy reads, alert creation, heartbeats - each
  a thin request-and-unwrap call through its own shared `_call`/
  `_job_report`/`_fetch_page` helpers. `M.new(config)` takes the same
  `config.server = {address, api_key, batch_size}` shape
  `docs/dev/worker-configuration.md` documents. watchtower-server's own
  standalone worker (`worker/lua/main.lua`) is this module's original
  consumer; a third-party worker can use it as-is against any
  watchtower-server-compatible API, or ignore it entirely and supply its own
  `deps` (e.g. a direct DB-backed one, the way watchtower-server's embedded
  worker does with its own in-process `embedded_provider`).
- **`watchtower_worker_core.pollers.common`** - the claim/report-warning and
  batch-summary helpers every claim-based poller (`observe`/`analyze`/
  `evaluate`/`notify`) shares.
- **`watchtower_worker_core.pollers.observe`** / **`.analyze`** /
  **`.evaluate`** / **`.notify`** / **`.scheduler`** - one
  independently-requireable module per worker role, each exposing
  `M.poll_and_run(deps, logger)`. Every concrete claim/process/report
  implementation is caller-supplied via `deps` - these modules never touch
  a database or make an HTTP call themselves:
  - `pollers.observe`: `deps = {claim, observe_observable, post_observation,
    report_result, report_error}` - claims one scheduler-fired batch job,
    observes every observable in it, posts each observation, and reports
    exactly one aggregate result.
  - `pollers.analyze`: `deps = {claim, analyze_observable, report_result,
    report_error}` - same batch shape, for re-running rule matching
    against each observable's latest stored observation (no re-observe).
  - `pollers.evaluate`: `deps = {claim, report_result, report_error}` - the
    thinnest of the five: claiming already performs the alert/policy
    matching and enqueues the result elsewhere, so this only reports what
    the claim already accomplished.
  - `pollers.notify`: `deps = {claim, send, report}` - claims a batch
    directly off a delivery queue and dispatches each group via a `send`
    function (a `notification_senders.new(...)` instance's `.send`).
  - `pollers.scheduler`: `deps = {fire_due_tasks}` - the odd one out (no
    claim/report split, since `fire_due_tasks` already does all its work
    server-side in one call), included for symmetry so all five roles are
    reusable the same way.

## Writing a new observer type

An observer type is a plain Lua module with a `M.new(observer_config, deps)`
builder and an instance implementing `:run(observable, observable_type)`,
optionally `:capabilities()`. It self-registers by calling
`observer_registry.register_type` once, at the bottom of its own file -
requiring the module is then all a worker entry point needs to do to make
it available:

```lua
-- my_worker/observers/rss_feed.lua
local M = {}

-- observer_config: {id, type="rss_feed", observable_type="feed_item", ...}
function M.new(observer_config, deps)
  return setmetatable({ _feed_client = deps.feed_client }, { __index = M })
end

function M:capabilities()
  return { "rss_feed" }
end

-- Optional: the safe-to-report subset of this observer's own config, for
-- heartbeat self-reporting (config.report_config) - aggregated across
-- every registered observer by registry:reportable_observers(). An
-- observer type that skips this gets a generic, minimal fallback instead.
function M:reportable_config(observer_config)
  return { id = observer_config.id, type = observer_config.type, observable_type = observer_config.observable_type }
end

-- Required contract: (properties, nil) | (nil, err)
function M:run(observable, observable_type)
  local url = observable.properties and observable.properties.feed_url
  if not url then
    return nil, "observable has no 'feed_url' property"
  end
  local item, err = self._feed_client:latest_item(url)
  if not item then
    return nil, err
  end
  return { title = item.title, link = item.link, published_at = item.published_at }
end

-- Self-registration: requiring this module is now sufficient to make
-- "rss_feed" available to observer_registry.new - no builder table to
-- hand-edit at the worker entry point.
require("watchtower_worker_core.observer_registry").register_type("rss_feed", M.new)

return M
```

```lua
-- worker entry point
require("my_worker.observers.rss_feed")  -- side effect: self-registers "rss_feed"

local observer_registry = require("watchtower_worker_core.observer_registry").new(
  config.observer.observers,  -- e.g. {{id="feed_scraper", type="rss_feed", observable_type="feed_item"}}
  nil,               -- no explicit override table needed
  { feed_client = my_feed_client }
)
```

Everything downstream - `processors.observe_observable`/`process_observable`,
every `pollers/*.lua` - is already fully generic and needs no
changes to support a new observer type; they only ever call
`ctx.observer_registry:run(observable, observable_type)`, and
`watchtower_worker_core.config_report.apply_registry` only ever calls
`ctx.observer_registry:reportable_observers()` - `:capabilities()` and
`:reportable_config(observer_config)` above are both picked up
automatically, with no separate registration call of any kind. In
practice a worker entry point builds its `context.observer_registry`
implicitly, via `watchtower_worker_core.lifecycle.build` (see below), not
by calling `observer_registry.new` directly the way the snippet above
does - `M.new` stays available as the lower-level primitive `lifecycle.build`
itself is built on. A `watchtower_worker_core.lifecycle` plugin registers
an observer type explicitly instead of self-registering: inside its own
`setup(context, deps)`, `context.observer_types:register_type("rss_feed",
M.new)` - see "Writing a new task plugin" below, and
`worker_plugins/watchtower_observer_web_scraper/plugin.lua` for a real example.

## Writing a new task plugin

A plugin is `{ name, dependencies?, setup(context, deps) -> result? }` -
`watchtower_worker_core.lifecycle.build(plugins, context)` runs every
plugin's `setup` once, in dependency order (`deps[dep_name]` = that
dependency's own `setup` return value), and merges whatever `result` it
returns:

```lua
-- my_worker/plugins/rss_poller.lua
local has_role = require("watchtower_worker_core.roles").has_role

local Plugin = { name = "rss_poller" }

function Plugin.setup(context)
  if not has_role(context.config.roles, "observer") then
    return nil  -- nothing to register - this plugin has no work to do
  end

  return {
    tasks = {
      {
        name = "rss_poll",
        role = "observer",           -- metadata only (run_once/tasks_by_role), never an enablement gate
        phase = require("watchtower_worker_core.phases").OBSERVE,  -- see below
        interval = context.config.observer.interval,
        run = function()
          -- ... claim/process/report, or a periodic sweep - same
          -- run() -> ok, more contract watchtower_worker_core.loop expects.
          return true
        end,
      },
    },
    -- Optional: merged into the one `deps` table
    -- watchtower_worker_core.observer_registry.new is built from.
    observer_deps = { my_client = context.rss_client },
    -- Optional: merged into the heartbeat's `properties` payload.
    heartbeat_properties = function()
      return { rss_items_seen = context._rss_items_seen or 0 }
    end,
  }
end

return Plugin
```

```lua
-- worker entry point
local plugins = require("watchtower_worker_core.plugins")  -- the 5 built-ins
table.insert(plugins, require("my_worker.plugins.rss_poller"))

local lifecycle = require("watchtower_worker_core.lifecycle").build(plugins, context)
lifecycle:run_loop({ clock = ..., sleep = ... })   -- or lifecycle:run_once({...}) for a one-shot pass
```

A plugin decides for *itself*, via `context.config.roles`/`has_role`,
whether it has anything to register - `lifecycle.build` never gates a
plugin's `setup` call on any role. One plugin failing at `setup` (a raised
error) is caught and logged, degrading gracefully rather than preventing
every other plugin's tasks from being registered.

### Task order (`phase`)

`lifecycle.build` sorts the whole assembled task list by each task's own
`phase` (see `watchtower_worker_core.phases` - a small set of named,
spaced-out numeric constants: `HEARTBEAT`/`SCHEDULE`/`OBSERVE`/`ANALYZE`/
`EVALUATE`/`DELIVER`/`DEFAULT`, ascending = earlier) before either
`:run_once` or `:run_loop` ever sees it - ties (including "no `phase` set,"
which defaults to `phases.DEFAULT`) break by registration order. This
matters most for `:run_once`: a worker with every built-in role enabled
is meant to produce a full `observe -> analyze -> evaluate -> deliver`
chain of *real* output (a fresh observation, an alert it triggers, the
delivery it enqueues, the delivery actually sent) from **one** pass, and
that only works if each phase's task runs after the phase that produces
its input - `analyze` re-processing a `observe` hasn't observed yet, or
`deliver` draining a queue `evaluate` hasn't enqueued into yet, would
silently produce nothing. The five built-in plugins
(`shared/watchtower_worker_core/plugins/*.lua`) already set the matching
constant on their own tasks; a third-party plugin unrelated to the alert
pipeline (like `watchtower_observer_web_scraper`'s ad-hoc test-poller) can
simply leave `phase` unset.

## What stayed out and why

- **`scraper_creator.lua` / `observers/web_scraper.lua` / `test_poller.lua` /
  `plugin.lua`** - watchtower-server's own "web_scraper" observer type
  implementation (plus its ad-hoc "test a scraper config against a URL"
  poller, and the `watchtower_worker_core.lifecycle` plugin that registers
  both explicitly, via `context.observer_types`, not self-registration).
  It's already cleanly pluggable into `observer_registry.new(observers_config,
  observer_type_builders, deps)`/`lifecycle.build(plugins, context)` from
  the outside, so nothing here needed to change for it to keep working -
  it now lives in its own package, `watchtower_observer_web_scraper`
  (`worker_plugins/watchtower_observer_web_scraper/`, the
  `watchtower-observer-web-scraper` rock - see that package's own README),
  separate from this one, exactly as this section originally anticipated.
- **`analyzer.lua`** - watchtower-server's rule-matching/alert-creation logic,
  which talks to Postgres directly with no dependency-injection seam for
  that access. Never used by watchtower-server's own standalone worker either,
  for the same reason. The reusable seam for the "analyzer" role is
  `pollers.analyze`'s `deps.analyze_observable` - wire it to a direct DB
  call (as watchtower-server's embedded worker does) or to an HTTP endpoint (as
  watchtower-server's standalone worker does), whichever fits your own worker.

## A note on `pling`

`notification_senders` requires `pling.notifiers.{discord,webhook,
webhook_transport,email}` at runtime - a published LuaRocks package
(github.com/Desvelao/pling), declared as an ordinary rockspec
`dependency` here and pulled in normally by `luarocks make`/`install`. If
you don't need the "deliver" role, every other module in this package
works without it - just avoid requiring
`watchtower_worker_core.notification_senders`/`.pollers.notify`.

## Install

```console
luarocks install watchtower-worker-core
```

or, during watchtower-server's own development, nothing extra is needed at
all: this directory lives inside `shared/`, which is already bind-mounted
into both the server and standalone-worker dev containers with
`watchtower_worker_core.*` on `LUA_PATH` (see `shared/README.md`).
watchtower-server's own dev and prod stacks keep vendoring `shared/` via
bind-mount/`COPY` exactly as before this package existed - this rockspec
and its publish workflow exist for *external* consumers (a project outside
this repo), not as a change to watchtower-server's own build.
