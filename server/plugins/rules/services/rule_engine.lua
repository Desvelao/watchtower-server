local rule_expr = require("rule_expr")
local allowed_fields = require("plugins.rules.allowed_fields")
local Logger = require("core.logger")

local logger = Logger:new("ERROR", function(level, message)
  return string.format("[%s] %s", level, message)
end)

local M = {}

function M.new(rule_model)
  local instance = {
    _model = rule_model,
  }
  return setmetatable(instance, { __index = M })
end

-- Loads every enabled rule (ordered by id asc) and pre-parses each one's
-- `if` expression into an AST once, instead of on every match call. An
-- unparseable rule is logged and skipped, same as before.
function M:_load_rules()
  local rules =
    self._model:select("where enabled = ? order by id asc", true)

  local compiled = {}
  for _, rule in ipairs(rules) do
    local ast, parse_err = rule_expr.parse(rule.condition_expression, allowed_fields)
    if not ast then
      logger:error("Rule has an unparseable condition, skipping: rule_id={rule_id} error={error}", {
        rule_id = rule.id,
        error = parse_err,
      })
    else
      table.insert(compiled, { rule = rule, ast = ast })
    end
  end

  return compiled
end

-- Drops the cached rule/AST list so the next match() reloads and re-parses
-- from the database. Callers that mutate rules (create/update/delete) must
-- call this - see rules.lua's `on_change` config.
function M:invalidate()
  self._cache = nil
end

-- Finds every enabled rule (ordered by id asc) whose `if` expression
-- matches `context`, and returns an array of `{id, action, severity, tags}`
-- - one entry per matching rule, in id order. `severity`/`tags` are nil on
-- an entry when that rule didn't declare them (the caller falls back to
-- the event's own values in that case). Returns an empty array if no
-- enabled rule matches. The rule list and parsed ASTs are cached across
-- calls (see _load_rules/invalidate) rather than re-queried and re-parsed
-- on every event.
function M:match(context)
  if not self._cache then
    self._cache = self:_load_rules()
  end

  local matches = {}
  for _, entry in ipairs(self._cache) do
    if rule_expr.evaluate(entry.ast, context) then
      local rule = entry.rule
      table.insert(matches, {
        id = rule.id,
        action = rule.action,
        severity = rule.severity,
        tags = rule.tags,
      })
    end
  end

  return matches
end

-- Tests a single ad-hoc `if_expr` against `context`, without touching the
-- rules table at all - for previewing a draft rule's condition before
-- saving it (see POST /api/rules/test-expression). A plain module-level
-- function, not an instance method - it needs no DB model. Returns
-- (matched: boolean, err: nil) on success, or (nil, err) if `if_expr`
-- fails to parse.
function M.test_expression(if_expr, context)
  local ast, err = rule_expr.parse(if_expr, allowed_fields)
  if not ast then
    return nil, err
  end
  return rule_expr.evaluate(ast, context), nil
end

return M
