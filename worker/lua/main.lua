#!/usr/bin/env lua
-- Standalone worker: polls the server's HTTP API for enabled
-- observables, observes them, posts an observation back, and reports job status.

local socket = require("socket")
local HTTP_PROVIDER = require("watchtower_worker_core.provider_http")
local worker_runner = require("watchtower_worker_core.runner")

-- --once (checked first - visible directly in a systemd unit file or
-- crontab line) or WORKER_RUN_ONCE=1/true (env fallback, for invocation
-- wrappers that can't easily pass argv) - if either is set, this process
-- performs exactly one claim/process/report pass per configured role and
-- exits, instead of looping forever under its own polling intervals. See
-- docs/dev/worker-configuration.md's "Running as a one-shot job" section.
local function resolve_run_once()
  for _, a in ipairs(arg or {}) do
    if a == "--once" then return true end
  end
  local env = os.getenv("WORKER_RUN_ONCE")
  return env == "1" or env == "true"
end

-- --role=<name> (repeatable) or --roles=a,b (checked first, same
-- argv-over-env precedence as resolve_run_once), else WORKER_RUN_ONCE_ROLES
-- (comma-separated env fallback) - restricts a --once/WORKER_RUN_ONCE pass to
-- just this subset of config.roles, instead of running every role the
-- config file declares. Lets one WORKER_CONFIG_FILE back several separate
-- cron entries, one per role (e.g. a tight "deliver" schedule alongside a
-- loose "scheduler" one) without duplicating config per role. Returns nil
-- (run every configured role, today's behavior) when neither is set.
local function resolve_role_filter()
  local roles
  local function add_list(list)
    roles = roles or {}
    for r in list:gmatch("[^,]+") do
      table.insert(roles, r)
    end
  end
  local argv = arg or {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    -- `--role=x`/`--roles=a,b`, or the space-separated `--role x`/`--roles a,b`
    local value = a:match("^%-%-roles?=(.+)$")
    if not value and (a == "--role" or a == "--roles") then
      value = argv[i + 1]
      i = i + 1
    end
    if value then
      add_list(value)
    end
    i = i + 1
  end
  if roles then
    return roles
  end
  local env = os.getenv("WORKER_RUN_ONCE_ROLES")
  if env and env ~= "" then
    add_list(env)
    return roles
  end
  return nil
end

-- watchtower_worker_core is a publishable library and never reads the
-- environment itself (see runner.lua's own header comment) - this is the
-- one place the standalone worker resolves every env var build_config
-- actually uses, and hands them in as plain values.
local env = {
  WORKER_CONFIG_FILE = os.getenv("WORKER_CONFIG_FILE"),
  LOG_LEVEL = os.getenv("LOG_LEVEL"),
  SERVER_API_KEY_FILE = os.getenv("SERVER_API_KEY_FILE"),
  SERVER_API_KEY = os.getenv("SERVER_API_KEY"),
  SMTP_HOST = os.getenv("SMTP_HOST"),
  SMTP_PORT = os.getenv("SMTP_PORT"),
  SMTP_USER = os.getenv("SMTP_USER"),
  SMTP_PASSWORD_FILE = os.getenv("SMTP_PASSWORD_FILE"),
  SMTP_PASSWORD = os.getenv("SMTP_PASSWORD"),
  SMTP_FROM = os.getenv("SMTP_FROM"),
  SMTP_SSL = os.getenv("SMTP_SSL"),
}
local config = worker_runner.build_config("standalone", env)
local http_provider = HTTP_PROVIDER.new(config)
-- Lives on the connector object itself (context.connector.connection_type),
-- not as a separate context field - see watchtower_worker_core.lifecycle's
-- own header comment for the connector contract.
http_provider.connection_type = "http"

local observable_types = require("watchtower_worker_core.observable_type_cache").new(function(id)
  return http_provider:get_observable_type(id)
end)

-- The five built-in role plugins (scheduler/analyzer/
-- evaluator/deliver/observer - see
-- shared/watchtower_worker_core/plugins/init.lua), plus whichever
-- observer-type/task plugin(s) config.plugins names (see
-- watchtower_worker_core.runner's build_config and plugin_loader.lua) -
-- config.plugins defaults to {}, so a WORKER_CONFIG_FILE wanting to observe
-- products must list "watchtower_observer_web_scraper.plugin" explicitly.
-- This file never touches watchtower_worker_core.observer_registry,
-- watchtower_observer_web_scraper's own
-- observer_config_test_poller/observers.web_scraper, or
-- provider_http.lua's site-config/test-observation methods directly - that
-- plugin builds everything it needs (including the outbound scrape-fetch
-- transport) from context.connector (http_provider below) itself, inside
-- its own setup(); this worker only ever gets the vendored rock's own
-- blocking default, since context.connector.connection_type is "http", not
-- "embedded". A third-party plugin module needs no code change here at all
-- - just add its module path to config.plugins and make sure it's on
-- LUA_PATH (e.g. the worker_plugins/ bind mount - see dev/docker-compose.yml).
local plugins = require("watchtower_worker_core.plugins")
for _, plugin in ipairs(require("watchtower_worker_core.plugin_loader").require_configured(config.plugins, require("watchtower_worker_core.logger").new("plugin-loader", config.log_level))) do
  table.insert(plugins, plugin)
end

-- context is the one shared table watchtower_worker_core.lifecycle.build
-- hands to every plugin's setup() and every task closes over - see that
-- module's own header comment for the full contract.
local context = {
  config = config,
  connector = http_provider,
  observable_types = observable_types,
  -- observer.source = "interval"'s ctx.post_observation (see
  -- shared/watchtower_worker_core/processors.lua's process_observable) -
  -- posts the observation with no per-observable jobs row, same
  -- job-report-free primitive observer.source = "queue" already uses.
  post_observation = function(observable, observation_result)
    return http_provider:post_observation(observable, observation_result)
  end,
  logger_name = "watchtower-worker",
}

local lifecycle = require("watchtower_worker_core.lifecycle").build(plugins, context)

-- --once/WORKER_RUN_ONCE always forces a single run_once pass (mode =
-- "sequence"), regardless of config.mode - preserves every existing
-- cron/systemd one-shot recipe (see docs/dev/worker-configuration.md's
-- "Running as a one-shot job" section) unchanged even for a WORKER_CONFIG_FILE
-- that also sets mode. Otherwise config.mode (defaulting to "loop" - see
-- watchtower_worker_core.runner's build_config) picks the run style: "sequence"
-- (a single pass then exit, config-driven rather than flag-driven),
-- "sequence-interval" (repeated full passes, waiting config.sequence_interval
-- between them), or "loop" (today's persistent per-task-interval loop).
local run_opts = {
  mode = resolve_run_once() and "sequence" or config.mode,
  roles_filter = resolve_role_filter(),
  logger = context.logger,
  -- Sub-second clock/sleep (luasocket is already a hard dependency of
  -- provider_http.lua) - loop.lua's/schedule.lua's defaults are os.time's 1s
  -- resolution and a forked shell `sleep`.
  clock = socket.gettime,
  sleep = socket.sleep,
}

if run_opts.mode == "sequence-interval" then
  run_opts.interval = config.sequence_interval
end

-- The role filter only narrows a run_once-based pass ("sequence"/
-- "sequence-interval"); the persistent loop always runs every role
-- config.roles declares, so say so rather than silently ignoring what looks
-- like an instruction.
if run_opts.mode == "loop" and resolve_role_filter() then
  context.logger.warn(
    "--role/--roles/WORKER_RUN_ONCE_ROLES only apply with --once/WORKER_RUN_ONCE or mode=sequence/sequence-interval; running every configured role"
  )
end

local ok = lifecycle:run(run_opts)
if run_opts.mode == "sequence" then
  os.exit(ok and 0 or 1)
end
