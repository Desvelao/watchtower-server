-- Builds the safe-to-report subset of a worker's `config` (as loaded by
-- watchtower_worker_core.runner's build_config) for self-reporting in
-- heartbeats - see watchtower_worker_core.processors' do_heartbeat and
-- observe_pending_worker.lua's send_heartbeat, both gated behind
-- `config.report_config` (opt-in, default off). The caller JSON-encodes the
-- table this returns and sends it as the heartbeat's `config` field.
--
-- Allow-list, not deny-list: only an explicit set of known-safe field
-- names is kept, so anything not recognized - server.api_key above all -
-- is silently dropped rather than leaked.
--
-- Observer field allow-lists are entirely supplied by the observer type
-- itself, via the same optional-instance-method interface
-- observer_registry.lua's own :capabilities() already uses:
-- :reportable_config(observer_config), aggregated across every registered
-- observer by registry:reportable_observers() (falling back to a generic,
-- minimal allow-list for a type that doesn't implement it). This module has
-- no fixed idea of what fields any particular observer type's config
-- carries (e.g. web_scraper's `sites_source`/`url_property`/`sites` are
-- that observer type's own concern) and no self-registration table of its
-- own - apply_registry below just publishes whatever the registry already
-- computed onto `config`.

local SERVER_SAFE_FIELDS = { "base_url", "batch_size" }

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
    interval = config.interval,
    heartbeat_interval = config.heartbeat_interval,
    version = config.version,
    capabilities = config.capabilities,
    worker_id = config.worker_id,
  }

  if config.server then
    report.server = pick(config.server, SERVER_SAFE_FIELDS)
  end

  if config.observers_report then
    report.observers = config.observers_report
  end

  return report
end

-- The JSON-encoded form of build_reportable_config - what the heartbeat's
-- `config` field carries (config.reportable_config_json).
function M.build_reportable_config_json(config)
  return require("cjson.safe").encode(M.build_reportable_config(config))
end

-- Publishes a (re)built observer registry on `config`: its `capabilities`
-- (self-reported in every heartbeat) and, when the opt-in
-- config.report_config is set, each observer's own reportable-config subset
-- (registry:reportable_observers(), see observer_registry.lua) plus the
-- full config dump derived from them - which embeds both, so they must be
-- rebuilt every time the registry is, or a remote-sites refresh leaves the
-- reported config stale. The single place both worker runtimes do this, at
-- startup and on every refresh.
function M.apply_registry(config, registry)
  config.capabilities = registry:capabilities()
  if config.report_config then
    config.observers_report = registry:reportable_observers()
    config.reportable_config_json = M.build_reportable_config_json(config)
  end
end

return M
