-- The grammar shared/rule_engine/expr.lua's condition language (`if:`) is
-- allowed to reference for a notification policy's `if` - see
-- server/plugins/notification_channels/services/notification_policy_engine.lua
-- (server-side) and shared/watchtower_worker_core/notification_policy_matcher.lua
-- (the standalone worker's own client-side matcher - lives under shared/,
-- not server/plugins/, precisely so this vocabulary is reachable from both).
-- A policy matches against an ALERT (not an observation - contrast
-- shared/rule_engine/allowed_fields.lua, which matches observations), so
-- the vocabulary is alerts' own columns: `severity`, `tags`, `rule_id` (the
-- alert's own fields) plus `observable_id`, which isn't a real column on
-- `alerts` - it's joined in from `observations` via `alerts.observation_id`
-- when building the match context (see
-- shared/watchtower_worker_core/notification_policy_matcher.lua's
-- build_match_context and server/lib/alert_queries.lua), the same way plugins/rules' own `source`/`observable_id` are synthesized
-- rather than read off a real column.
return {
  severity = { ["="] = true, ["!="] = true, ["in"] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  tags = { has = true },
  rule_id = { ["="] = true, ["!="] = true, ["in"] = true },
  observable_id = { ["="] = true, ["!="] = true, ["in"] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
}
