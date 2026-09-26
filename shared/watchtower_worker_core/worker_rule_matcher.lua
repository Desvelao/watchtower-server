-- Worker-side counterpart to shared/analyzer.lua + server/plugins/rules/
-- services/rule_engine.lua, combined: given an observable id, re-runs rule
-- matching against its latest stored observation and creates the resulting
-- alert(s) - but entirely from the standalone worker's own process, over
-- HTTP, instead of server-side with direct Postgres access. Reuses the
-- exact same rule_engine.engine/rule_engine.expr matching core (pure Lua,
-- zero DB dependency - see shared/rule_engine/README.md) and the identical
-- shared/rule_engine/allowed_fields.lua vocabulary the server's own rule
-- engine uses, so a rule that matches server-side matches identically here.
--
-- This exists because the "analyzer" worker role used to be a thin trigger
-- for a server-side analyze route (since removed), which did all of the real
-- work (rule fetch, observation fetch, cooldown check, alert insert)
-- server-side - the worker contributed nothing but the HTTP call. The matching
-- *algorithm* was always pure/portable; only its inputs (current rules,
-- latest observation, recent-alert history) and output (the alert row) are
-- inherently reads/writes against Postgres. Those now happen over the
-- worker's existing HTTP transport (shared/watchtower_worker_core/provider_http.lua) instead
-- of in-process on the server, via a new alerts:create permission (see
-- server/plugins/alerting/plugin.lua's POST /api/alerts, and its own header
-- comment for why this is a narrower write surface than a generic alerts
-- API - it does no matching/cooldown logic of its own, only validation).
--
-- Dependency-injected (deps, below) rather than baking in provider_http
-- directly, so this module stays a plain, testable orchestrator - same
-- shape as shared/analyzer.lua's own M.new(rule_engine, alert_manager, ...).
--
-- deps:
--   load_rules()                                      -> array of rule rows
--     (each with at least id/condition_expression/severity/tags/
--     cooldown_seconds - the exact shape GET /api/rules?enabled=true
--     already returns), or nil/error on failure.
--   fetch_latest_observation(observable_id)            -> observation | nil
--     (observation: {id, timestamp, worker, properties} - see
--     shared/watchtower_worker_core/provider_http.lua's M:latest_observation) or nil if the
--     observable has no stored observation yet.
--   fetch_baseline(observable_id, reference_timestamp, seconds, exclude_id)
--     -> decoded properties table | nil - backs the "changed"/
--     "changed_within" operators (shared/rule_engine/expr.lua), mirroring
--     shared/analyzer.lua's own fetch_baseline_properties.
--   has_alert_for_observation(rule_id, observation_id) -> boolean
--     - true if this exact (rule_id, observation_id) pair already has an
--     alert, checked unconditionally (independent of cooldown_seconds) -
--     mirrors shared/analyzer.lua's own already_alerted check, suppressing a
--     literal duplicate when the "analyzer" role re-runs against a
--     still-latest observation it already analyzed.
--   has_recent_alert(rule_id, observable_id, cooldown_seconds) -> boolean
--     - the cooldown check; deps decide nil/<=0 cooldown_seconds returns
--     false without a request (mirrors shared/analyzer.lua's
--     is_in_cooldown short-circuit).
--   create_alert(fields) -> ok, err - fields = {observation_id, severity,
--     tags, rule_id}, identical shape shared/analyzer.lua's
--     derive_alert_fields already produces.
--   log_error(message) - optional, called on a rule-parse or alert-create
--     failure. Left generic (a plain function, not core.logger-shaped),
--     same convention as shared/analyzer.lua.
local engine_lib = require("rule_engine.engine")
local allowed_fields = require("rule_engine.allowed_fields")
local rule_matching = require("watchtower_worker_core.rule_matching")
local cjson_safe = require("cjson.safe")

local M = {}

function M.new(deps)
  local engine = engine_lib.new({
    load = deps.load_rules,
    allowed_fields = allowed_fields,
    on_parse_error = function(item, err)
      if deps.log_error then
        deps.log_error(
          string.format("Rule has an unparseable condition, skipping: rule_id=%s error=%s", tostring(item.id), tostring(err))
        )
      end
    end,
  })

  -- The orchestration is shared with the SQL-backed shared/analyzer.lua (see
  -- rule_matching.lua); only its I/O differs.
  local matcher = rule_matching.new({
    match = function(context) return engine:match(context) end,
    fetch_baseline = deps.fetch_baseline,
    has_alert_for_observation = deps.has_alert_for_observation,
    has_recent_alert = deps.has_recent_alert,
    create_alert = deps.create_alert,
    log_error = deps.log_error,
  })

  local instance = { _engine = engine, _matcher = matcher, _deps = deps }
  return setmetatable(instance, { __index = M })
end

-- Drops the cached rule/AST list, mirroring rule_engine.lua's own
-- :invalidate() - called periodically by provider_http.lua's
-- M:_get_rule_matcher (this instance is long-lived, reused across many
-- :analyze_observable calls, so without this a rule created/edited/deleted
-- after the first call would never be picked up).
function M:invalidate()
  self._engine:invalidate()
end

function M:_log(message)
  if self._deps.log_error then
    self._deps.log_error(message)
  end
end

-- Re-runs rule matching against observable_id's latest stored observation and
-- creates one alert per match. Returns (matches, ok), same contract as
-- shared/analyzer.lua:M:analyze. No observation yet -> {}, true (mirrors
-- plugins/entities/services/reanalyze.lua's own graceful no-op).
--
-- `meta` = {observable_name, observable_type_name} - resolved by the caller
-- (the worker already fetches the observable/observable_type in its own
-- pipeline; this module doesn't re-fetch them) - populates the match
-- context's source/observable_type fields. Passed per call rather than held
-- on this long-lived instance.
function M:analyze_observable(observable_id, meta)
  local observation, fetch_err = self._deps.fetch_latest_observation(observable_id)
  if fetch_err then
    self:_log("Failed to fetch latest observation: " .. tostring(fetch_err))
    return {}, false
  end
  if not observation then
    return {}, true
  end

  return self._matcher:analyze({
    id = observation.id,
    source = meta.observable_name,
    -- The HTTP response is auto-decoded, so `properties` is already a table -
    -- rule_matching.build_context needs the JSON STRING form (see there).
    payload = cjson_safe.encode(observation.properties),
    observable_id = observable_id,
    worker = observation.worker,
    observable_type = meta.observable_type_name,
    timestamp = observation.timestamp,
  })
end

return M
