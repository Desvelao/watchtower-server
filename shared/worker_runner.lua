local Logger = require("logger")

local logger = Logger.new("worker_runner")

local M = {}

-- The server API key can come from three places, most-secure-first:
--   1. SERVER_API_KEY_FILE - an env var naming a file to read it from at
--      startup, rather than holding the value itself. Never appears in
--      `docker inspect`/`ps`/`/proc/<pid>/environ` - only a path does. This
--      is also the whole Docker/Compose secrets integration: a secret
--      mounted at /run/secrets/<name> is just a file, so
--      SERVER_API_KEY_FILE=/run/secrets/server_api_key is all that's
--      needed, no separate "Docker secrets" code path.
--   2. SERVER_API_KEY - the plain env var, visible via the mechanisms
--      above, but simplest.
--   3. `server.api_key` in WORKER_CONFIG_FILE itself - least secure of the
--      three unless that file is kept out of version control and tightly
--      permissioned (same risk as any secret sitting in a config file).
-- An unreadable/empty SERVER_API_KEY_FILE falls through to the next source
-- (logged as a warning) rather than crashing worker startup.
local function resolve_server_api_key()
  local key_file = os.getenv("SERVER_API_KEY_FILE")
  if key_file then
    local f = io.open(key_file, "r")
    if f then
      local contents = f:read("*a")
      f:close()
      local trimmed = contents:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        return trimmed
      end
      logger.warn(
        string.format(
          "SERVER_API_KEY_FILE '%s' is empty, falling back",
          key_file
        )
      )
    else
      logger.warn(
        string.format(
          "SERVER_API_KEY_FILE '%s' could not be opened, falling back",
          key_file
        )
      )
    end
  end
  return os.getenv("SERVER_API_KEY")
end

-- Every other worker setting lives in WORKER_CONFIG_FILE (a .lua file -
-- see config_provider_file.lua). This loads that file once and builds the
-- whole config from it - connectivity/timing fields below, plus `sites`
-- (untouched here, just passed through for scraper_creator.lua to read
-- directly, so the file is only ever loaded from this one place).
-- config_provider.lua/config_provider_file.lua are generic file-loading
-- utilities, not part of scraper_creator.lua - only this worker-app layer
-- knows about WORKER_CONFIG_FILE at all.
function M.build_config(mode)
  local config = {}

  config.worker_config_file = os.getenv("WORKER_CONFIG_FILE") or nil

  local file_config = {}
  if config.worker_config_file then
    file_config = require("config_provider")
      .new({ source = "file", path = config.worker_config_file })
      :get()
  end

  -- Self-reported in heartbeats, same query-param syntax as GET
  -- /api/items (e.g. "enabled=true"). Informational only - not parsed or
  -- enforced server-side.
  config.item_filter = file_config.item_filter
  config.version = file_config.version or "dev"
  config.sites = file_config.sites
  -- Opt-in (default off): whether this worker should self-report its own
  -- (secret-scrubbed) configuration in heartbeats - see
  -- worker_config_report.lua.
  config.report_config = file_config.report_config or false

  if mode == "standalone" then
    if file_config.server then
      config.server = {
        base_url = file_config.server.address,
        api_key = resolve_server_api_key() or file_config.server.api_key,
        batch_size = file_config.server.batch_size or 10,
        monitor_id = file_config.server.monitor_id or "worker-lua",
        version = file_config.server.version or config.version,
      }
    end

    config.poll_interval = file_config.poll_interval or 5
    config.heartbeat_interval = file_config.heartbeat_interval or 30
  elseif mode == "embedded" then
    config.poll_interval = file_config.poll_interval or 10
    config.heartbeat_interval = file_config.heartbeat_interval or 30
    config.monitor_id = "embedded"
  else
    error(
      string.format(
        "worker_runner.build_config: unknown mode '%s'",
        tostring(mode)
      )
    )
  end

  return config
end

local function build_processors()
  local worker_processors = require("worker_processors")

  return {
    inputs = {
      input_http = worker_processors.input_http,
      input_db_poll = worker_processors.input_db_poll,
      input_sleep = worker_processors.input_sleep,
    },
    filters = {
      filter_processing = worker_processors.filter_processing,
      filter_scrape = worker_processors.filter_scrape,
      filter_ack = worker_processors.filter_ack,
      filter_drop = worker_processors.filter_drop,
    },
    outputs = {
      output_console = worker_processors.output_console,
    },
  }
end

local function run(opts)
  if not opts or not opts.mode then
    error("worker_runner: opts.mode is required")
  end
  if not opts.notify then
    error("worker_runner: opts.notify is required")
  end
  if not opts.scraper then
    error("worker_runner: opts.scraper is required")
  end
  if not opts.logger_name then
    error("worker_runner: opts.logger_name is required")
  end

  local config = opts.config or M.build_config(opts.mode)

  local processors = build_processors()
  local pipeline = require("worker_pipeline")(config, opts.mode)

  local ctx = {
    notify = opts.notify,
    scraper = opts.scraper,
    config = config,
  }

  if opts.extra_ctx then
    for k, v in pairs(opts.extra_ctx) do
      ctx[k] = v
    end
  end

  local luastash = require("luastash")

  return luastash(pipeline, processors, ctx, {
    logger = luastash.Logger:new({
      name = opts.logger_name,
      level = opts.logger_level or "debug",
    }),
  })
end

return setmetatable(M, {
  __call = function(_, opts)
    return run(opts)
  end,
})
