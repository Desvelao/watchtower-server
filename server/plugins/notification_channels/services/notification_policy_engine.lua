-- Previews a notification policy's `if` condition without touching the
-- notification_policies table - POST /api/notification_policies/test, for
-- checking a draft policy before saving it. This is the only place the
-- server itself ever evaluates a policy condition, and only as a
-- side-effect-free dry run on a caller-supplied context: real matching
-- (which alerts go to which channels) happens worker-side, in
-- shared/watchtower_worker_core/notification_policy_matcher.lua, against
-- the identical rule_engine.notification_policy_allowed_fields vocabulary,
-- so a policy previews here exactly as it will match there.
local rule_expr = require("rule_engine.expr")
local allowed_fields = require("rule_engine.notification_policy_allowed_fields")

local M = {}

-- Tests a single ad-hoc `if_expr` against `context` (an alert's own fields -
-- see notification_policy_allowed_fields.lua). Returns (matched, nil) or
-- (nil, parse_err). Mirrors plugins/rules/services/rule_engine.lua's
-- M.test_expression.
function M.test_expression(if_expr, context)
  local ast, err = rule_expr.parse(if_expr, allowed_fields)
  if not ast then
    return nil, err
  end
  return rule_expr.evaluate(ast, context), nil
end

return M
