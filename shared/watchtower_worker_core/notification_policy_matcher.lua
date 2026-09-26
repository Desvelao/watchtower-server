-- The "evaluator" role's matching: decides which
-- candidate alerts go to which notification channels, and enqueues the
-- resulting pending (alert, channel) deliveries. Runs entirely worker-side
-- in BOTH runtimes - in-process for the embedded worker (direct model/SQL
-- deps, no HTTP), over HTTP for the standalone worker (narrow,
-- non-evaluating endpoints) - because an API route must never itself
-- evaluate/decide anything: only a worker's own code may run matching/
-- business logic. The server only ever exposes reads/writes to this module:
-- the enabled policies (GET /api/notification_policies?enabled=true), the
-- candidate alerts (GET /api/alerts?needs_delivery=true, a plain data
-- filter), and a validate-only enqueue (POST /api/alert_deliveries, which
-- mirrors POST /api/alerts's precedent for worker_rule_matcher.lua).
--
-- Reuses the exact same rule_engine.engine/rule_engine.expr matching core
-- (pure Lua, zero DB dependency) and the identical
-- rule_engine.notification_policy_allowed_fields.lua vocabulary the
-- server's dry-run preview (POST /api/notification_policies/test) uses, so
-- a policy matches identically wherever it's evaluated.
--
-- Dependency-injected (deps, below) rather than baking in a transport, same
-- shape as worker_rule_matcher.lua's own M.new(deps).
--
-- deps:
--   load_policies() -> array of enabled policy rows (each with at least
--     id/condition_expression/channel_ids - the shape GET
--     /api/notification_policies?enabled=true returns), or nil/error on
--     failure.
--   new_candidate_alerts_pager() -> generator - a FRESH keyset pager over the
--     alerts that still need a delivery, called once per pass so a pass
--     never resumes from a previous (possibly failed) one. Each generator
--     call returns the next page (an array of alerts, each with at least
--     id/severity/tags/rule_id/observable_id), or nil with no err once
--     exhausted, or nil + err on a failed fetch. Keyset (not offset)
--     because enqueuing removes alerts from the candidate set while it is
--     being paged.
--   enqueue_delivery(alert_id, channel_id) -> enqueued, err - `enqueued` is
--     true if a row was inserted/reset for retry, false if an existing
--     non-error row was left untouched (already pending/triggering/sent),
--     nil + err on failure.
--   log_error(message) - optional, called with an already-formatted string
--     on a policy-parse, matching, or enqueue failure.
local engine_lib = require("rule_engine.engine")
local allowed_fields = require("rule_engine.notification_policy_allowed_fields")

local M = {}

-- The matching context for an alert: the fields
-- rule_engine.notification_policy_allowed_fields lets a policy reference.
-- `alert` needs severity/tags/rule_id plus observable_id (which alerts has
-- no column for - the candidate query joins it in via the observation).
-- Also what the server's dry-run preview builds from a request body, so the
-- vocabulary -> context mapping lives in exactly one place.
function M.build_match_context(alert)
  return {
    severity = alert.severity,
    tags = alert.tags,
    rule_id = alert.rule_id,
    observable_id = alert.observable_id,
  }
end

function M.new(deps)
  local engine = engine_lib.new({
    load = deps.load_policies,
    allowed_fields = allowed_fields,
    on_parse_error = function(item, err)
      if deps.log_error then
        deps.log_error(
          string.format("Notification policy has an unparseable condition, skipping: policy_id=%s error=%s", tostring(item.id), tostring(err))
        )
      end
    end,
  })

  local instance = { _engine = engine, _deps = deps }
  return setmetatable(instance, { __index = M })
end

function M:_log(message)
  if self._deps.log_error then
    self._deps.log_error(message)
  end
end

-- Turns a scheduler task's `notify_policy_ids` scope into a policy filter
-- for the engine: nil/empty means every enabled policy.
local function scope_filter(policy_ids)
  if not policy_ids or #policy_ids == 0 then
    return nil
  end
  local allowed = {}
  for _, id in ipairs(policy_ids) do
    allowed[tonumber(id)] = true
  end
  return function(policy)
    return allowed[policy.id] == true
  end
end

-- One full pass: drains every candidate-alert page
-- (a fresh deps.new_candidate_alerts_pager()), matches each alert against the enabled
-- policies (only those in `policy_ids`, if given - a notify task's scope;
-- nil/empty = all), and enqueues one pending delivery per matched (alert,
-- channel) pair via deps.enqueue_delivery. An alert matching no policy has
-- no side effect (same "no match, no side effect" semantics as rules/
-- observations).
--
-- The enabled-policy list is re-read on every pass (never trusted from an
-- earlier one): this instance is long-lived, and a policy created/edited/
-- deleted after its first load must not go unnoticed. That costs at most one
-- policies read per pass - and none at all when there are no candidate
-- alerts, since the engine only loads on its first match.
--
-- Returns (outcome, ok): outcome is {enqueued, alerts_matched} - `enqueued`
-- counts (alert, channel) pairs actually inserted or reset from 'error', not
-- already-queued/already-sent no-ops; `ok` is false if fetching any page or
-- any enqueue failed (or matching itself failed, which aborts the pass), so a
-- caller can still report the partial outcome it did accomplish.
function M:evaluate_and_enqueue(policy_ids)
  local filter = scope_filter(policy_ids)
  local enqueued, alerts_matched = 0, 0
  local any_failed = false

  self._engine:invalidate()
  local next_page = self._deps.new_candidate_alerts_pager()

  while true do
    local alerts, err = next_page()
    if not alerts then
      if err then
        self:_log("Failed to fetch candidate alerts: " .. tostring(err))
        any_failed = true
      end
      break
    end

    for _, alert in ipairs(alerts) do
      local ok_match, matches = pcall(function()
        return self._engine:match(M.build_match_context(alert), filter)
      end)

      if not ok_match then
        -- Almost always the policy list failing to load (the engine retries
        -- that on every match), so stop here rather than hammering the
        -- source once per remaining alert; the next pass starts fresh.
        self:_log("Policy matching failed, aborting this pass: " .. tostring(matches))
        return { enqueued = enqueued, alerts_matched = alerts_matched }, false
      end

      local matched_any = false
      for _, policy in ipairs(matches) do
        for _, channel_id in ipairs(policy.channel_ids or {}) do
          matched_any = true
          local inserted, enqueue_err = self._deps.enqueue_delivery(alert.id, channel_id)
          if inserted then
            enqueued = enqueued + 1
          elseif inserted == nil then
            self:_log("Failed to enqueue delivery: " .. tostring(enqueue_err))
            any_failed = true
          end
        end
      end

      if matched_any then
        alerts_matched = alerts_matched + 1
      end
    end
  end

  return { enqueued = enqueued, alerts_matched = alerts_matched }, not any_failed
end

return M
