local Logger = require("watchtower_worker_core.logger")

local M = {}

-- This module never reads the environment itself (this is a publishable
-- library, shared/watchtower_worker_core, not tied to any one consumer's
-- config source) - build_config's `env` parameter is a plain table of
-- already-resolved values the caller assembles however it likes (typically
-- worker/lua/main.lua/server/workers/observe_pending_worker.lua reading
-- os.getenv for each name build_config below actually uses).

-- A value only counts when it's non-empty: a caller sourcing `env` from
-- os.getenv commonly sees `${VAR:-}`-style docker-compose exports that are
-- unconditionally set to "", so an empty string must fall through to the
-- next source instead of masking it (Lua treats "" as truthy, so a bare
-- `value or fallback` would never fall back).
local function nonempty(value)
  if value ~= nil and value ~= "" then
    return value
  end
  return nil
end

-- Boolean value: nil/empty -> `default`; "0"/"false"/"no"/"off" (any case)
-- -> false; anything else -> true.
local function parse_bool(value, default)
  value = nonempty(value)
  if value == nil then
    return default
  end
  value = value:lower()
  return not (value == "0" or value == "false" or value == "no" or value == "off")
end

-- A secret can come from three places, most-secure-first:
--   1. `file_path` - a path to a file to read it from at startup, rather
--      than holding the value itself. Never appears in
--      `docker inspect`/`ps`/`/proc/<pid>/environ` - only a path does. This
--      is also the whole Docker/Compose secrets integration: a secret
--      mounted at /run/secrets/<name> is just a file, so a caller passing
--      env.SERVER_API_KEY_FILE=/run/secrets/server_api_key as `file_path`
--      is all that's needed, no separate "Docker secrets" code path.
--   2. `plain_value` - the plain value, visible via the mechanisms above,
--      but simplest.
--   3. the caller's own fallback (a field in WORKER_CONFIG_FILE itself) -
--      least secure of the three unless that file is kept out of version
--      control and tightly permissioned (same risk as any secret sitting in
--      a config file).
-- An unreadable/empty `file_path` falls through to the next source (logged
-- as a warning) rather than crashing worker startup. Used for the server API
-- key and the SMTP relay's password - the only settings sensitive enough to
-- warrant it (everything else is a plain value-or-file value in
-- build_config below). Note this is not itself "reading an env var" - it
-- just prefers a secret given as a file path over one given directly,
-- regardless of where either candidate value came from.
local function resolve_secret(file_path, plain_value, logger)
  if file_path then
    local f = io.open(file_path, "r")
    if f then
      local contents = f:read("*a")
      f:close()
      local trimmed = contents:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        return trimmed
      end
      logger.warn(string.format("secret file '%s' is empty, falling back", file_path))
    else
      logger.warn(string.format("secret file '%s' could not be opened, falling back", file_path))
    end
  end
  return nonempty(plain_value)
end

local function resolve_server_api_key(env, logger)
  return resolve_secret(env.SERVER_API_KEY_FILE, env.SERVER_API_KEY, logger)
end

local function resolve_smtp_password(env, logger)
  return resolve_secret(env.SMTP_PASSWORD_FILE, env.SMTP_PASSWORD, logger)
end

