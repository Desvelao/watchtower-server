-- Embedded worker (USE_EMBED_WORKER, enabled by default - set to 0 to
-- disable) that runs inside the server's nginx worker process (ngx.timer).
-- Every role's tick is a watchtower_worker_core.lifecycle task, built from
-- the same built-in role plugins (shared/watchtower_worker_core/plugins/)
-- and whichever observer-type/task plugin(s) config.plugins names (e.g.
-- worker_plugins/watchtower_observer_web_scraper/plugin.lua) - the same
-- config.plugins-driven set the standalone worker uses (worker/lua/main.lua),
-- see watchtower_worker_core.runner's build_config/plugin_loader.lua - only
-- `context.connector` (this runtime's in-process transport,
-- `embedded_provider` below - it also implements the worker_manager-based
-- heartbeat method, the `connection_type` field every connector must
-- provide, and the observer_configs-backed methods
-- watchtower_observer_web_scraper.plugin builds its own
-- fetch_remote_sites/observer_config_test_poller_deps from) differs from
-- the standalone worker's http_provider. Every registered task then runs on
-- its own concurrent ngx.timer.every (see `every` below) rather than one
-- shared loop, so a slow role never delays another -
-- watchtower_worker_core.loop.lua (the standalone worker's earliest-due-next
-- scheduler) is never used here.
--
-- What's genuinely specific to this runtime lives here: DB-backed ingest of
-- its own observations, worker registration/heartbeat, and the observer(s) built
-- from plugins/observer_configs (one per enabled (observable_type_id,
-- observer_type) pair) - see build_observer_configs_observers below. An
-- observable type with no enabled observer_configs row simply gets no
-- observer registered (a safe no-op, not an error) until one is configured;
-- there is no hardcoded fallback for "product" or any other type.
--
-- Required from nginx.conf's init_worker_by_lua_block (once per nginx
-- worker at boot), not from app.lua's top level, for the same reason
-- server/workers/bootstrap_admin.lua is: app.lua is `require`d fresh on
-- every request in dev (lua_code_cache off), and real DB I/O inside a
-- module body loaded that way hits OpenResty's "attempt to yield across
-- C-call boundary" - the actual work below runs inside ngx.timer
-- callbacks instead.
local ok_config, config_err = pcall(require, "config")
local db = require("lapis.db")
local models = require("models")
local cjson_safe = require("cjson.safe")
local notification_senders = require("watchtower_worker_core.notification_senders")
local resty_webhook_transport = require("lib.resty_webhook_transport")
local resty_mail_notifier = require("lib.resty_mail_notifier")
local reanalyze = require("plugins.entities.services.reanalyze")
local observer_type_catalog = require("lib.observer_type_catalog")
local schedule = require("watchtower_worker_core.schedule")
local route_helpers = require("lib.routes")

if not ok_config then
  ngx.log(
    ngx.ERR,
    "[observe-worker] failed to load config: " .. tostring(config_err)
  )
end

local EMBEDDED_WORKER_ID = "embedded"
local WORKER_START_TIME = os.time()

-- config itself is env-var/file-only (no DB access), so it's safe to build
-- at module-load time (unlike the lifecycle below, which needs real DB I/O
-- deferred into a ngx.timer callback). Declared this early so every
-- function below can already close over it.
--
-- watchtower_worker_core is a publishable library and never reads the
-- environment itself (see runner.lua's own header comment) - this is the
-- one place the embedded worker resolves every env var build_config
-- actually uses, and hands them in as plain values. LOG_LEVEL/
-- SERVER_API_KEY* are omitted here since they're standalone-only (see
-- docs/dev/worker-configuration.md) - this worker's own worker_logger below
-- never reaches into Logger.new/config.log_level, and it has no HTTP
-- transport to authenticate.
local embedded_env = {
  WORKER_CONFIG_FILE = os.getenv("WORKER_CONFIG_FILE"),
  USE_EMBED_SCHEDULER = os.getenv("USE_EMBED_SCHEDULER"),
  USE_EMBED_DELIVER = os.getenv("USE_EMBED_DELIVER"),
  USE_EMBED_EVALUATOR = os.getenv("USE_EMBED_EVALUATOR"),
  SMTP_HOST = os.getenv("SMTP_HOST"),
  SMTP_PORT = os.getenv("SMTP_PORT"),
  SMTP_USER = os.getenv("SMTP_USER"),
  SMTP_PASSWORD_FILE = os.getenv("SMTP_PASSWORD_FILE"),
  SMTP_PASSWORD = os.getenv("SMTP_PASSWORD"),
  SMTP_FROM = os.getenv("SMTP_FROM"),
  SMTP_SSL = os.getenv("SMTP_SSL"),
}
local config = require("watchtower_worker_core.runner").build_config("embedded", embedded_env)

local has_role = require("watchtower_worker_core.roles").has_role

