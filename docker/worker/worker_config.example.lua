-- Reference WORKER_CONFIG_FILE for the standalone scrape worker
-- (worker/lua/main.lua). Copy to outputs/worker_config.lua (gitignored -
-- see .gitignore) and edit; the dev compose stack mounts
-- ../outputs:/etc/price-monitor/outputs and defaults
-- WORKER_CONFIG_FILE to /etc/price-monitor/outputs/worker_config.lua (see
-- dev/docker-compose.yml). Every field here also applies to the embedded
-- worker (USE_EMBED_WORKER=1 on the `lapis` service) except `server`,
-- which embedded ignores - it talks to the database directly, not over
-- the HTTP API.
return {
  -- Self-reported in heartbeats; purely informational.
  version = "0.1.0",

  -- How often (seconds) to poll for items due a scrape.
  poll_interval = 10,

  -- How often (seconds) to send a monitor heartbeat.
  heartbeat_interval = 30,

  -- Self-reported in heartbeats, query-param-shaped (e.g. "enabled=true").
  -- Informational only - not parsed or enforced server-side.
  item_filter = "enabled=true",

  -- Standalone-only: how this worker reaches the server. The API key
  -- comes from (most-secure-first): SERVER_API_KEY_FILE (a path to a
  -- separately-permissioned secret file - how Docker/Compose secrets
  -- integrate too), the SERVER_API_KEY env var, or `server.api_key`
  -- below (least secure - only reasonable in a gitignored/tightly
  -- permissioned file). Create a real key via POST /api/auth/api_key
  -- (needs api_key:manage; see docs/dev/README.md) before using this for
  -- real - a fresh dev database seeds no api_keys rows.
  server = {
    address = "http://lapis:8080",
    -- api_key = "akey_...",
    batch_size = 10,
    monitor_id = "worker-lua",
  },

  -- Site scraper definitions - same shape as
  -- server/plugins/scraper_remote_config_lua's `POST .../site` body
  -- (fields.<price|discount|available>.{selector,transform,validate}).
  -- Only used by the standalone worker; the embedded worker reads
  -- scraper_remote_sites from the database directly instead (it's already
  -- in-process there, see server/workers/scrape_pending_worker.lua).
  sites = {
    -- {
    --   name = "example-site",
    --   urls_match = { "^https?://example%.com/" },
    --   fields = {
    --     price = { selector = { ".price" } },
    --     discount = { selector = { ".discount" } },
    --     available = { selector = { ".availability" } },
    --   },
    -- },
  },

  -- Opt-in (default off): self-report a secret-scrubbed copy of this
  -- config in every heartbeat (see shared/worker_config_report.lua).
  report_config = false,
}
