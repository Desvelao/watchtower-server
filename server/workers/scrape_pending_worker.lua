-- Optional embedded worker (USE_EMBED_WORKER=1) that runs inside the
-- server's nginx worker process (ngx.timer), polling items due for a
-- scrape and driving them through the shared pipeline (shared/worker_*.lua)
-- to actually scrape, ingest an observation, and report job status - all
-- via direct in-process model/service access, no HTTP round trip. Ported
-- from pibuzz's application/workers/alert_pending_worker.lua.
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

if not ok_config then
  ngx.log(
    ngx.ERR,
    "[scrape-worker] failed to load config: " .. tostring(config_err)
  )
end

local EMBEDDED_MONITOR_ID = "embedded"
local WORKER_START_TIME = os.time()

-- Duplicates a slice of plugins/events/plugin.lua's on_create hook rather
-- than reaching into that plugin's request-scoped instance (which doesn't
-- exist yet at nginx worker boot) - same precedent pibuzz's
-- alert_pending_worker.lua set for its own alert_manager.
local rule_engine = require("plugins.rules.services.rule_engine").new(models.Rules)

local function derive_alert_fields(event, match)
  return {
    event_id = event.id,
    priority = (match and match.severity) or "low",
    tags = (match and match.tags) or event.tags,
    pattern = match and match.action or nil,
    rule_id = match and match.id or nil,
  }
end

local function create_alert(event, match)
  local ok, alert = pcall(function()
    return models.Alerts:create(derive_alert_fields(event, match))
  end)
  if not ok then
    ngx.log(ngx.ERR, "[scrape-worker] failed to create alert for event: " .. tostring(alert))
    return false
  end
  return true
end

local function build_match_context(event)
  local payload_data = {}
  if type(event.payload) == "string" then
    payload_data = cjson_safe.decode(event.payload) or {}
  end
  return {
    source = event.source,
    tags = event.tags,
    payload = event.payload,
    item_id = event.item_id,
    price = payload_data.price,
    discount = payload_data.discount,
    available = payload_data.available,
    url = payload_data.url,
  }
end