-- Log sink handed to every shared poller/processor (info/warn/error,
-- printf-free).
-- info goes out at NOTICE since nginx.conf's error_log is `notice` - INFO
-- would be dropped, and these "[id=..] - [action=observed]" lines are the
-- only per-observe trace an operator sees.
-- No `.debug`, deliberately: the stock openresty/openresty:alpine base image
-- (docker/images/{dev/lapis,prod/server}/Dockerfile) isn't built
-- --with-debug, so ngx.log(ngx.DEBUG, ...) is compiled out and silently
-- dropped regardless of error_log's level - a stub here would look
-- functional but never actually emit. Nothing embedded-side calls
-- context.logger.debug() unconditionally today (only
-- watchtower_worker_core.provider_http does, standalone-only); a future
-- caller that needs it must nil-check `context.logger.debug` first, or this
-- table needs a real one behind a rebuilt debug-enabled nginx image.
local worker_logger = {
  info = function(message) ngx.log(ngx.NOTICE, "[observe-worker] " .. message) end,
  warn = function(message) ngx.log(ngx.WARN, "[observe-worker] " .. message) end,
  error = function(message) ngx.log(ngx.ERR, "[observe-worker] " .. message) end,
}

-- Self-rearming ngx.timer.at loop for a cron-string interval - ngx.timer.every
-- only supports a fixed period for the life of the timer (no API to change
-- it), so a wall-clock-pinned task instead reschedules itself each run via
-- watchtower_worker_core.schedule (the same module loop.lua's standalone
-- persistent loop uses for the same purpose). pcall'd around `fn` so one
-- failing run doesn't stop the timer from re-arming, unlike the plain
-- ngx.timer.every path below (which lets OpenResty's own default timer
-- error logging handle an uncaught error) - here a swallowed/uncaught error
-- would silently kill this task's schedule forever.
local function every_cron(label, cron_expr, fn)
  local function tick(premature)
    if premature then return end
    local ok, err = pcall(fn)
    if not ok then
      worker_logger.error(label .. " failed: " .. tostring(err))
    end
    local next_ts, sched_err = schedule.next_due(cron_expr, ngx.time())
    if not next_ts then
      worker_logger.error(label .. " cron scheduling failed, timer stopped: " .. tostring(sched_err))
      return
    end
    local rok, rerr = ngx.timer.at(math.max(next_ts - ngx.time(), 0), tick)
    if not rok then
      worker_logger.error("failed to re-arm " .. label .. " timer: " .. tostring(rerr))
    end
  end

  local first_due, first_err = schedule.next_due(cron_expr, ngx.time())
  if not first_due then
    worker_logger.error("failed to start " .. label .. " timer: " .. tostring(first_err))
    return
  end
  local ok, err = ngx.timer.at(math.max(first_due - ngx.time(), 0), tick)
  if not ok then
    worker_logger.error("failed to start " .. label .. " timer: " .. tostring(err))
  end
end

