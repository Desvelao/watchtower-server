-- Boolean expression language shared by the server's Rule `if:` condition
-- (src/server/application/services/rule_engine.lua/rules.lua) and the Lua
-- workers' destination-routing `match` expressions
-- (src/shared/notifications/router.lua), e.g.:
--   tags has "prod" AND source="sensor-1"
--
-- Grammar (precedence low -> high: OR, AND, NOT, comparison/parens):
--   expression := or_expr
--   or_expr    := and_expr ( "OR" and_expr )*
--   and_expr   := unary ( "AND" unary )*
--   unary      := "NOT" unary | primary
--   primary    := "(" expression ")" | "*" | comparison
--   comparison := FIELD operator value
--   operator   := "=" | "!=" | "has" | ">" | "<" | ">=" | "<="
--   value      := "\"...\"" | bareword
--
-- A bare "*" always matches, regardless of context - a catch-all condition,
-- usable anywhere a comparison could appear (needs no field/operator, and
-- is exempt from the allowed_fields check below). Composes normally with
-- the rest of the grammar: `NOT *` is always false, `* AND tags has "prod"`
-- reduces to the tags check, `* OR ...` is always true.
--
-- AND/OR/NOT/has are case-insensitive keywords. Which field names/operators
-- are actually allowed is caller-supplied (see M.parse's `allowed_fields`
-- param) rather than fixed here, since the server's rules only ever see an
-- event's tags/source/payload, while a worker's routes match against a
-- whole alert (tags/source/pattern/priority/payload). Callers that don't
-- pass one get the server's default vocabulary (see
-- DEFAULT_FIELD_OPERATORS below), unchanged.
--
-- `payload` holds an event/alert's raw payload string; `payload.<path>`
-- (e.g. `payload.sensor.value`) reaches into it when it parses as a JSON
-- object, walking dot-separated object keys (no array indexing) - see
-- `lookup_payload_path` below. A payload that isn't JSON, or a path that
-- doesn't resolve, just makes the comparison evaluate to "not found"
-- (empty string / false for `has`), never an error.
--
-- Every value comparison - `tags has`, flat `=`/`!=`/ordinal on
-- `source`/`payload`, and nested `payload.<path>` alike - is
-- case-insensitive on both sides, with no case-sensitive operator or
-- escape hatch. Two values differing only by case (e.g. tags "Prod" and
-- "PROD") are indistinguishable to this grammar.
--
-- `>`/`<`/`>=`/`<=` compare numerically when both sides parse as Lua
-- numbers (`tonumber`), otherwise fall back to the same case-insensitive
-- string comparison as `=`/`!=` - see `compare_ordinal` below. `=`/`!=`
-- themselves are always plain case-insensitive string comparison, never
-- numeric, so this is purely additive - it does not change any existing
-- comparison's behavior. CAVEAT: on the `priority` field (worker routes
-- only - the server's rules never see it), this means `priority>"high"` is
-- a byte-wise STRING comparison, not the application's semantic
-- low<medium<high<critical ranking (that ranking only exists as the DB's
-- generated `priority_value` column, which isn't part of this context) -
-- `"low" > "high"` is true alphabetically, which is almost certainly not
-- what an author means.

local cjson_safe = require("cjson.safe")

local M = {}

local KEYWORDS =
  { ["and"] = "AND", ["or"] = "OR", ["not"] = "NOT", ["has"] = "HAS" }

local ORDINAL_OPS = { [">"] = true, ["<"] = true, [">="] = true, ["<="] = true }

local DEFAULT_FIELD_OPERATORS = {
  tags = { has = true },
  source = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  payload = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  ["payload.*"] = { ["="] = true, ["!="] = true, has = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
}

-- Finds the operator set for `field` in `allowed_fields`, falling back to a
-- "<prefix>.*" wildcard entry (e.g. "payload.*" for a "payload.status"
-- field) when there's no exact match - lets a caller opt a whole family of
-- dynamic sub-fields (nested JSON payload keys) into the grammar without
-- enumerating each one up front.
local function lookup_operators(allowed_fields, field)
  if allowed_fields[field] then
    return allowed_fields[field]
  end
  local prefix = field:match("^([^.]+)%.")
  return prefix and allowed_fields[prefix .. ".*"] or nil
end

-- Per-context cache of the JSON-decoded `payload` field, keyed by the
-- context table itself (weak keys, so it never outlives the context) - lets
-- every "payload.<path>" comparison in a single match()/dispatch() call
-- decode the same payload string only once.
local payload_json_cache = setmetatable({}, { __mode = "k" })

local function decoded_payload(context)
  if payload_json_cache[context] ~= nil then
    local cached = payload_json_cache[context]
    return cached ~= false and cached or nil
  end
  local decoded = type(context.payload) == "string"
      and cjson_safe.decode(context.payload)
    or nil
  payload_json_cache[context] = (type(decoded) == "table") and decoded or false
  return type(decoded) == "table" and decoded or nil
end

-- Walks `path` (dot-separated, e.g. "status" or "sensor.value") through the
-- decoded payload table. Object-key traversal only - no array indexing.
local function lookup_payload_path(context, path)
  local value = decoded_payload(context)
  if value == nil then
    return nil
  end
  for segment in path:gmatch("[^.]+") do
    if type(value) ~= "table" then
      return nil
    end
    value = value[segment]
  end
  return value
end

-- `>`/`<`/`>=`/`<=`: numeric comparison when both sides parse as Lua
-- numbers, otherwise the same case-insensitive string comparison `=`/`!=`
-- use - see the header comment's caveat about `priority` above.
local function compare_ordinal(op, ctx_raw, target_raw)
  local ctx_num, target_num = tonumber(ctx_raw), tonumber(target_raw)
  local a, b
  if ctx_num ~= nil and target_num ~= nil then
    a, b = ctx_num, target_num
  else
    a, b = tostring(ctx_raw):lower(), tostring(target_raw):lower()
  end
  if op == ">" then
    return a > b
  elseif op == "<" then
    return a < b
  elseif op == ">=" then
    return a >= b
  else
    return a <= b
  end
end

--------------------------------------------------------------------------
-- Tokenizer
--------------------------------------------------------------------------

local function tokenize(expr)
  local tokens = {}
  local i = 1
  local len = #expr

  while i <= len do
    local c = expr:sub(i, i)

    if c:match("%s") then
      i = i + 1
    elseif c == "(" then
      table.insert(tokens, { type = "lparen", pos = i })
      i = i + 1
    elseif c == ")" then
      table.insert(tokens, { type = "rparen", pos = i })
      i = i + 1
    elseif c == '"' then
      local start = i
      local buf = {}
      i = i + 1
      local closed = false
      while i <= len do
        local ch = expr:sub(i, i)
        if ch == "\\" and i < len then
          local nextch = expr:sub(i + 1, i + 1)
          if nextch == '"' or nextch == "\\" then
            table.insert(buf, nextch)
            i = i + 2
          else
            table.insert(buf, ch)
            i = i + 1
          end
        elseif ch == '"' then
          closed = true
          i = i + 1
          break
        else
          table.insert(buf, ch)
          i = i + 1
        end
      end
      if not closed then
        return nil, string.format("unterminated string at position %d", start)
      end
      table.insert(
        tokens,
        { type = "value", value = table.concat(buf), pos = start }
      )
    elseif c == "!" and expr:sub(i, i + 1) == "!=" then
      table.insert(tokens, { type = "op", value = "!=", pos = i })
      i = i + 2
    elseif c == ">" and expr:sub(i, i + 1) == ">=" then
      table.insert(tokens, { type = "op", value = ">=", pos = i })
      i = i + 2
    elseif c == "<" and expr:sub(i, i + 1) == "<=" then
      table.insert(tokens, { type = "op", value = "<=", pos = i })
      i = i + 2
    elseif c == ">" then
      table.insert(tokens, { type = "op", value = ">", pos = i })
      i = i + 1
    elseif c == "<" then
      table.insert(tokens, { type = "op", value = "<", pos = i })
      i = i + 1
    elseif c == "=" then
      table.insert(tokens, { type = "op", value = "=", pos = i })
      i = i + 1
    else
      local start = i
      while i <= len do
        local ch = expr:sub(i, i)
        if
          ch:match("%s")
          or ch == "("
          or ch == ")"
          or ch == '"'
          or ch == "="
          or ch == "!"
          or ch == ">"
          or ch == "<"
        then
          break
        end
        i = i + 1
      end
      if i == start then
        return nil,
          string.format("unexpected character '%s' at position %d", c, start)
      end
      local word = expr:sub(start, i - 1)
      local lower = word:lower()
      if KEYWORDS[lower] then
        table.insert(tokens, { type = KEYWORDS[lower], pos = start })
      else
        table.insert(tokens, { type = "word", value = word, pos = start })
      end
    end
  end

  table.insert(tokens, { type = "eof", pos = len + 1 })
  return tokens, nil
end

--------------------------------------------------------------------------
-- Parser (recursive descent)
--------------------------------------------------------------------------

local function new_parser(tokens)
  local p = { tokens = tokens, idx = 1 }

  function p:peek()
    return self.tokens[self.idx]
  end

  function p:advance()
    local t = self.tokens[self.idx]
    self.idx = self.idx + 1
    return t
  end

  function p:expect(ttype, what)
    local t = self:peek()
    if t.type ~= ttype then
      error(string.format("expected %s at position %d", what or ttype, t.pos))
    end
    return self:advance()
  end

  return p
end

local parse_expression

local function parse_comparison(p)
  local field_tok = p:peek()
  if field_tok.type ~= "word" then
    error(string.format("expected a field name at position %d", field_tok.pos))
  end
  p:advance()

  local op_tok = p:peek()
  if op_tok.type == "op" then
    p:advance()
  elseif op_tok.type == "HAS" then
    p:advance()
    op_tok = { type = "op", value = "has", pos = op_tok.pos }
  else
    error(
      string.format(
        "expected an operator (=, !=, has, >=, <=) at position %d",
        op_tok.pos
      )
    )
  end

  local value_tok = p:peek()
  local value
  if value_tok.type == "value" then
    value = value_tok.value
    p:advance()
  elseif value_tok.type == "word" then
    value = value_tok.value
    p:advance()
  else
    error(string.format("expected a value at position %d", value_tok.pos))
  end

  return {
    type = "cmp",
    field = field_tok.value,
    op = op_tok.value,
    value = value,
    pos = field_tok.pos,
  }
end

local function parse_primary(p)
  local t = p:peek()
  if t.type == "lparen" then
    p:advance()
    local inner = parse_expression(p)
    p:expect("rparen", "')'")
    return inner
  end
  if t.type == "word" and t.value == "*" then
    p:advance()
    return { type = "wildcard", pos = t.pos }
  end
  return parse_comparison(p)
end

local function parse_unary(p)
  if p:peek().type == "NOT" then
    p:advance()
    return { type = "not", expr = parse_unary(p) }
  end
  return parse_primary(p)
end

local function parse_and(p)
  local left = parse_unary(p)
  while p:peek().type == "AND" do
    p:advance()
    local right = parse_unary(p)
    left = { type = "and", left = left, right = right }
  end
  return left
end

parse_expression = function(p)
  local left = parse_and(p)
  while p:peek().type == "OR" do
    p:advance()
    local right = parse_and(p)
    left = { type = "or", left = left, right = right }
  end
  return left
end

--------------------------------------------------------------------------
-- Semantic validation
--------------------------------------------------------------------------

local function validate(ast, allowed_fields)
  if ast.type == "wildcard" then
    return nil
  elseif ast.type == "cmp" then
    local allowed = lookup_operators(allowed_fields, ast.field)
    if not allowed then
      local fields = {}
      for field in pairs(allowed_fields) do
        table.insert(fields, field)
      end
      table.sort(fields)
      return string.format(
        "semantic error at position %d: unknown field '%s' (allowed: %s)",
        ast.pos,
        ast.field,
        table.concat(fields, ", ")
      )
    end
    if not allowed[ast.op] then
      local ops = {}
      for op in pairs(allowed) do
        table.insert(ops, op)
      end
      table.sort(ops)
      return string.format(
        "semantic error at position %d: operator '%s' is not valid for field '%s' (use %s)",
        ast.pos,
        ast.op,
        ast.field,
        table.concat(ops, ", ")
      )
    end
    return nil
  elseif ast.type == "not" then
    return validate(ast.expr, allowed_fields)
  else
    return validate(ast.left, allowed_fields)
      or validate(ast.right, allowed_fields)
  end
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

-- `allowed_fields` (optional): a { [field] = { [operator] = true, ... } }
-- table restricting which fields/operators are semantically valid. A
-- "<prefix>.*" entry (e.g. "payload.*") allows any "<prefix>.<anything>"
-- field, for dynamic sub-fields like nested JSON payload keys - see
-- `lookup_operators`. Defaults to DEFAULT_FIELD_OPERATORS when omitted.
function M.parse(expr_string, allowed_fields)
  allowed_fields = allowed_fields or DEFAULT_FIELD_OPERATORS

  if type(expr_string) ~= "string" or expr_string:match("^%s*$") then
    return nil, "expression is empty"
  end

  local tokens, tok_err = tokenize(expr_string)
  if not tokens then
    return nil, tok_err
  end

  local p = new_parser(tokens)
  local ok, ast_or_err = pcall(function()
    local ast = parse_expression(p)
    local trailing = p:peek()
    if trailing.type ~= "eof" then
      error(string.format("unexpected token at position %d", trailing.pos))
    end
    return ast
  end)

  if not ok then
    return nil, tostring(ast_or_err):gsub("^.-:%d+:%s*", "")
  end

  local sem_err = validate(ast_or_err, allowed_fields)
  if sem_err then
    return nil, sem_err
  end

  return ast_or_err, nil
end

function M.evaluate(ast, context)
  if ast.type == "wildcard" then
    return true
  elseif ast.type == "not" then
    return not M.evaluate(ast.expr, context)
  elseif ast.type == "and" then
    return M.evaluate(ast.left, context) and M.evaluate(ast.right, context)
  elseif ast.type == "or" then
    return M.evaluate(ast.left, context) or M.evaluate(ast.right, context)
  end

  -- comparison node
  if ast.field == "tags" then
    local tags = context.tags
    if type(tags) ~= "table" then
      return false
    end
    local target = ast.value:lower()
    for _, tag in ipairs(tags) do
      if tostring(tag):lower() == target then
        return true
      end
    end
    return false
  elseif ast.field:match("^payload%.") then
    local value = lookup_payload_path(context, ast.field:sub(#"payload." + 1))
    if ast.op == "has" then
      if type(value) ~= "table" then
        return false
      end
      local target = ast.value:lower()
      for _, item in ipairs(value) do
        if tostring(item):lower() == target then
          return true
        end
      end
      return false
    end
    if ORDINAL_OPS[ast.op] then
      return compare_ordinal(ast.op, value == nil and "" or value, ast.value)
    end
    local ctx_value = tostring(value == nil and "" or value):lower()
    local target = ast.value:lower()
    if ast.op == "=" then
      return ctx_value == target
    else
      return ctx_value ~= target
    end
  else
    -- source, payload (raw string), or any other flat field
    if ORDINAL_OPS[ast.op] then
      return compare_ordinal(ast.op, context[ast.field] or "", ast.value)
    end
    local ctx_value = tostring(context[ast.field] or ""):lower()
    local target = ast.value:lower()
    if ast.op == "=" then
      return ctx_value == target
    else
      return ctx_value ~= target
    end
  end
end

return M
