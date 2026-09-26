-- The rule-matching orchestration both "analyzer" implementations share, so
-- they can't drift apart: shared/analyzer.lua (SQL-backed: the embedded
-- worker, direct Postgres) and watchtower_worker_core.worker_rule_matcher
-- (HTTP-backed: the standalone worker, which has no database). Each supplies
-- only its own I/O as `deps`; everything that decides anything lives here -
-- how an observation becomes a match context, how a matched rule becomes an
-- alert, and when an alert is silently suppressed. DB-free and
-- dependency-injected, so it runs identically in both runtimes.
--
-- deps:
--   match(context) -> array of matched rules (each {id, severity, tags,
--     cooldown_seconds}); may raise (counted as a failed pass).
--   fetch_baseline(observable_id, reference_timestamp, seconds, exclude_id)
--     -> decoded properties table | nil - backs the "changed"/
--     "changed_within" operators (shared/rule_engine/expr.lua). Optional:
--     without it those operators evaluate to false.
--   has_alert_for_observation(rule_id, observation_id) -> boolean - this
--     exact pair already has an alert; checked unconditionally, independent
--     of cooldown_seconds (re-matching the identical observation against the
--     same rule can never yield a legitimately distinct alert).
--   has_recent_alert(rule_id, observable_id, cooldown_seconds) -> boolean -
--     the cooldown check; the dep decides that nil/<=0 cooldown_seconds means
--     false. Both existence checks are expected to RAISE on failure rather
--     than answer false: "couldn't check" read as "not alerted yet" would
--     flood duplicates.
--   create_alert(fields) -> ok, err - fields = {observation_id, severity,
--     tags, rule_id}. A silent suppression by the store itself (e.g. a
--     unique-constraint race between two concurrent passes) is the dep's to
--     turn into `true`.
--   log_error(message) - optional; left generic (a plain function, not
--     core.logger-shaped) so this module needn't know its caller's logging
--     convention.
local M = {}

-- Wraps fn(seconds) so each distinct `seconds` value is fetched once for the
-- life of the returned closure: a single match's "changed"/"changed_within"
-- comparisons against the same window only ever query once. A nil result is
-- memoized too (as false internally).
local function memoize_by_seconds(fn)
  local cache = {}
  return function(seconds)
    if cache[seconds] == nil then
      cache[seconds] = fn(seconds) or false
    end
    return cache[seconds] ~= false and cache[seconds] or nil
  end
end

-- Builds the rule-matching context for `observation`: universal observation
-- metadata (source/observable_id/worker/observable_type) plus `payload` - no
-- observable-type-SPECIFIC field (e.g. "product"'s price/discount/
-- available/url) is ever lifted onto the context, so the rule vocabulary
-- stays generic across observable types (see
-- shared/rule_engine/allowed_fields.lua); those remain reachable only via
-- payload.<name>. `payload` must be the JSON-encoded STRING form:
-- shared/rule_engine/expr.lua decodes it itself (cached per context), so
-- passing an already-decoded table would break `payload.<path>`.
-- `observable_type` is the type's own `name` (not its schema), letting a rule
-- target one observable type without knowing its payload field names;
-- `source` is the observation's Observable's name, synthesized by the caller
-- since it isn't a real column on `observations`.
--
-- Also attaches `_fetch_baseline` (memoized, see above) when the observation
-- carries both `observable_id` and `timestamp` (and `fetch_baseline` is
-- given) - this is what powers `payload`/`payload.<path>`'s `changed`/
-- `changed_within` operators; omitted otherwise, in which case those
-- operators deterministically evaluate to `false`. `observation.id`, when
-- present, is excluded from the baseline lookup (the observation currently
-- being analyzed must not match itself as its own predecessor).
--
-- observation: {id?, source, payload, observable_id, worker, observable_type,
--   timestamp?}
function M.build_context(observation, fetch_baseline)
  local context = {
    source = observation.source,
    payload = observation.payload,
    observable_id = observation.observable_id,
    worker = observation.worker,
    observable_type = observation.observable_type,
  }
  if fetch_baseline and observation.observable_id and observation.timestamp then
    context._fetch_baseline = memoize_by_seconds(function(seconds)
      return fetch_baseline(observation.observable_id, observation.timestamp, seconds, observation.id)
    end)
  end
  return context
end

-- The alert fields for `observation`, from the rule match that fired it. A
-- matched rule's severity/tags apply; severity falls back to "low" only if
-- the rule itself declares none.
function M.derive_alert_fields(observation, match)
  return {
    observation_id = observation.id,
    severity = match.severity or "low",
    tags = match.tags,
    rule_id = match.id,
  }
end

function M.new(deps)
  return setmetatable({ _deps = deps }, { __index = M })
end

function M:_log(message)
  if self._deps.log_error then
    self._deps.log_error(message)
  end
end

-- Creates one alert for `observation`/`match`, unless this exact (rule,
-- observation) pair already has one, or `match` has a `cooldown_seconds` and
-- a prior alert for the same rule+observable already fired within that window
-- - both deliberate, silent suppressions (not a failure): the first avoids a
-- literal duplicate when the "analyzer" role re-runs against an unchanged
-- observation, the second avoids re-alerting on every NEW observation while a
-- condition stays true. Returns true/false so a multi-match batch's failures
-- don't stop the rest.
function M:_create_alert(observation, match)
  if self._deps.has_alert_for_observation(match.id, observation.id) then
    return true
  end

  if self._deps.has_recent_alert(match.id, observation.observable_id, match.cooldown_seconds) then
    return true
  end

  local ok, err = self._deps.create_alert(M.derive_alert_fields(observation, match))
  if not ok then
    self:_log("Failed to create alert for observation: " .. tostring(err))
    return false
  end
  return true
end

-- Analyzes `observation`: matches it against every enabled rule and creates
-- one alert per match; an observation matching zero rules creates none.
-- Returns (matches, ok) - `matches` is the raw array of matched rules (empty
-- on a matching failure, so a caller can still count/report on it), `ok` is
-- false if rule matching itself failed or any alert failed to create.
function M:analyze(observation)
  local ok_match, matches = pcall(self._deps.match, M.build_context(observation, self._deps.fetch_baseline))
  if not ok_match then
    self:_log("Rule matching failed: " .. tostring(matches))
    return {}, false
  end

  local any_failed = false
  for _, match in ipairs(matches) do
    if not self:_create_alert(observation, match) then
      any_failed = true
    end
  end

  return matches, not any_failed
end

return M