-- Every other worker setting lives in WORKER_CONFIG_FILE (a .lua file -
-- see config_provider_file.lua). This loads that file once and builds the
-- whole config from it - connectivity/timing fields below, plus `sites`
-- (untouched here, just passed through for scraper_creator.lua to read
-- directly, so the file is only ever loaded from this one place).
-- config_provider.lua/config_provider_file.lua are generic file-loading
-- utilities, not part of scraper_creator.lua - only this worker-app layer
-- knows about WORKER_CONFIG_FILE at all.
--
-- Every setting specific to one worker role lives namespaced under
-- config.<role name> (config.observer/.scheduler/.deliver/.analyzer/
-- .evaluator, matching the exact vocabulary
-- config.roles/has_role/WORKER_ROLES already use), always built regardless
-- of whether that role is actually enabled this run - only the fields
-- genuinely shared across roles, or about the worker process itself, stay
-- at the config root (version/interval/heartbeat_interval/worker_id/
-- report_config/roles/server.*).
--
-- `env` (a plain table, default {}) is every already-resolved value this
-- function reads below, keyed by the same name a caller sourcing it from
-- os.getenv would use (WORKER_CONFIG_FILE, LOG_LEVEL, SERVER_API_KEY_FILE/
-- SERVER_API_KEY, USE_EMBED_SCHEDULER/USE_EMBED_DELIVER/USE_EMBED_EVALUATOR,
-- SMTP_HOST/SMTP_PORT/SMTP_USER/SMTP_PASSWORD_FILE/SMTP_PASSWORD/SMTP_FROM/
-- SMTP_SSL) - this module never calls os.getenv itself (see this file's own
-- header note above resolve_secret), so worker/lua/main.lua/
-- server/workers/observe_pending_worker.lua are the ones that actually read
-- the environment, each assembling its own `env` table before calling this.
function M.build_config(mode, env)
  env = env or {}
  local logger = Logger.new("worker_runner", env.LOG_LEVEL)
  local config = {}

  local worker_config_file = env.WORKER_CONFIG_FILE

  local file_config = {}
  if worker_config_file then
    file_config = require("watchtower_worker_core.config_provider")
      .new({ source = "file", path = worker_config_file, log_level = env.LOG_LEVEL })
      :get()
  end

  config.version = file_config.version or "dev"
  -- Opt-in (default off): whether this worker should self-report its own
  -- (secret-scrubbed) configuration in heartbeats - see
  -- worker_config_report.lua.
  config.report_config = file_config.report_config or false
  -- Threaded through to every Logger.new(...) call downstream that wants it
  -- (watchtower_worker_core.provider_http/.lifecycle) - see logger.lua's own
  -- header comment for why this module no longer resolves it via os.getenv
  -- itself.
  config.log_level = env.LOG_LEVEL

  if mode == "standalone" then
    if file_config.server then
      config.server = {
        base_url = file_config.server.address,
        api_key = resolve_server_api_key(env, logger) or file_config.server.api_key,
        batch_size = file_config.server.batch_size or 10,
      }
    end
    -- The worker's registered identity - a config-file root field (not
    -- nested under server), since it's used far beyond just the HTTP
    -- transport (heartbeats, job reports, delivery claims all key off it).
    config.worker_id = file_config.worker_id or "worker-lua"

    -- Shared default claim/tick cadence, applied below to every role that
    -- doesn't set its own config.<role>.interval (see role_interval
    -- below) - not itself role-specific.
    config.interval = file_config.interval or 5
    config.heartbeat_interval = file_config.heartbeat_interval or 30
    -- The heartbeat task's own post-failure retry backoff - deliberately a
    -- separate field from config.interval/heartbeat_interval above, since
    -- those both accept a cron expression string while this must always be
    -- a plain number of seconds (watchtower_worker_core.lifecycle validates
    -- it as such and drops the whole heartbeat task otherwise).
    config.heartbeat_retry_interval = file_config.heartbeat_retry_interval or 5
    -- Which roles this worker process self-reports/runs - decoupled from
    -- any single role's own logic (see shared/watchtower_worker_core/processors.lua's
    -- has_role). Defaults to {"observer"} for backward compatibility with
    -- any WORKER_CONFIG_FILE that predates this field.
    config.roles = file_config.roles or { "observer" }
    -- Which run style this worker process uses - see
    -- watchtower_worker_core.lifecycle's :run(opts). Defaults to "loop"
    -- (today's persistent per-task-interval loop), so any WORKER_CONFIG_FILE
    -- that predates this field keeps behaving exactly as before.
    -- "sequence"/"sequence-interval" are only ever selected here when
    -- --once/WORKER_RUN_ONCE is NOT also given - see worker/lua/main.lua.
    config.mode = file_config.mode or "loop"
    -- Only meaningful when config.mode == "sequence-interval": the wait
    -- between one full sequence pass finishing and the next starting - a
    -- plain number of seconds, or a cron expression string
    -- (watchtower_worker_core.schedule's usual dual form, same grammar as
    -- any role's own interval). Falls back to the shared root config.interval
    -- above when unset, same "role has its own interval, defaulting to the
    -- shared one" pattern role_interval implements below - an operator only
    -- needs to set this explicitly when the pass cadence should differ from
    -- that shared default (e.g. a fast pass alongside a deliberately slow
    -- per-role interval - see docs/dev/worker-configuration.md).
    config.sequence_interval = file_config.sequence_interval or config.interval
  elseif mode == "embedded" then
    config.interval = file_config.interval or 10
    config.heartbeat_interval = file_config.heartbeat_interval or 30
    config.heartbeat_retry_interval = file_config.heartbeat_retry_interval or 5
    config.worker_id = "embedded"
    -- Always observer+analyzer (unchanged default); "scheduler"/"deliver"/
    -- "evaluator" are independently opt-in via their
    -- own env flags, each gated separately from USE_EMBED_WORKER (see
    -- server/workers/observe_pending_worker.lua).
    config.roles = { "observer", "analyzer" }
    if env.USE_EMBED_SCHEDULER == "1" then
      table.insert(config.roles, "scheduler")
    end
    if env.USE_EMBED_DELIVER == "1" then
      table.insert(config.roles, "deliver")
    end
    if env.USE_EMBED_EVALUATOR == "1" then
      table.insert(config.roles, "evaluator")
    end
  else
    error(
      string.format(
        "worker_runner.build_config: unknown mode '%s'",
        tostring(mode)
      )
    )
  end

  -- Array of Lua module path strings (e.g. "watchtower_observer_web_scraper.plugin"),
  -- each require()d by plugin_loader.require_configured and appended to
  -- watchtower_worker_core.plugins' five built-ins before lifecycle.build runs -
  -- see worker/lua/main.lua/server/workers/observe_pending_worker.lua. Applies to
  -- both modes identically, same as config.observer/config.scheduler below.
  -- Defaults to {} - nothing beyond the five built-in role plugins is loaded
  -- unless named here, so an operator wanting to observe products must list
  -- watchtower_observer_web_scraper.plugin explicitly (it is no longer
  -- unconditional).
  config.plugins = file_config.plugins or {}

  -- Default "does a task run immediately at worker boot, or wait for its
  -- first interval/cron match?" for every role's task(s) in "loop" mode (see
  -- watchtower_worker_core.loop's M.run) - each role's own <role>.run_on_start
  -- (below) falls back to this when it doesn't set its own. Meaningless for
  -- "sequence"/"sequence-interval" mode (every task always runs on every
  -- pass there) and for the embedded worker (never consumes loop.lua).
  config.run_on_start = file_config.run_on_start ~= false

  -- A role's own interval, falling back to the shared config.interval
  -- above (itself already mode-defaulted to 5s/10s) when the role doesn't set
  -- one of its own. Only called after config.interval is resolved above.
  -- NOT used for "scheduler", which has its own, deliberately slower,
  -- independent default - see config.scheduler below.
  local function role_interval(role_key)
    local role_config = file_config[role_key]
    return (role_config and role_config.interval) or config.interval
  end

  -- A role's own run_on_start, falling back to the shared config.run_on_start
  -- above when the role doesn't set one of its own. Unlike role_interval,
  -- needs an explicit nil-check rather than a plain `or`: `false` is itself a
  -- meaningful override that `or` would otherwise skip past.
  local function role_run_on_start(role_key)
    local role_config = file_config[role_key]
    if role_config and role_config.run_on_start ~= nil then
      return role_config.run_on_start
    end
    return config.run_on_start
  end

  -- "observer"-role settings - see shared/watchtower_worker_core/processors.lua's
  -- build_tasks (do_run_pending_observe_batch/do_run_interval_observe) and
  -- server/workers/observe_pending_worker.lua's poll_pending_observe_batch.
  local file_observer = file_config.observer or {}
  local file_observer_test_poll = file_observer.test_poll or {}
  config.observer = {
    -- Where an "observer"-role tick gets its next Observable from - an
    -- explicit either/or, not a hybrid:
    --   "queue" (default) - ONLY claims a pending type='observe' `jobs` row
    --     the scheduler queued (see shared/watchtower_worker_core/processors.lua's
    --     do_run_pending_observe_batch and server/workers/observe_pending_worker.lua's
    --     poll_pending_observe_batch). If nothing is currently pending, this
    --     tick does nothing (no fallback to interval polling) - observing
    --     only ever happens for scheduler-generated work (an
    --     admin-configured scheduler_tasks task), giving an operator strict
    --     control over what gets observed and when. A fresh deployment with
    --     no scheduler_tasks configured yet therefore observes nothing until
    --     one is created.
    --   "interval" - the original continuous "stalest enabled observable"
    --     polling (get_pending_observable/_fetch_observable_batch),
    --     unconditionally. The scheduler's queue is never consulted - a
    --     worker in this mode ignores scheduling entirely, exactly like
    --     before the "scheduler" role existed.
    -- Any other value falls back to "queue" - same "prefer the new default"
    -- treatment as an absent field.
    source = file_observer.source == "interval" and "interval" or "queue",
    -- Array of {id, type, observable_type, url_property?, sites_source?,
    -- remote_sites_refresh_interval?, ...type-specific fields} - standalone
    -- only (the embedded worker's one observer is hardcoded inline instead,
    -- see server/workers/observe_pending_worker.lua's
    -- build_observer_registry, which never reads this array). Each entry's
    -- own sites_source/remote_sites_refresh_interval is read directly by
    -- that observer type's own module (e.g. watchtower_observer_web_scraper.observers.web_scraper),
    -- which re-fetches its own remote site list as part of its own :run,
    -- on its own cadence - this file has no involvement in that at all,
    -- and just passes the array through unexamined.
    observers = file_observer.observers,
    interval = role_interval("observer"),
    run_on_start = role_run_on_start("observer"),
    -- Independent enable/disable for the two things this role's
    -- config.plugins can register: the main observe task itself (built-in
    -- watchtower_worker_core.plugins.observer, gated on top of the existing
    -- has_role(roles, "observer") check) and, in test_poll below, the
    -- ad-hoc "test this scraper config against a URL" poller
    -- (worker_plugins/watchtower_observer_web_scraper/plugin.lua's
    -- observer_config_test_poll task, which has no role of its own at all
    -- today). Lets an operator dedicate one worker to the main
    -- observe/analyze/evaluate/deliver flow and another to just servicing
    -- test requests - see docs/dev/worker-configuration.md.
    observe = {
      enabled = (file_observer.observe and file_observer.observe.enabled) ~= false,
    },
    test_poll = {
      enabled = (file_observer_test_poll.enabled) ~= false,
      -- nil = falls back to the shared root config.interval, resolved
      -- where this is actually consumed (watchtower_observer_web_scraper's
      -- plugin.lua) - same "role has its own interval, defaulting to
      -- the shared one" pattern role_interval implements above, but
      -- test_poll isn't itself a role, so it can't reuse that helper as-is.
      interval = file_observer_test_poll.interval,
    },
  }

  -- "scheduler"-role settings - see shared/watchtower_worker_core/processors.lua's
  -- do_fire_due_tasks and server/workers/observe_pending_worker.lua's
  -- poll_and_fire_due_tasks.
  local file_scheduler = file_config.scheduler or {}
  local file_scheduler_reap_stale = file_scheduler.reap_stale or {}
  config.scheduler = {
    -- How often (seconds) a "scheduler"-role tick evaluates scheduler_tasks
    -- for due tasks. Cron granularity is minute-level, so polling much
    -- faster buys nothing - defaults to a much slower 30s of its own
    -- (deliberately NOT role_interval's shared 5s/10s default) unless
    -- an operator explicitly opts it in via scheduler.interval, or the
    -- shared root interval, themselves.
    interval = file_scheduler.interval or file_config.interval or 30,
    -- How often (seconds) a "scheduler"-role tick reaps `jobs` rows stuck in
    -- 'triggering' (.interval), and how long a 'triggering' job may go
    -- without a report before it's considered stale (.timeout_seconds) -
    -- see shared/watchtower_worker_core/pollers/reap_stale.lua,
    -- .../processors.lua's build_tasks (reap_stale_jobs), and
    -- server/workers/observe_pending_worker.lua's start_stale_job_reap. A job
    -- whose claiming worker crashed/hung mid-observe without ever reporting
    -- would otherwise wedge jobs_active_unique_idx forever, permanently
    -- blocking any future claim for that same (worker_id, type, ref_id).
    -- Housekeeping for the whole `jobs` queue, but gated on this role like
    -- every other scheduler.* setting - only a worker that also evaluates
    -- scheduler_tasks reaps stale jobs.
    reap_stale = {
      interval = file_scheduler_reap_stale.interval or 60,
      timeout_seconds = file_scheduler_reap_stale.timeout_seconds or 300,
    },
    run_on_start = role_run_on_start("scheduler"),
  }

  -- "deliver"-role settings - see shared/watchtower_worker_core/processors.lua's
  -- do_run_pending_notify_batch and server/workers/observe_pending_worker.lua's
  -- poll_pending_notify_batch.
  local file_deliver = file_config.deliver or {}
  local file_smtp = file_deliver.smtp or {}
  config.deliver = {
    -- Where a "deliver"-role tick gets its work from - an explicit
    -- either/or, mirroring observer.source's own "queue"|"interval" split
    -- above:
    --   "deliveries" (default) - claims/reports directly against the
    --     alert_deliveries queue (see shared/watchtower_worker_core/processors.lua's
    --     do_run_pending_notify_batch and plugins/notification_channels/
    --     services/delivery_queue.lua), fully independent of scheduler_tasks/
    --     jobs. Lets any number of deliver workers drain the queue
    --     concurrently (FOR UPDATE SKIP LOCKED).
    --   "queue" - claims a scheduler_tasks type='deliver' job instead (the
    --     same PUT /api/scheduler/claim route/claim_next_batch the other
    --     three scheduler-fired roles already use), so a "deliver" tick's
    --     own cadence is admin-configured via a scheduler_tasks row rather
    --     than this worker's own interval. See processors.lua's
    --     do_run_pending_notify_batch for exactly how it maps back onto the
    --     same alert_deliveries claim/send/report underneath.
    -- Any other value falls back to "deliveries" - same "prefer the current
    -- default" treatment as an absent field.
    source = file_deliver.source == "queue" and "queue" or "deliveries",
    -- The SMTP relay used by "deliver"-role email channels, resolved the
    -- same env-first-then-file way as server.api_key above. `host`
    -- absent/empty means "email isn't configured" - see
    -- shared/watchtower_worker_core/notification_senders.lua's SENDERS.email, which treats a
    -- host-less config as a per-alert send failure rather than a crash.
    smtp = {
      host = nonempty(env.SMTP_HOST) or file_smtp.host,
      port = tonumber(env.SMTP_PORT) or file_smtp.port or 465,
      user = nonempty(env.SMTP_USER) or file_smtp.user,
      password = resolve_smtp_password(env, logger) or file_smtp.password,
      from = nonempty(env.SMTP_FROM) or file_smtp.from,
      ssl = parse_bool(env.SMTP_SSL, file_smtp.ssl ~= false),
    },
    interval = role_interval("deliver"),
    run_on_start = role_run_on_start("deliver"),
  }

  -- "analyzer"-role settings - see shared/watchtower_worker_core/processors.lua's
  -- do_run_pending_analyze_batch/do_run_interval_analyze_all.
  local file_analyzer = file_config.analyzer or {}
  config.analyzer = {
    -- Where an "analyzer"-role tick gets its work from - an explicit
    -- either/or, mirroring observer.source above:
    --   "queue" (default) - ONLY claims a pending scheduler_tasks
    --     type='analyze' job (unchanged, original behavior).
    --   "interval" - re-runs rule matching against every currently enabled
    --     observable's latest stored observation, unconditionally, on this
    --     role's own interval cadence. scheduler_tasks is never
    --     consulted, and no `jobs` row is involved at all.
    -- Any other value falls back to "queue" - same "prefer the current
    -- default" treatment as an absent field.
    source = file_analyzer.source == "interval" and "interval" or "queue",
    interval = role_interval("analyzer"),
    run_on_start = role_run_on_start("analyzer"),
  }
  -- "evaluator"-role settings - same either/or shape
  -- as analyzer.source above, mirroring it exactly:
  --   "queue" (default) - ONLY claims a pending scheduler_tasks
  --     type='notify' job (unchanged, original behavior).
  --   "interval" - matches every candidate alert (one with no
  --     alert_deliveries row yet, or with at least one in status='error')
  --     against every currently enabled notification_policies,
  --     unconditionally, on this role's own interval cadence.
  --     scheduler_tasks is never consulted, and no `jobs` row is involved
  --     at all - the same shared/watchtower_worker_core/
  --     notification_policy_matcher.lua pass both modes run, in-process for
  --     embedded (server/workers/observe_pending_worker.lua's
  --     poll_pending_evaluate_interval) and over HTTP for standalone
  --     (shared/watchtower_worker_core/provider_http.lua's evaluate_notify_policies) - never a
  --     server-side "evaluate" endpoint, since matching must never happen
  --     inside an API route handler.
  local file_evaluate = file_config.evaluator or {}
  local file_evaluate_reap_stale = file_evaluate.reap_stale or {}
  config.evaluator = {
    source = file_evaluate.source == "interval" and "interval" or "queue",
    interval = role_interval("evaluator"),
    -- How often (seconds) an "evaluator"-role tick reaps `alert_deliveries`
    -- rows stuck in 'triggering' (.interval), and how long a 'triggering'
    -- row may go without a report before it's considered stale
    -- (.timeout_seconds) - mirrors scheduler.reap_stale above exactly, see
    -- shared/watchtower_worker_core/pollers/reap_stale_deliveries.lua and
    -- server/plugins/notification_channels/services/delivery_queue.lua's
    -- reap_stale. A delivery whose claiming "deliver"-role worker
    -- crashed/hung mid-send without ever reporting would otherwise sit in
    -- 'triggering' forever, never sent and never retried.
    reap_stale = {
      interval = file_evaluate_reap_stale.interval or 60,
      timeout_seconds = file_evaluate_reap_stale.timeout_seconds or 300,
    },
    run_on_start = role_run_on_start("evaluator"),
  }

  return config
end

-- The persistent loop/one-shot-pass responsibilities that used to live here
-- (`run(opts)`/`M.run_once(opts)`, driven by a `build_ctx` merging
-- opts.notify/observer_registry/observable_types/config/extra_ctx) moved to
-- watchtower_worker_core.lifecycle: a worker entry point now builds its own
-- `context` table directly and calls
-- watchtower_worker_core.lifecycle.build(plugins, context) to get back a
-- Lifecycle exposing :run_loop(opts)/:run_once(opts) - see
-- worker/lua/main.lua and server/workers/observe_pending_worker.lua. This
-- module keeps only build_config(mode, env) above, which is unrelated to
-- that (a plain WORKER_CONFIG_FILE-plus-already-resolved-values loader, no
-- task/lifecycle concerns).
return M
