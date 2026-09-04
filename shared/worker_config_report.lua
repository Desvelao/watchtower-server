-- Builds the safe-to-report subset of a worker's `config` (as loaded by
-- worker_runner.build_config) for self-reporting in heartbeats - see
-- worker_processors.lua's maybe_heartbeat and scrape_pending_worker.lua's
-- send_heartbeat, both gated behind `config.report_config` (opt-in,
-- default off). The caller JSON-encodes the table this returns and sends
-- it as the heartbeat's `config` field.
--
-- Allow-list, not deny-list: only an explicit set of known-safe field
-- names is kept, so anything not recognized - server.api_key above all -
-- is silently dropped rather than leaked.

local SERVER_SAFE_FIELDS = { "base_url", "batch_size", "monitor_id", "version" }
local SITE_SAFE_FIELDS = { "name", "urls_match", "fields", "urls_test" }

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

local M = {}

function M.build_reportable_config(config)
  config = config or {}

  local report = {
    poll_interval = config.poll_interval,
    heartbeat_interval = config.heartbeat_interval,
    item_filter = config.item_filter,
    version = config.version,
    capabilities = config.capabilities,
  }

  if config.server then
    report.server = pick(config.server, SERVER_SAFE_FIELDS)
  end

  if config.sites then
    local sites = {}
    for _, site in ipairs(config.sites) do
      table.insert(sites, pick(site, SITE_SAFE_FIELDS))
    end
    report.sites = sites
  end

  return report
end

return M