-- Starts one recurring tick as its own concurrent ngx.timer.every - the
-- embedded worker has that primitive available, unlike the standalone
-- worker (where each tick is a task in watchtower_worker_core.lifecycle's
-- persistent loop), so a slow role never delays another. `label` names the
-- tick in the failure log. `interval` is either a plain number of seconds
-- (unchanged ngx.timer.every path) or a cron expression string (routed to
-- every_cron above, since ngx.timer.every can't do variable delays).
local function every(label, interval, fn)
  if type(interval) == "string" then
    return every_cron(label, interval, fn)
  end

  local ok, err = ngx.timer.every(interval, fn)
  if not ok then
    worker_logger.error("failed to start " .. label .. " timer: " .. tostring(err))
  end
end

-- Constructed directly rather than reaching into a request-scoped plugin
-- instance (which doesn't exist yet at nginx worker boot).
-- `analyzer` is shared/analyzer.lua - the rule-matching + alert-creation
-- logic, used by ingest_observation below and both analyze ticks (through
-- plugins/entities/services/reanalyze.lua).
local rule_engine = require("plugins.rules.services.rule_engine").new(models.Rules)
local analyzer = require("analyzer").new(rule_engine, models.Alerts, worker_logger.error)

-- Self-reported analyzer-role metadata (see
-- plugins/workers/worker_role_schemas.lua's `analyzer` property schema) -
-- a real, honestly-computed counter, incremented once per observation
-- actually run through `analyzer:analyze`, included in the next heartbeat
-- (see context.extra_heartbeat_properties below - no role/plugin owns this
-- counter, it's specific to this runtime's own ingest-on-observe path).
local observations_analyzed = 0

-- Creates the observation row and runs it through the rule engine directly
-- (POST /api/observations, by contrast, only stores the row - see that
-- handler), returning the observation. `observation_result` is the properties table
-- observe_observable returned, shaped per
-- observable_type.observation_schema but not yet validated - validate_values
-- is the authoritative check here (same one the HTTP route uses), reused
-- directly since this runs in the same Lua runtime.
local function ingest_observation(observable, observable_type, observation_result)
  local ok_validate, normalized_or_err = require("lib.property_schema").validate_values(
    observable_type and observable_type.observation_schema,
    observation_result
  )
  if not ok_validate then
    -- Raises (not `return false, err`) deliberately: notifier.complete's
    -- pcall around this call is the only thing that notices failure here -
    -- its own return value is otherwise discarded before
    -- job_manager:report(..., "acknowledged", ...) runs below, so a plain
    -- `return false` would silently report this job "acknowledged" with
    -- nothing actually written.
    error("observation properties failed validation: " .. tostring(normalized_or_err))
  end
  local normalized = normalized_or_err

  local observation = models.Observations:create({
    observable_id = observable.id,
    timestamp = db.format_date(),
    worker = EMBEDDED_WORKER_ID,
    properties = require("lib.jsonb_query").encode(normalized),
  })

  -- `timestamp` is what makes analyzer.build_match_context attach
  -- _fetch_baseline (needs both observable_id and timestamp); without it the
  -- `changed`/`changed_within` operators silently evaluate to false here,
  -- unlike services/reanalyze.lua's same call.
  analyzer:analyze({
    id = observation.id,
    source = observable.name,
    payload = cjson_safe.encode(normalized),
    observable_id = observable.id,
    timestamp = observation.timestamp,
    worker = EMBEDDED_WORKER_ID,
    observable_type = observable_type and observable_type.name,
  })
  observations_analyzed = observations_analyzed + 1

  return observation
end

-- The single "stalest" enabled Observable: never-observed observables first
-- (the `last_obs.timestamp IS NOT NULL` boolean sorts false-before-true
-- under Postgres' default ASC, pulling them to the front explicitly), then
-- whichever has the oldest latest-observation timestamp. Derived from
-- observations directly (via the observations_observable_timestamp_idx
-- (observable_id, timestamp DESC) index) rather than
-- observables.last_observe_take_at, since observer.source = "interval" no
-- longer reports a per-observable `jobs` row (see process_observable) and
-- that column is the only thing that ever wrote last_observe_take_at - a
-- raw db.query is needed here since Model:select can only append a WHERE
-- clause after `SELECT * FROM <table>`, not express a LEFT JOIN LATERAL.
-- No cooldown/backoff is enforced yet - every poll tick re-selects the
-- current stalest observable, so a single enabled observable is observed
-- continuously at `interval` cadence; a documented simplification for
-- this first pass; a real cooldown (skip observables observed within the
-- last N seconds) is a natural follow-up once there's more than a handful
-- of observables.
local function get_pending_observable()
  local rows = db.query([[
    SELECT o.*
    FROM observables o
    LEFT JOIN LATERAL (
      SELECT timestamp
      FROM observations
      WHERE observable_id = o.id
      ORDER BY timestamp DESC
      LIMIT 1
    ) last_obs ON true
    WHERE o.enabled = true
    ORDER BY (last_obs.timestamp IS NOT NULL), last_obs.timestamp ASC, o.id ASC
    LIMIT 1
  ]])
  return rows[1]
end

local job_manager = require("plugins.jobs.services.jobs").new(models.Jobs, {
  observe = {
    -- remove_fields_on_update: see the identical comment on
    -- plugins/jobs/plugin.lua's own observables_manager - this is a second,
    -- independent resource_manager instance over the same `observables` model,
    -- so it needs the same fix for the same reason (a jsonb `properties`
    -- column already decoded to a Lua table by the DB driver can't be
    -- written back verbatim via a plain observable:update).
    manager = require("lib.resource_manager").new(models.Observables, {
      remove_fields_on_update = { "properties" },
    }),
    apply = function(d, winner)
      d.last_observe_status = winner.status
      d.last_observe_worker = winner.worker_id
      if winner.taken_at then
        d.last_observe_take_at = winner.taken_at
      end
      if winner.acked_at then
        d.last_observe_ack_at = winner.acked_at
      end
      return d
    end,
  },
})

local worker_manager = require("plugins.workers.services.workers").new(
  models.Workers,
  models.WorkerHeartbeats
)

-- The "deliver" role's own claim/report cycle against the alert_deliveries
-- queue - see plugins/notification_channels/services/delivery_queue.lua.
-- Constructed before scheduler_service below so it can be passed straight
-- in - scheduler_service:claim_next_batch's 'deliver' branch calls this same
-- instance's :claim_batch internally (see services/scheduler.lua), an
-- alternative entry point onto this queue alongside this role's own
-- independent tick (processors.do_run_pending_notify_batch, via
-- embedded_provider below).
local delivery_queue_service = require("plugins.notification_channels.services.delivery_queue").new(
  models.NotificationChannels
)
-- observable_type_manager/policy_manager omitted: this instance only ever
-- calls :fire_due/:claim_next_batch (the "scheduler"/"observer"/"analyzer"/
-- "evaluator" roles' own ticks below), never
-- :create/:update (admin CRUD lives in plugins/scheduler/plugin.lua's own
-- instance) - same "constructed twice, once per Lua runtime" precedent as
-- job_manager/worker_manager above. Deliberately decoupled from the
-- observer_registry/analyzer machinery: this service knows nothing about
-- observing, and get_pending_observable know nothing about it. Also
-- deliberately decoupled from actually sending a notification - its notify
-- branch only hands out a task's policy scope, and the evaluator's matching
-- (policy_matcher below) only ever enqueues onto alert_deliveries, never
-- sends (see embedded_sender below, a separate, unrelated dependency for
-- the "deliver" role's own tick).
local scheduler_service = require("plugins.scheduler.services.scheduler").new(
  models.SchedulerTasks, models.Observables, nil, nil, delivery_queue_service
)

-- The "evaluator" role's matching (see
-- shared/watchtower_worker_core/notification_policy_matcher.lua for the full
-- design - the standalone worker runs the same module over HTTP): decides
-- which candidate alerts go to which channels and enqueues the resulting
-- pending deliveries onto alert_deliveries, here with direct in-process
-- deps. It's this worker's own instance, sharing no state with the
-- admin-CRUD plugin's policy_manager; it re-reads the enabled policies at the
-- start of every pass, so a policy edit is never missed.
local EVALUATE_PAGE_SIZE = 100
local policy_matcher = require("watchtower_worker_core.notification_policy_matcher").new({
  load_policies = function()
    return models.NotificationPolicies:select("where enabled = ? order by id asc", true)
  end,
  new_candidate_alerts_pager = function()
    local after_id = 0
    return function()
      local alerts = require("lib.alert_queries").candidate_alerts_page(after_id, EVALUATE_PAGE_SIZE)
      if #alerts == 0 then
        return nil
      end
      after_id = alerts[#alerts].id
      return alerts
    end
  end,
  enqueue_delivery = function(alert_id, channel_id)
    local ok, inserted = pcall(delivery_queue_service.enqueue, delivery_queue_service, alert_id, channel_id)
    if not ok then
      return nil, tostring(inserted)
    end
    return inserted
  end,
  log_error = worker_logger.warn,
})

-- LuaSocket/LuaSec (pling's own default transport) cannot run inside
-- this nginx worker process - see server/lib/resty_webhook_transport.lua's
-- header comment. Only the embedded runtime needs this; the standalone
-- worker builds its own notification_senders.new(...) instance with the
-- default transport (shared/watchtower_worker_core/processors.lua).
--
-- Email used to get different treatment here: pling.notifiers.email is
-- built on LuaSocket's own socket.smtp/socket.tp/mime protocol code, which
-- internally invokes Lua callbacks *from* C functions (e.g. for
-- line/dot-stuffing processing) - yielding a cosocket op through that C
-- boundary raises "attempt to yield across C-call boundary" (a hard
-- Lua/LuaJIT runtime restriction). A first attempt at fixing this
-- (server/lib/resty_smtp_socket.lua, now removed) tried injecting a
-- cosocket-based *socket* underneath pling's own SMTP protocol code,
-- the same DI pattern used for resty_webhook_transport.lua/
-- watchtower_observer_web_scraper's own resty_transport.lua (picked by
-- worker_plugins/watchtower_observer_web_scraper/plugin.lua, based on
-- context.connector.connection_type == "embedded") - that was confirmed broken, since
-- the yield happens inside pling's
-- protocol layer itself, not the socket. lua-resty-mail (resty.mail)
-- sidesteps the problem entirely by implementing the SMTP wire protocol
-- directly over ngx.socket.tcp, with no LuaSocket protocol code anywhere in
-- the call path - see server/lib/resty_mail_notifier.lua's header comment
-- for the full rationale. config.deliver.smtp is the same app-wide SMTP
-- relay setting the standalone worker resolves
-- (shared/watchtower_worker_core/runner.lua's build_config); a nil/host-less
-- config.deliver.smtp just means email sends fail per-alert with a clear
-- reason, same as the standalone worker.
local embedded_sender = notification_senders.new(resty_webhook_transport.new({}), config.deliver.smtp, resty_mail_notifier)

-- Constructing the cache itself does no DB I/O (only :get(id) does, later)
-- so this is safe at module-load time, same precedent as `rule_engine`
-- above - the actual models.ObservableTypes:find() calls only ever happen from
-- inside notifier.complete/observe_observable, both only ever invoked from
-- the ngx.timer callbacks below.
local observable_types = require("watchtower_worker_core.observable_type_cache").new(function(id)
  local et = models.ObservableTypes:find({ id = id })
  if not et then
    return nil, "observable type not found: " .. tostring(id)
  end
  local jsonb_query = require("lib.jsonb_query")
  et.properties = jsonb_query.decode(et.properties)
  et.observation_schema = jsonb_query.decode(et.observation_schema)
  return et
end)

-- POST-observation-only counterpart to ingest_observation: creates the
-- observation and runs it through the rule engine exactly like the
-- ordinary per-observable path does (real alerts still fire on a
-- genuinely price-changing observation), but reports no per-observable
-- `jobs` row. Shared by both observer.source modes - the scheduler-fired
-- "queue" batch (embedded_provider:post_observation below, one aggregate
-- job report at the end instead, see shared/watchtower_worker_core/pollers/observe.lua)
-- and "interval" mode's own context.post_observation (see
-- shared/watchtower_worker_core/processors.lua's process_observable) -
-- neither ever creates/updates a jobs row per observable. Returns (ok, err).
local function post_observation(observable, observation_result)
  return pcall(function()
    local observable_type, et_err = observable_types:get(observable.observable_type_id)
    if not observable_type then
      error("failed to resolve observable type: " .. tostring(et_err))
    end
    ingest_observation(observable, observable_type, observation_result)
  end)
end

-- Re-runs rule matching against one observable's latest stored observation.
-- Raises when its observable type can't be resolved: analysing without it
-- would silently miss every rule that targets an observable_type, so the
-- caller (both analyze ticks pcall this) must count the observable as failed.
local function analyze_one(observable)
  local observable_type, type_err = observable_types:get(observable.observable_type_id)
  if not observable_type then
    error("failed to resolve observable type " .. tostring(observable.observable_type_id) .. ": " .. tostring(type_err))
  end
  return reanalyze.analyze_observable(observable, observable_type, models.Observations, analyzer)
end

-- (ok, err) from a call that raises on failure - what the shared pollers'
-- report_* deps expect (job_manager/delivery_queue raise rather than return).
local function pcall_ok(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    return false, err
  end
  return true
end

-- This worker's context.connector: the same method names the standalone
-- worker's HTTP provider (shared/watchtower_worker_core/provider_http.lua)
-- has, here calling the services in-process - no HTTP round trip, same
-- precedent as job_manager/worker_manager above. With this, each role's tick
-- is literally the shared function (claim -> process -> one final report);
-- only the transport differs. Besides the per-role claim/report methods
-- below, this table also implements the narrow `{heartbeat(fields) -> ok,
-- err; started_at}` contract watchtower_worker_core.lifecycle's
-- M._run_heartbeat calls unconditionally, regardless of which roles are
-- configured - see `started_at`/`:heartbeat` at the bottom of this table,
-- mirroring provider_http.lua's own combined surface.
local embedded_provider = {}

function embedded_provider:fire_due_tasks()
  return scheduler_service:fire_due()
end

function embedded_provider:reap_stale_jobs(timeout_seconds)
  return job_manager:reap_stale(timeout_seconds)
end

function embedded_provider:claim_batch(type_)
  return scheduler_service:claim_next_batch(EMBEDDED_WORKER_ID, type_)
end

-- skip_rollup=true: a scheduler-fired job's ref_id is a scheduler_tasks.id,
-- not an observables.id.
function embedded_provider:report_batch_result(type_, task_id, action, message, result)
  return pcall_ok(
    job_manager.report, job_manager, type_, task_id, EMBEDDED_WORKER_ID, "acknowledged", action, message, result, true
  )
end

function embedded_provider:report_batch_error(type_, task_id, message)
  return pcall_ok(job_manager.report_error, job_manager, type_, task_id, EMBEDDED_WORKER_ID, message, true)
end

function embedded_provider:post_observation(observable, observation_result)
  return post_observation(observable, observation_result)
end

function embedded_provider:analyze_observable(observable)
  return analyze_one(observable)
end

-- do_run_interval_observe's (shared/watchtower_worker_core/processors.lua)
-- own single-observable-per-call contract - the embedded counterpart to
-- provider_http.lua's M.next (a paginated generator standalone-only), here
-- just the direct query above. Returns (observable, nil) | (nil, nil) - this
-- never fails on its own, unlike the standalone HTTP version.
function embedded_provider:next()
  return get_pending_observable()
end

-- A single un-paginated select: this worker has direct Postgres access, so
-- no HTTP pagination/cursor is needed (contrast the standalone provider's
-- pager). The generator yields the one page, then nil.
function embedded_provider:new_enabled_observables_pager()
  local done = false
  return function()
    if done then
      return nil
    end
    done = true
    local observables = models.Observables:select("where enabled = true order by id asc")
    if #observables == 0 then
      return nil
    end
    return observables
  end
end

function embedded_provider:evaluate_notify_policies(policy_ids)
  return policy_matcher:evaluate_and_enqueue(policy_ids)
end

function embedded_provider:claim_deliveries()
  return delivery_queue_service:claim_batch(EMBEDDED_WORKER_ID)
end

function embedded_provider:report_deliveries(channel_results)
  return pcall_ok(delivery_queue_service.report, delivery_queue_service, channel_results, EMBEDDED_WORKER_ID)
end

function embedded_provider:reap_stale_deliveries(timeout_seconds)
  -- delivery_queue_service:reap_stale returns the raw reaped-rows array;
  -- wrapped here into the {reaped, items} shape
  -- pollers/reap_stale_deliveries.lua's poll_and_run expects (the same
  -- shape the standalone worker gets from PUT /api/alert_deliveries/reap-stale's
  -- own response) - unlike embedded_provider:reap_stale_jobs above, which
  -- returns job_manager:reap_stale's raw array unwrapped (a pre-existing
  -- inconsistency in that older code path, not repeated here).
  local items = delivery_queue_service:reap_stale(timeout_seconds)
  return { reaped = #items, items = items }
end

-- The heartbeat half of context.connector's combined contract -
-- watchtower_worker_core.lifecycle's M._run_heartbeat reports through this
-- (see that module's own header comment for the {heartbeat(fields) -> ok,
-- err; started_at} contract every connector provides, alongside its
-- claim/report methods above) - a small adapter around worker_manager:heartbeat's
-- own (worker_id, fields) shape and its Postgres array/jsonb encoding
-- requirements (db.array/jsonb_query.encode), which the generic lifecycle
-- heartbeat body knows nothing about. pcall'd since worker_manager:heartbeat
-- raises on a DB error rather than returning (ok, err) itself.
-- embedded_provider:heartbeat(fields) is called with `:` (see
-- watchtower_worker_core.lifecycle's M._run_heartbeat, matching
-- provider_http.lua's own `function M:heartbeat(fields)` colon-defined
-- method) - so this must accept an implicit `self` too, even though it's
-- unused here.
--
-- connection_type also lives on the connector itself (not a separate
-- context field) - M._run_heartbeat reads it off
-- context.connector.connection_type for the heartbeat payload, and
-- watchtower_observer_web_scraper.plugin's build_scraper_transport reads it
-- to pick the outbound scrape-fetch transport.
embedded_provider.started_at = WORKER_START_TIME
embedded_provider.connection_type = "embedded"
function embedded_provider:heartbeat(fields)
  local ok, err = pcall(function()
    return worker_manager:heartbeat(EMBEDDED_WORKER_ID, {
      connection_type = fields.connection_type,
      version = fields.version,
      capabilities = db.array(fields.capabilities),
      uptime_seconds = fields.uptime_seconds,
      config = fields.config,
      roles = db.array(fields.roles),
      properties = require("lib.jsonb_query").encode(fields.properties),
    })
  end)
  if not ok then
    return false, err
  end
  return true
end

-- The remaining six methods give embedded_provider the same
-- observer_configs/observer_config_test_requests surface provider_http.lua
-- already exposes to the standalone worker (see that module's own
-- next_observer_test/observer_test_triggering/observer_test_ack/
-- observer_test_error/get_observer_config/list_observer_config_sites) -
-- direct DB/model access instead of HTTP, but the exact same method names,
-- so watchtower_observer_web_scraper.plugin can build its own
-- fetch_remote_sites/observer_config_test_poller_deps purely from
-- context.connector on either runtime, with no runtime-specific adapter
-- module of its own. These tables are schema-generic (no observer_type
-- column - see config/dataset/init.sql's observer_configs comment), so
-- exposing them here is no more observer-type-specific than the
-- claim/report methods above.
function embedded_provider:list_observer_config_sites(observable_type_id)
  local catalog_entry = observer_type_catalog.default()
  local rows = models.ObserverConfigs:select(
    "where observable_type_id = ? and enabled = true order by name asc",
    observable_type_id
  )
  local sites = {}
  for i, row in ipairs(rows) do
    sites[i] = catalog_entry.to_site(row)
  end
  return sites
end

-- Embedded counterpart to the standalone worker's
-- GET /api/observer_configs/test_requests/pending - an ad-hoc test has no
-- observables/observable_type row for observer_registry to dispatch through,
-- so this is a direct query rather than going through any observer/observable
-- machinery. Same atomic-claim shape as that HTTP route (see its own header
-- comment in server/plugins/observer_configs/plugin.lua): SELECT ... FOR
-- UPDATE OF octr SKIP LOCKED locks the candidate row against any other
-- concurrent claimer (another nginx worker process's own embedded poller
-- tick, or a standalone worker hitting the HTTP route - they share the same
-- `jobs` table), then the INSERT durably records the claim before the
-- transaction commits, so the plain pre-fix "SELECT with no locking" race
-- (two pollers both handed the same still-unclaimed row) can't happen here
-- either.
function embedded_provider:next_observer_test()
  local claimed = route_helpers.with_transaction(function()
    local rows = db.query([[
      SELECT octr.id, octr.config, octr.test_url
      FROM observer_config_test_requests octr
      LEFT JOIN jobs j ON j.type = 'observer_test' AND j.ref_id = octr.id
      WHERE j.id IS NULL
      ORDER BY octr.created_at ASC
      LIMIT 1
      FOR UPDATE OF octr SKIP LOCKED
    ]])

    local row = rows[1]
    if not row then
      return nil
    end

    db.query([[
      INSERT INTO jobs (worker_id, type, ref_id, status, taken_at)
      VALUES (?, 'observer_test', ?, 'triggering', NOW())
    ]], EMBEDDED_WORKER_ID, row.id)

    return row
  end)

  if not claimed then
    return nil
  end
  return {
    id = claimed.id,
    config = require("lib.jsonb_query").decode(claimed.config),
    test_url = claimed.test_url,
  }
end

function embedded_provider:get_observer_config(id)
  return models.ObserverConfigs:find({ id = id })
end

-- job_manager:report/:report_error raise on failure rather than returning
-- (ok, err), hence pcall_ok here - matching provider_http.lua's own
-- (ok, err) contract for these three methods.
function embedded_provider:observer_test_triggering(id)
  return pcall_ok(job_manager.report, job_manager, "observer_test", id, EMBEDDED_WORKER_ID, "triggering")
end

function embedded_provider:observer_test_ack(id, result)
  return pcall_ok(job_manager.report, job_manager, "observer_test", id, EMBEDDED_WORKER_ID, "acknowledged", "tested", nil, result)
end

function embedded_provider:observer_test_error(id, message)
  return pcall_ok(job_manager.report_error, job_manager, "observer_test", id, EMBEDDED_WORKER_ID, message)
end

-- Not a WORKER_CONFIG_FILE knob for any observer built below - see
-- watchtower_observer_web_scraper.observers.web_scraper's own
-- DEFAULT_REMOTE_SITES_REFRESH_INTERVAL comment for why this is entirely
-- that observer type's own concern. Same "internal implementation detail,
-- not an operator-facing knob at the role level" precedent as
-- ENGINE_CACHE_REFRESH_INTERVAL below.
local REMOTE_SITES_REFRESH_INTERVAL = 60

-- One config.observer.observers[] entry per distinct observable_type_id
-- that has at least one enabled plugins/observer_configs row - each opts
-- into sites_source="remote" against THAT registry (see
-- watchtower_observer_web_scraper.plugin's fetch_remote_sites, branching on
-- the remote_source="observer_configs" marker set here). observer_type is not
-- configured anywhere (see lib/observer_type_catalog.lua's header comment)
-- - every entry uses the catalog's one implemented type. Real DB I/O - only
-- ever called from inside the boot ngx.timer callback below, never at
-- module load time.
local function build_observer_configs_observers()
  local rows = db.query([[
    SELECT DISTINCT observable_type_id
    FROM observer_configs
    WHERE enabled = true
  ]])

  local _, observer_type = observer_type_catalog.default()
  local observers = {}
  for _, row in ipairs(rows) do
    local observable_type = models.ObservableTypes:find({ id = row.observable_type_id })
    if not observable_type then
      worker_logger.warn("observer_configs references missing observable_type_id " .. tostring(row.observable_type_id))
    else
      table.insert(observers, {
        id = "observer_config_" .. row.observable_type_id .. "_" .. observer_type,
        type = observer_type,
        observable_type = observable_type.name,
        sites_source = "remote",
        remote_source = "observer_configs",
        observable_type_id = row.observable_type_id,
        observer_type = observer_type,
        remote_sites_refresh_interval = REMOTE_SITES_REFRESH_INTERVAL,
      })
    end
  end

  return observers
end

-- The five built-in role plugins (scheduler/analyzer/
-- evaluator/deliver/observer - see
-- shared/watchtower_worker_core/plugins/init.lua), plus whichever
-- observer-type/task plugin(s) config.plugins names, exactly like the
-- standalone worker (worker/lua/main.lua) assembles - see
-- watchtower_worker_core.runner's build_config and plugin_loader.lua.
-- config.plugins defaults to {}, so WORKER_CONFIG_FILE must list
-- "watchtower_observer_web_scraper.plugin" explicitly for this worker to
-- have any observer type available at all. This file never touches
-- watchtower_worker_core.observer_registry, or
-- watchtower_observer_web_scraper's own observer_config_test_poller/
-- observers.web_scraper, directly - that plugin builds everything it needs
-- (including the outbound scrape-fetch transport) from context.connector
-- (embedded_provider above) itself, inside its own setup().
local plugins = require("watchtower_worker_core.plugins")
for _, plugin in ipairs(require("watchtower_worker_core.plugin_loader").require_configured(config.plugins, worker_logger)) do
  table.insert(plugins, plugin)
end

-- context is the one shared table watchtower_worker_core.lifecycle.build
-- hands to every plugin's setup() and every task closes over - see that
-- module's own header comment for the full contract. Built here (no DB I/O
-- of its own - every field is either already-constructed above or a
-- closure), but NOT handed to lifecycle.build yet: that call does real DB
-- I/O (observer_registry construction, via web_scraper's
-- fetch_remote_sites), so it's deferred into the ngx.timer.at(0, ...)
-- callback below, same as build_observer_registry used to be.
local context = {
  config = config,
  connector = embedded_provider,
  observable_types = observable_types,
  -- The "deliver" role plugin's do_run_pending_notify_batch lazily builds
  -- ctx.notification_sender the first time it's missing, defaulting to
  -- notification_senders' own blocking transport - fine for the standalone
  -- worker's plain Lua 5.1 process, but LuaSocket can't run inside this
  -- nginx worker (see embedded_sender's own header comment above), so it
  -- must already be set here, never left for that lazy default to build.
  notification_sender = embedded_sender,
  post_observation = function(observable, observation_result)
    return embedded_provider:post_observation(observable, observation_result)
  end,
  extra_heartbeat_properties = function()
    return { observations_analyzed = observations_analyzed }
  end,
  logger = worker_logger,
}

-- Built inside the boot timer below, alongside worker registration -
-- module-scoped so M.run_role_once (far below) can reach it once boot has
-- completed; nil until then.
local lifecycle

-- jobs.worker_id has a FK to workers, so the 'embedded' worker row must
-- exist before any poller can report a job under that worker id. Retries a
-- few times (short DB hiccups shouldn't need a full heartbeat_interval
-- wait) before giving up and starting every task's own timer anyway - a
-- persistent DB outage shouldn't block every task from starting forever, and a report made
-- before registration succeeds will now fail loudly (FK violation,
-- surfaced via the normal error-logging path) instead of silently
-- succeeding as it used to.
local function register_worker_with_retries(heartbeat_task, max_attempts, retry_delay_seconds)
  for attempt = 1, max_attempts do
    if heartbeat_task.run() then
      return true
    end
    if attempt < max_attempts then
      ngx.sleep(retry_delay_seconds)
    end
  end
  worker_logger.error(
    "worker registration failed after "
      .. max_attempts
      .. " attempts, starting poll loop anyway"
  )
  return false
end

-- Cache-freshness interval for the module-level rule engine below - not
-- exposed as a WORKER_CONFIG_FILE knob (unlike remote_sites_refresh_
-- interval) since this is purely an internal implementation detail, not
-- something an operator needs to tune.
local ENGINE_CACHE_REFRESH_INTERVAL = 60

-- Builds the Lifecycle (real DB I/O - observer_registry construction, via
-- web_scraper's fetch_remote_sites - so this must run inside a ngx.timer
-- callback, not this module's own body/top level), retries worker
-- registration a few times synchronously, then starts every registered
-- task on its own concurrent ngx.timer.every (see `every` above) - heartbeat
-- included, since watchtower_worker_core.lifecycle.build schedules it
-- itself now rather than this file doing so separately. rule_engine is this
-- worker's own long-lived instance, used by every analyzer:analyze call
-- (the per-observation ingest path and both analyze ticks) and entirely
-- separate from the admin `rules` plugin's, which only invalidates itself
-- on rule mutations - so it needs its own periodic invalidate, or a rule
-- created/edited/deleted after its first :match() would be invisible here
-- until a restart; not one of watchtower_worker_core.lifecycle's tasks
-- since it's an internal cache-freshness detail of this runtime's own
-- rule_engine instance, not a role.
local function start_worker()
  local ok, err = ngx.timer.at(0, function()
    -- Real DB I/O, so it must run here, not at module load time (same
    -- "attempt to yield across C-call boundary" constraint as everything
    -- else in this callback). A query failure degrades to zero observers
    -- rather than aborting the whole boot - "degrade, don't crash" for a
    -- config-loading failure, distinct from the observer_registry.new call
    -- inside lifecycle.build below, which is still allowed to raise and
    -- abort boot entirely on a genuinely bad observer config (e.g. a
    -- duplicate observable_type mapping).
    local ok_query, observer_configs_observers = pcall(build_observer_configs_observers)
    if not ok_query then
      worker_logger.error(
        "failed to load observer_configs observers, starting with none: "
          .. tostring(observer_configs_observers)
      )
      observer_configs_observers = {}
    end

    config.observer.observers = observer_configs_observers

    local build_ok, build_result = pcall(require("watchtower_worker_core.lifecycle").build, plugins, context)
    if not build_ok then
      worker_logger.error("failed to build worker lifecycle: " .. tostring(build_result))
      return
    end
    lifecycle = build_result

    local heartbeat_task = lifecycle:task("heartbeat")
    if heartbeat_task then
      register_worker_with_retries(heartbeat_task, 3, 1)
    end

    for _, task in ipairs(lifecycle:tasks()) do
      every(task.name, task.interval, task.run)
    end

    if has_role(config.roles, "analyzer") then
      every("rule engine refresh", ENGINE_CACHE_REFRESH_INTERVAL, function()
        rule_engine:invalidate()
      end)
    end
  end)

  if not ok then
    worker_logger.error("failed to start worker: " .. tostring(err))
  end
end

if ngx and ngx.worker and ngx.worker.id then
  if ngx.worker.id() == 0 then
    start_worker()
  end
end

local M = {}

-- On-demand, single out-of-band pass for one role - see
-- plugins/workers/plugin.lua's POST /api/workers/embedded/run/:role, the
-- embedded worker's closest equivalent to the standalone worker's --once
-- (see worker/lua/main.lua) - this process itself can't be invoked by an
-- external OS cron/systemd timer the way a standalone process can, since it
-- lives inside the server's nginx worker rather than being its own process.
-- Runs every task lifecycle:tasks_by_role(role) returns exactly once,
-- synchronously, from the calling Lapis request handler's own coroutine
-- instead of a timer callback (both are yield-capable, so no special
-- handling is needed here beyond dispatch). Returns (true, nil) once done,
-- or (false, err[, status]) for an unrecognized/undeclared/not-yet-ready
-- role - doesn't itself report success/failure of the underlying claim, same
-- "fire and forget, check logs/jobs/alert_deliveries" contract each task's
-- own timer already has.
function M.run_role_once(role)
  -- The lifecycle (and every boot-time timer) only exists on nginx worker 0
  -- - this module is required in every nginx worker, but a request can land
  -- on any of them (production runs several). Running a role anywhere else
  -- would claim a job and then fail every item against a nil registry, so
  -- refuse up front and let the caller retry.
  if ngx.worker.id() ~= 0 then
    return false,
      "the embedded worker runs on nginx worker 0 only (this request was served by worker "
        .. tostring(ngx.worker.id()) .. "), retry",
      503
  end
  if not has_role(require("watchtower_worker_core.roles").ROLES, role) then
    return false, "unknown role: " .. tostring(role)
  end
  if not has_role(config.roles, role) then
    return false, "role not enabled on this worker: " .. tostring(role)
  end
  if not lifecycle then
    return false, "embedded worker not ready yet, retry", 503
  end
  for _, task in ipairs(lifecycle:tasks_by_role(role)) do
    task.run()
  end
  return true, nil
end

-- Published as a plain Lua global, NOT just returned as this module's
-- table, so plugins/workers/plugin.lua's request handler for
-- POST /api/workers/embedded/run/:role can reach this exact booted
-- instance's closures (scheduler_service, delivery_queue_service, context,
-- etc.) without going through require() again. This
-- module is only ever require()d once, from nginx.conf's
-- init_worker_by_lua_block (see the header comment at the top of this
-- file) - a route handler's own require("workers.observe_pending_worker")
-- would, in dev (lua_code_cache off), re-execute this entire file fresh on
-- every single request that hit it, re-registering a whole second set of
-- ngx.timer.every pollers on top of the ones already running from boot,
-- forever - the exact per-request module-reload trap bootstrap_admin.lua's
-- own header comment warns about, just reached from a request handler
-- instead of a module body. A plain global isn't subject to that reload -
-- it's set once, here, during this file's one-time init_worker execution,
-- and simply read back afterwards.
_G.watchtower_embedded_worker = M

return M
