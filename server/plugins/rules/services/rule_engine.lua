-- Thin, DB-backed wrapper around the generic rule_engine.engine (see
-- shared/rule_engine/README.md) - this module owns only what's specific to
-- watchtower-server's own `rules` table: which rows to load (enabled, id asc),
-- which field/operator vocabulary a rule's `if` may reference
-- (allowed_fields.lua), and how a matched row projects into the
-- {id, severity, tags, cooldown_seconds} shape shared/analyzer.lua expects.
local engine_lib = require("rule_engine.engine")
local rule_expr = require("rule_engine.expr")
local allowed_fields = require("rule_engine.allowed_fields")
local Logger = require("core.logger")

local logger = Logger:new("ERROR", function(level, message)
  return string.format("[%s] %s", level, message)
end)

local M = {}

-- Builds a rule_engine.engine instance that loads every enabled rule
-- (ordered by id asc) from `rule_model` and pre-parses each one's `if`
-- expression into an AST once, instead of on every match call. An
-- unparseable rule is logged and skipped, same as before this file
-- delegated to rule_engine.engine.
function M.new(rule_model)
  local engine = engine_lib.new({
    load = function()
      return rule_model:select("where enabled = ? order by id asc", true)
    end,
    allowed_fields = allowed_fields,
    on_parse_error = function(item, err)
      logger:error("Rule has an unparseable condition, skipping: rule_id={rule_id} error={error}", {
        rule_id = item.id,
        error = err,
      })
    end,
  })

  local instance = { _engine = engine }
  return setmetatable(instance, { __index = M })
end

-- Drops the cached rule/AST list so the next match() reloads and re-parses
-- from the database. Callers that mutate rules (create/update/delete) must
-- call this - see rules.lua's `on_change` config.
function M:invalidate()
  self._engine:invalidate()
end

-- Finds every enabled rule (ordered by id asc) whose `if` expression
-- matches `context`, and returns an array of
-- `{id, severity, tags, cooldown_seconds}` - one entry per matching
-- rule, in id order. `severity`/`tags` are nil on an entry when that rule
-- didn't declare them (the caller falls back to its own defaults in that
-- case); `cooldown_seconds` is nil when the rule has no cooldown configured
-- (see shared/analyzer.lua, which uses it to suppress repeat alerts for the
-- same rule+item). Returns an empty array if no enabled rule matches. The
-- rule list and parsed ASTs are cached across calls (see rule_engine.engine)
-- rather than re-queried and re-parsed on every observation.
function M:match(context)
  local matched_rules = self._engine:match(context)

  local matches = {}
  for _, rule in ipairs(matched_rules) do
    table.insert(matches, {
      id = rule.id,
      severity = rule.severity,
      tags = rule.tags,
      cooldown_seconds = rule.cooldown_seconds,
    })
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
