-- Re-runs rule matching against an Observable's already-stored latest observation
-- (no re-observe) - the server-side work a scheduler task of type='analyze'
-- triggers per Observable (see
-- shared/watchtower_worker_core/pollers/analyze.lua). A plain function,
-- not a class - dependency-injected on `analyzer` (shared/analyzer.lua,
-- already constructed by whichever caller owns it) so this module needs no
-- `require("plugins...")` of its own. Called only by
-- server/workers/observe_pending_worker.lua's analyze ticks, directly
-- in-process (no self-HTTP-call), reusing the analyzer instance
-- ingest_observation already owns. The standalone worker has no direct DB
-- access, so it runs the same matching client-side instead
-- (shared/watchtower_worker_core/worker_rule_matcher.lua).
local M = {}

-- observable_type: the Observable's resolved observable_types row (or nil),
-- already looked up by the caller (same `observable, observable_type, ...`
-- convention as server/workers/observe_pending_worker.lua's
-- ingest_observation) - only its `name` is used, to populate the
-- observable_type field in the rule-matching context (see
-- shared/analyzer.lua's build_match_context).
-- observations_model: anything with :select(query, ...) -> rows (a plain
-- Lapis Model works, e.g. models.Observations).
-- analyzer: shared/analyzer.lua instance (:analyze(observation) -> matches, ok).
-- Returns {matches, ok} - `matches` is the count of rules that matched
-- (0 when there's no observation yet, or nothing matched); `ok` is false if
-- rule matching itself failed or any alert failed to create (a
-- cooldown-suppressed match is not a failure - see shared/analyzer.lua's
-- M:_create_alert).
function M.analyze_observable(observable, observable_type, observations_model, analyzer)
  -- observations has no created_at column - `timestamp` is the column that
  -- records when the observation was taken (see config/dataset/init.sql).
  local latest = observations_model:select(
    "where observable_id = ? order by timestamp desc limit 1", observable.id
  )[1]

  if not latest then
    return { matches = 0, ok = true }
  end

  local cjson_safe = require("cjson.safe")
  local jsonb_query = require("lib.jsonb_query")
  local matches, ok = analyzer:analyze({
    id = latest.id,
    source = observable.name,
    payload = cjson_safe.encode(jsonb_query.decode(latest.properties)),
    observable_id = observable.id,
    worker = latest.worker,
    observable_type = observable_type and observable_type.name,
    timestamp = latest.timestamp,
  })

  return { matches = #matches, ok = ok }
end

return M
