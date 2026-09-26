-- Shared "analyzer" role, SQL-backed: given an ingested observation,
-- evaluates every enabled rule against it and creates the resulting alert(s).
-- Used only by the embedded worker (server/workers/observe_pending_worker.lua:
-- directly after ingesting its own observation, and from its "analyzer"-role ticks
-- via plugins/entities/services/reanalyze.lua); POST /api/observations never
-- runs it (an API route never evaluates rules - see that handler's header).
-- It's constructed directly there rather than through a plugin-composed
-- context, which doesn't exist at nginx-worker boot.
--
-- The matching orchestration itself (match context, alert derivation,
-- duplicate/cooldown suppression) is watchtower_worker_core.rule_matching,
-- shared with the standalone worker's HTTP-backed
-- watchtower_worker_core.worker_rule_matcher; this module supplies only the
-- Postgres I/O behind it. The standalone worker is deliberately NOT wired to
-- use this: it's a plain Lua + socket.http client with no database driver at
-- all, by design. This module's dependency-injected constructor (plain
-- rule_engine/alert_manager objects, not a `require("plugins...")` baked in
-- here) is what keeps it independent of anything server-plugin-specific.
--
-- `lapis.db` itself (not a server-plugin require) is an exception to that -
-- used below for the existence/baseline queries, safe because this module
-- only ever runs in the server/embedded-worker Lua runtime (both have
-- Postgres access via lapis.db already).
local db = require("lapis.db")
local cjson_safe = require("cjson.safe")
local rule_matching = require("watchtower_worker_core.rule_matching")

local M = {}

-- True if this exact (rule_id, observation_id) pair already has an alert -
-- e.g. from a prior "analyzer"-role pass re-analyzing the same still-latest
-- observation (see services/reanalyze.lua) before a newer one arrives.
local function already_alerted(rule_id, observation_id)
  local rows = db.query("SELECT 1 FROM alerts WHERE rule_id = ? AND observation_id = ? LIMIT 1", rule_id, observation_id)
  return rows ~= nil and #rows > 0
end

-- True if a rule match should be suppressed: a prior alert for the same
-- (rule_id, observable_id) pair already fired within the last
-- `cooldown_seconds`. `cooldown_seconds` nil/0/negative (no cooldown
-- configured on the rule) or a nil `observable_id` (nothing to key the dedup
-- on) always returns false - the alert is created every time. A live query,
-- not a cache, so it stays correct across nginx worker processes and doesn't
-- need invalidating.
local function is_in_cooldown(rule_id, observable_id, cooldown_seconds)
  if not cooldown_seconds or cooldown_seconds <= 0 or not observable_id then
    return false
  end

  local rows = db.query(
    "SELECT 1 FROM alerts a JOIN observations o ON o.id = a.observation_id "
      .. "WHERE a.rule_id = ? AND o.observable_id = ? "
      .. "AND a.created_at >= NOW() - (? * INTERVAL '1 second') LIMIT 1",
    rule_id,
    observable_id,
    cooldown_seconds
  )

  return rows ~= nil and #rows > 0
end

-- Fetches the decoded `properties` of the most recent observation for
-- `observable_id` recorded at or before `reference_timestamp` minus `seconds`
-- - the "changed"/"changed_within" operators' baseline (see
-- shared/rule_engine/expr.lua). `seconds = 0` finds the immediately preceding
-- observation (as of `reference_timestamp`). A live, uncached, parameterized
-- db.query, casting the jsonb column to text (this codebase's established
-- convention for raw db.query against jsonb). Returns nil if there's no
-- qualifying row.
--
-- `exclude_id` (optional) excludes one observation row by id from the
-- search - the observation currently being analyzed. This matters
-- specifically for `seconds = 0`: by the time analysis runs, that
-- observation is already committed with `timestamp = reference_timestamp`,
-- so a plain `timestamp <= reference_timestamp` would otherwise match the
-- row itself (never a true "immediately preceding" observation) rather than
-- a genuinely earlier one. Omitted by callers with no such row to exclude
-- (e.g. POST /api/rules/test-expression's synthetic, unsaved context).
function M.fetch_baseline(observable_id, reference_timestamp, seconds, exclude_id)
  local sql = "SELECT properties::text AS properties FROM observations "
    .. "WHERE observable_id = ? AND timestamp <= (?::timestamp - (? * INTERVAL '1 second'))"
  local params = { observable_id, reference_timestamp, seconds }
  if exclude_id then
    sql = sql .. " AND id != ?"
    table.insert(params, exclude_id)
  end
  local rows = db.query(sql .. " ORDER BY timestamp DESC LIMIT 1", (table.unpack or unpack)(params))
  local row = rows and rows[1]
  return row and cjson_safe.decode(row.properties) or nil
end

-- rule_engine: anything with :match(context) -> matches
--   (plugins/rules/services/rule_engine.lua's shape).
-- alert_manager: anything with :create(fields)
--   (lib/resource_manager.lua-shaped, or a raw Lapis Model - both expose
--   a plain :create(fields) method).
-- log_error: optional function(message) - called with an already-formatted
--   string on a rule-matching or alert-creation failure. Left generic
--   (not core.logger-shaped) so this module doesn't need to know which
--   logging convention its caller uses; pass nil to log nothing.
function M.new(rule_engine, alert_manager, log_error)
  local matcher = rule_matching.new({
    match = function(context) return rule_engine:match(context) end,
    fetch_baseline = M.fetch_baseline,
    has_alert_for_observation = already_alerted,
    has_recent_alert = is_in_cooldown,
    -- A unique-constraint violation from alerts_rule_id_observation_id_idx
    -- (config/dataset/init.sql) - the DB-level backstop for the same
    -- invariant already_alerted checks, in case of a race between two
    -- concurrent analyzer passes - is a silent suppression, not a failure.
    create_alert = function(fields)
      local ok, err = pcall(function() return alert_manager:create(fields) end)
      if ok or tostring(err):find("alerts_rule_id_observation_id_idx", 1, true) then
        return true
      end
      return false, err
    end,
    log_error = log_error,
  })
  return setmetatable({ _matcher = matcher }, { __index = M })
end

-- Analyzes `observation` ({id, source, payload, observable_id, worker,
-- observable_type, timestamp} - see rule_matching.build_context): matches it
-- against every enabled rule and creates one alert per match. An observation
-- matching zero rules creates no alert at all. Returns (matches, ok) - see
-- rule_matching:analyze.
function M:analyze(observation)
  return self._matcher:analyze(observation)
end

return M