-- Creates the observation row plus its linked event (so the ingested
-- price runs through the rule engine, same as
-- plugins/observations/plugin.lua's POST handler), returning the
-- observation. `scrape_result` is the {price, discount, available, url}
-- table filter_scrape stashed on the pipeline event.
local function ingest_observation(item, scrape_result)
  local observation = models.Observations:create({
    item_id = item.id,
    price = scrape_result.price,
    url = scrape_result.url or item.url,
    timestamp = db.format_date(),
    discount = scrape_result.discount,
    available = scrape_result.available,
  })

  local event = models.Events:create({
    source = item.name,
    payload = cjson_safe.encode(scrape_result),
    item_id = item.id,
  })

  local ok_match, matches = pcall(function()
    return rule_engine:match(build_match_context(event))
  end)
  if not ok_match then
    ngx.log(ngx.ERR, "[scrape-worker] rule matching failed: " .. tostring(matches))
    matches = {}
  end

  if #matches == 0 then
    create_alert(event, nil)
  else
    for _, match in ipairs(matches) do
      create_alert(event, match)
    end
  end

  return observation
end

-- The single "stalest" enabled item: never-scraped items first (NULL
-- last_scrape_take_at sorts last under Postgres' default ASC/NULLS LAST,
-- so it's pulled to the front explicitly), then whichever was scraped
-- longest ago. No cooldown/backoff is enforced yet - every poll tick
-- re-selects the current stalest item, so a single enabled item is
-- scraped continuously at `poll_interval` cadence; a documented
-- simplification for this first pass; a real cooldown (skip items scraped
-- within the last N seconds) is a natural follow-up once there's more
-- than a handful of items.
local function get_pending_item()
  local rows = models.Items:select(
    "where enabled = true order by (last_scrape_take_at is not null), last_scrape_take_at asc, id asc limit 1"
  )
  return rows[1]
end

local job_manager = require("plugins.jobs.services.jobs").new(models.Jobs, {
  scrape = {
    manager = require("lib.resource_manager").new(models.Items, {}),
    apply = function(d, winner)
      d.last_scrape_status = winner.status
      d.last_scrape_monitor = winner.monitor_id
      if winner.taken_at then
        d.last_scrape_take_at = winner.taken_at
      end
      if winner.acked_at then
        d.last_scrape_ack_at = winner.acked_at
      end
      return d
    end,
  },
})

local monitor_manager = require("plugins.monitors.services.monitors").new(
  models.Monitors,
  models.MonitorHeartbeats
)

local notifier = {
  processing = function(self, item)
    local ok, err = pcall(job_manager.report, job_manager, "scrape", item.id, EMBEDDED_MONITOR_ID, "triggering")
    return ok, err
  end,
  complete = function(self, item, action, message, scrape_result)
    local ok, err = pcall(function()
      ingest_observation(item, scrape_result)
      return job_manager:report("scrape", item.id, EMBEDDED_MONITOR_ID, "acknowledged", action, message)
    end)
    return ok, err
  end,
  error = function(self, item, message)
    local ok, err = pcall(job_manager.report_error, job_manager, "scrape", item.id, EMBEDDED_MONITOR_ID, message)
    return ok, err
  end,
}

-- config itself is env-var/file-only (no DB access), so it's safe to
-- build at module-load time. `scraper` is not: models.ScraperRemote:select()
-- is real DB I/O, which - like bootstrap_admin.lua's insert - must not
-- run directly in this module body. Module bodies get `require`d fresh on
-- every request in dev (lua_code_cache off), and even the one-time
-- init_worker_by_lua_block load runs outside any ngx.timer coroutine, so
-- a yielding DB call here hits OpenResty's "attempt to yield across
-- C-call boundary" - silently, if it's wrapped in a bare pcall, which is
-- exactly what leaves `scraper` registered with zero sites forever. Built
-- inside the ngx.timer.at(0, ...) callback below instead, alongside
-- monitor registration - `scraper` is nil until then, which is fine since
-- nothing calls run_once() before that callback runs.
local config = require("worker_runner").build_config("embedded")
local scraper

local function build_scraper()
  local ok, sites = pcall(function()
    return models.ScraperRemote:select()
  end)
  if not ok then
    ngx.log(ngx.ERR, "[scrape-worker] failed to load scraper sites: " .. tostring(sites))
    sites = {}
  end

  local capabilities
  scraper, capabilities = require("scraper_creator").new(sites)
  config.capabilities = capabilities

  if config.report_config then
    config.reportable_config_json =
      cjson_safe.encode(require("worker_config_report").build_reportable_config(config))
  end
end

local function run_once()
  local ok, err = pcall(function()
    require("worker_runner")({
      mode = "embedded",
      config = config,
      notify = notifier,
      scraper = scraper,
      logger_name = "price-monitor-server",
      extra_ctx = { get_pending_item = get_pending_item },
    })
  end)

  if not ok then
    ngx.log(ngx.ERR, "[scrape-worker] failed to run pipeline: " .. tostring(err))
  end
end

-- Returns true if the monitor row was successfully registered/refreshed.
local function send_heartbeat()
  local ok, err = pcall(function()
    monitor_manager:heartbeat(EMBEDDED_MONITOR_ID, {
      connection_type = "embedded",
      version = config.version,
      capabilities = db.array(config.capabilities),
      item_filter = config.item_filter,
      uptime_seconds = os.time() - WORKER_START_TIME,
      config = config.reportable_config_json,
    })
  end)
  if not ok then
    ngx.log(ngx.ERR, "[scrape-worker] failed to send heartbeat: " .. tostring(err))
  end
  return ok
end

-- jobs.monitor_id has a FK to monitors, so the 'embedded' monitor row
-- must exist before run_once() can report any item's job under that
-- monitor id. Retries a few times (short DB hiccups shouldn't need a full
-- heartbeat_interval wait) before giving up and starting the poll loop
-- anyway - a persistent DB outage shouldn't block scraping forever, and a
-- report made before registration succeeds will now fail loudly (FK
-- violation, surfaced via the normal error-logging path) instead of
-- silently succeeding as it used to.
local function register_monitor_with_retries(max_attempts, retry_delay_seconds)
  for attempt = 1, max_attempts do
    if send_heartbeat() then
      return true
    end
    if attempt < max_attempts then
      ngx.sleep(retry_delay_seconds)
    end
  end
  ngx.log(
    ngx.ERR,
    "[scrape-worker] monitor registration failed after "
      .. max_attempts
      .. " attempts, starting poll loop anyway"
  )
  return false
end

-- Sequenced in one timer callback (rather than two independent
-- ngx.timer.at(0, ...) calls racing each other) so the poll loop never
-- starts before the first heartbeat attempt has resolved.
local function start_worker_with_heartbeat()
  local ok, err = ngx.timer.at(0, function()
    build_scraper()
    register_monitor_with_retries(3, 1)
    run_once()
  end)

  if not ok then
    ngx.log(ngx.ERR, "[scrape-worker] failed to start worker: " .. tostring(err))
  end
end

local function start_heartbeat(interval)
  local ok, err = ngx.timer.every(interval, send_heartbeat)
  if not ok then
    ngx.log(ngx.ERR, "[scrape-worker] failed to start heartbeat timer: " .. tostring(err))
  end
end

if ngx and ngx.worker and ngx.worker.id then
  if ngx.worker.id() == 0 then
    start_worker_with_heartbeat()
    start_heartbeat(config.heartbeat_interval)
  end
end
