-- Generic "match a context object against a compiled list of rule-like
-- definitions" engine core - the third piece of the `rule_engine` LuaRocks
-- package (see shared/rule_engine/README.md), alongside rule_engine.expr
-- (the boolean-expression grammar) and rule_engine.source (the flat
-- rule-document format). This module knows nothing about rows, rules,
-- alerts, Postgres, or any other backing store - it only knows how to
-- compile+cache a list of "items" (plain tables, each with an id and a
-- field holding a raw boolean-expression string) into ASTs and evaluate a
-- context against them, returning whichever of those items matched.
--
-- watchtower-server uses one instance of this per condition-matching
-- concern it has - its own rule engine (server/plugins/rules/services/
-- rule_engine.lua, matching an observation's context against `rules` rows)
-- and its notification-policy engine (server/plugins/notification_channels/
-- services/notification_policy_engine.lua, matching an alert's context
-- against `notification_policies` rows) - each supplying its own `load`
-- function (a DB query for its own enabled rows), `allowed_fields`
-- vocabulary, and id/severity/etc. projection on top of the plain items
-- this module hands back. Any other Lua project with its own backing store
-- (not necessarily Postgres, not necessarily even a database) can reuse
-- this the same way by supplying its own `load`.
local expr = require("rule_engine.expr")

local M = {}
local Engine = {}
Engine.__index = Engine

local function noop() end

-- M.new(opts) -> engine instance
--
-- opts:
--   load           - function() -> array of "item" tables to compile, e.g.
--                     a DB query for every currently-enabled row. Called
--                     once per cache generation (see :invalidate()) -
--                     required.
--   condition_field - name of the field on each item holding its raw
--                     boolean-expression string (default
--                     "condition_expression").
--   allowed_fields  - passed straight through to rule_engine.expr.parse -
--                     the caller-supplied field/operator vocabulary an
--                     item's condition may reference.
--   on_parse_error  - function(item, err), called (and that item then
--                     skipped, never raising) when an item's condition
--                     fails to parse. Defaults to a no-op; pass a
--                     logger-backed function to log-and-skip.
function M.new(opts)
  opts = opts or {}
  assert(type(opts.load) == "function", "rule_engine.engine: opts.load is required")
  local instance = {
    load = opts.load,
    condition_field = opts.condition_field or "condition_expression",
    allowed_fields = opts.allowed_fields,
    on_parse_error = opts.on_parse_error or noop,
  }
  return setmetatable(instance, Engine)
end

-- Drops the cached compiled item/AST list so the next :match() call
-- reloads (via opts.load) and re-parses every item from scratch. Callers
-- whose backing store can change (create/update/delete) must call this on
-- every mutation - this module has no way to know that on its own.
function Engine:invalidate()
  self._cache = nil
end

function Engine:_compile()
  local items = self.load()
  local compiled = {}
  for _, item in ipairs(items) do
    local ast, err = expr.parse(item[self.condition_field], self.allowed_fields)
    if not ast then
      self.on_parse_error(item, err)
    else
      table.insert(compiled, { item = item, ast = ast })
    end
  end
  return compiled
end

-- Returns every item (in opts.load's own order) whose condition matches
-- `context`. `filter`, if given, is `function(item) -> boolean` and is
-- checked before evaluating that item's AST (cheaper than evaluating an
-- expression only to discard the result) - e.g. a caller restricting the
-- match to a specific id subset. Reuses the compiled AST cache across
-- calls - see :invalidate().
function Engine:match(context, filter)
  if not self._cache then
    self._cache = self:_compile()
  end

  local matches = {}
  for _, entry in ipairs(self._cache) do
    if (not filter or filter(entry.item)) and expr.evaluate(entry.ast, context) then
      table.insert(matches, entry.item)
    end
  end
  return matches
end

M.Engine = Engine
return M
