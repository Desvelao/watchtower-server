-- Boolean expression language - the parser+evaluator core of the
-- `rule_engine` LuaRocks package (see shared/rule_engine/README.md). Used
-- directly by watchtower-server's own Rule `if:` condition
-- (server/plugins/rules/) and notification-policy `if:` condition
-- (server/plugins/notification_channels/), and generic enough for any
-- other Lua project's own boolean-match needs (e.g. a worker's
-- destination-routing `match` expressions), e.g.:
--   tags has "prod" AND source="sensor-1"
--
-- Grammar (precedence low -> high: OR, AND, NOT, comparison/parens):
--   expression := or_expr
--   or_expr    := and_expr ( "OR" and_expr )*
--   and_expr   := unary ( "AND" unary )*
--   unary      := "NOT" unary | primary
--   primary    := "(" expression ")" | "*" | comparison
--   comparison := FIELD operator value
--              |  FIELD "changed"
--              |  FIELD "is_set"
--              |  FIELD "in" "(" value ("," value)* ")"
--              |  FIELD ("dropped_pct"|"raised_pct") value "within" duration
--              |  FIELD ("older_than"|"newer_than") duration
--   operator   := "=" | "!=" | "has" | "contains"
--              |  ">" | "<" | ">=" | "<=" | "changed_within"
--   value      := "\"...\"" | bareword
--
-- A bare "*" always matches, regardless of context - a catch-all condition,
-- usable anywhere a comparison could appear (needs no field/operator, and
-- is exempt from the allowed_fields check below). Composes normally with
-- the rest of the grammar: `NOT *` is always false, `* AND tags has "prod"`
-- reduces to the tags check, `* OR ...` is always true.
--
-- AND/OR/NOT/has/contains/in/is_set/changed/changed_within/dropped_pct/
-- raised_pct/within/older_than/newer_than are case-insensitive keywords.
-- Which field names/operators are actually allowed is caller-supplied (see
-- M.parse's `allowed_fields` param) rather than fixed here, since the
-- server's rules only ever see an observation's source/payload, while a
-- worker's routes match against a whole alert
-- (tags/source/pattern/severity/payload). Callers that don't pass one get
-- the server's default vocabulary (see DEFAULT_FIELD_OPERATORS below),
-- unchanged.
--
-- `payload` holds an observation/alert's raw payload string; `payload.<path>`
-- (e.g. `payload.sensor.value`) reaches into it when it parses as a JSON
-- object, walking dot-separated object keys (no array indexing) - see
-- `lookup_payload_path` below. A payload that isn't JSON, or a path that
-- doesn't resolve, just makes the comparison evaluate to "not found"
-- (empty string / false for `has`), never an error.
--
-- `changed`/`changed_within <duration>` are valid only on `payload`/
-- `payload.<path>` (see shared/rule_engine/allowed_fields.lua). `changed`
-- takes no value - it's sugar for `changed_within 0`, both sharing the same
-- evaluator branch. They're true when the field's current value differs
-- (structurally, via `deep_equal`) from its value in a baseline observation:
-- `changed` compares against the immediately preceding observation;
-- `changed_within <duration>` compares against the most recent observation
-- recorded at least `<duration>` ago. Evaluating either requires the caller
-- to attach a `context._fetch_baseline(seconds) -> table|nil` function (see
-- shared/analyzer.lua's `make_baseline_fetcher`) - without one, or when no
-- qualifying prior observation exists, both operators evaluate to `false`
-- (never an error - the safe default). Bare `payload changed`/`payload
-- changed_within <duration>` diffs the entire decoded payload object (any
-- added/removed/changed property counts as changed). There is no dedicated
-- "unchanged" operator - use `NOT (payload.price changed)` /
-- `NOT (payload.price changed_within 1h)` instead.
--
-- `is_set` (valid only on `payload`/`payload.<path>`, same as `changed`)
-- takes no value and is true when the path resolves to a present value -
-- false when the payload isn't JSON, or the path doesn't exist. There's no
-- dedicated "not set"/"is null" operator - use
-- `NOT (payload.discount_code is_set)`, same convention as `changed`.
--
-- `contains` (valid on `source`/`payload`/`payload.<path>`) is a
-- case-insensitive PLAIN substring search - Lua's `string.find(..., 1,
-- true)`, so no Lua-pattern or regex syntax in the search term is
-- interpreted (`.`/`%`/`*`/etc match literally). There is deliberately no
-- regex/pattern-matching operator in this grammar - rule matching runs on
-- every ingested observation, and a user-authored regex there would be a
-- real catastrophic-backtracking (ReDoS) risk.
--
-- `FIELD in (value, value, ...)` is shorthand for
-- `FIELD = value OR FIELD = value OR ...` - same case-insensitive equality
-- semantics per element, just avoids repeating the field/operator. Valid
-- wherever `=`/`!=` is (see the caller-supplied `allowed_fields`), except
-- `tags`, which already has its own list-membership operator via `has`.
--
-- `FIELD dropped_pct <percent> within <duration>` / `raised_pct` (valid
-- only on `payload.<path>`) compare a numeric field's current value against
-- its value at a baseline observation at least `<duration>` ago - the same
-- `_fetch_baseline` mechanism as `changed_within` above. `dropped_pct` is
-- true when the current value is at least `<percent>` percent LOWER than
-- the baseline; `raised_pct` when it's at least `<percent>` percent
-- HIGHER. Evaluates to `false` (never an error) when either value is
-- missing/non-numeric, when there's no qualifying baseline, or when the
-- baseline is `0` (percent change is undefined against a zero baseline).
--
-- `FIELD older_than <duration>` / `newer_than` (valid only on
-- `payload.<path>`) compare a `date`-typed payload field (an ISO 8601
-- string, per server/lib/property_schema.lua) against `now - <duration>`,
-- via rule_engine.iso_date - `older_than` is true when the field's
-- date/datetime is before that cutoff, `newer_than` when it's at or after.
-- Evaluates to `false` when the field is missing or isn't a parseable ISO
-- 8601 date/datetime string. (A literal absolute-date comparison, e.g.
-- `payload.published_at > "2026-01-01"`, already works today via the plain
-- `>`/`<` fallback below - ISO 8601's lexicographic string order matches
-- chronological order for same-format strings; `older_than`/`newer_than`
-- only add the "relative to now" case that a literal can't express.)
--
-- `<duration>` is a magnitude+unit string parsed by rule_engine.duration:
-- `ms`/`s`/`m`/`h`/`d`/`M` (milliseconds/seconds/minutes/hours/days/
-- 30-day-approximated months), e.g. "500ms", "30s", "1m", "2h", "3d", "1M",
-- or a bare "0" (no unit).
--
-- Every value comparison - `tags has`, `contains`, `in`, flat `=`/`!=`/
-- ordinal on `source`/`payload`, and nested `payload.<path>` alike - is
-- case-insensitive on both sides, with no case-sensitive operator or
-- escape hatch. Two values differing only by case (e.g. tags "Prod" and
-- "PROD") are indistinguishable to this grammar.
--
-- `>`/`<`/`>=`/`<=` compare numerically when both sides parse as Lua
-- numbers (`tonumber`), otherwise fall back to the same case-insensitive
-- string comparison as `=`/`!=` - see `compare_ordinal` below. `=`/`!=`
-- themselves are always plain case-insensitive string comparison, never
-- numeric, so this is purely additive - it does not change any existing
-- comparison's behavior. EXCEPTION: on the `severity` field, `>`/`<`/`>=`/
-- `<=` instead rank both sides through the application's semantic
-- low<medium<high<critical ordering (`SEVERITY_RANK`/`compare_severity`
-- below, mirroring the DB's generated `severity_value` column exactly -
-- see config/dataset/init.sql), so `severity > "high"` means what an
-- author expects rather than a byte-wise string comparison.

local cjson_safe = require("cjson.safe")
local duration = require("rule_engine.duration")
local iso_date = require("rule_engine.iso_date")

local M = {}

local KEYWORDS = {
  ["and"] = "AND",
  ["or"] = "OR",
  ["not"] = "NOT",
  ["has"] = "HAS",
  ["contains"] = "CONTAINS",
  ["in"] = "IN",
  ["is_set"] = "IS_SET",
  ["changed"] = "CHANGED",
  ["changed_within"] = "CHANGED_WITHIN",
  ["dropped_pct"] = "DROPPED_PCT",
  ["raised_pct"] = "RAISED_PCT",
  ["within"] = "WITHIN",
  ["older_than"] = "OLDER_THAN",
  ["newer_than"] = "NEWER_THAN",
}

local ORDINAL_OPS = { [">"] = true, ["<"] = true, [">="] = true, ["<="] = true }

-- Mirrors the DB's generated `severity_value` column exactly (see
-- config/dataset/init.sql's `alerts` table) - used by `compare_severity`
-- below so `severity>`/`<`/`>=`/`<=` rank low<medium<high<critical instead
-- of comparing bytes.
local SEVERITY_RANK = { low = 1, medium = 2, high = 3, critical = 4 }

local DEFAULT_FIELD_OPERATORS = {
  tags = { has = true },
  source = { ["="] = true, ["!="] = true, ["in"] = true, contains = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  payload = { ["="] = true, ["!="] = true, ["in"] = true, contains = true, is_set = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  ["payload.*"] = {
    ["="] = true, ["!="] = true, has = true, ["in"] = true, contains = true, is_set = true,
    dropped_pct = true, raised_pct = true, older_than = true, newer_than = true,
    [">"] = true, ["<"] = true, [">="] = true, ["<="] = true,
  },
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

-- Walks `path` (dot-separated, e.g. "status" or "sensor.value") through a
-- plain table. Object-key traversal only - no array indexing. Returns nil if
-- `value` isn't a table, or the path doesn't resolve.
local function walk_path(value, path)
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

-- Walks `path` through the decoded payload table (see `decoded_payload`).
local function lookup_payload_path(context, path)
  return walk_path(decoded_payload(context), path)
end

-- Structural equality over nested tables/arrays (properties can be
-- multiple/typed per server/lib/property_schema.lua) - used by the
-- `changed`/`changed_within` evaluator branch to diff a current value
-- against a baseline one. String leaves are compared case-insensitively,
-- matching this file's own documented invariant that every value comparison
-- is case-insensitive on both sides (see header comment above).
local function deep_equal(a, b)
  if type(a) == "string" and type(b) == "string" then
    return a:lower() == b:lower()
  end
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

-- `>`/`<`/`>=`/`<=`: numeric comparison when both sides parse as Lua
-- numbers, otherwise the same case-insensitive string comparison `=`/`!=`
-- use - see `compare_severity` below for the `severity` field's own
-- ranked comparison instead of this one.
local function compare_ordinal(op, ctx_raw, target_raw)
  if type(ctx_raw) == "table" then
    return false
  end
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

-- `severity>`/`<`/`>=`/`<=`: ranks both sides through `SEVERITY_RANK`
-- (low<medium<high<critical) instead of `compare_ordinal`'s numeric/string
-- fallback - see the header comment's EXCEPTION note. Falls back to
-- `compare_ordinal` if either side isn't a recognized severity value
-- (defensive only - `VALID_SEVERITIES` already rejects anything else on
-- write, see server/plugins/rules/services/rules.lua).
local function compare_severity(op, ctx_raw, target_raw)
  local a = SEVERITY_RANK[tostring(ctx_raw):lower()]
  local b = SEVERITY_RANK[tostring(target_raw):lower()]
  if a == nil or b == nil then
    return compare_ordinal(op, ctx_raw, target_raw)
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

-- Case-insensitive membership check for `FIELD in (v1, v2, ...)` - same
-- equality semantics as `=`.
local function values_include(values, target_raw)
  local target = tostring(target_raw == nil and "" or target_raw):lower()
  for _, v in ipairs(values) do
    if tostring(v):lower() == target then
      return true
    end
  end
  return false
end

-- Case-insensitive plain (non-pattern) substring search for `contains` -
-- see the header comment on why this isn't a regex/Lua-pattern operator.
local function contains_substring(haystack_raw, needle_raw)
  local haystack = tostring(haystack_raw == nil and "" or haystack_raw):lower()
  local needle = tostring(needle_raw):lower()
  return haystack:find(needle, 1, true) ~= nil
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
    elseif c == "," then
      table.insert(tokens, { type = "comma", pos = i })
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
          or ch == ","
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

-- Reads a single "value" or "word" token (the grammar's `value := "\"...\""
-- | bareword`) and advances past it.
local function parse_value_token(p)
  local value_tok = p:peek()
  if value_tok.type == "value" or value_tok.type == "word" then
    p:advance()
    return value_tok.value
  end
  error(string.format("expected a value at position %d", value_tok.pos))
end

local function parse_comparison(p)
  local field_tok = p:peek()
  if field_tok.type ~= "word" then
    error(string.format("expected a field name at position %d", field_tok.pos))
  end
  p:advance()

  local op_tok = p:peek()

  -- No-value operators: `FIELD changed` / `FIELD is_set`.
  if op_tok.type == "CHANGED" or op_tok.type == "IS_SET" then
    p:advance()
    local op = op_tok.type == "CHANGED" and "changed" or "is_set"
    return { type = "cmp", field = field_tok.value, op = op, pos = field_tok.pos }
  end

  -- `FIELD in (value, value, ...)`.
  if op_tok.type == "IN" then
    p:advance()
    p:expect("lparen", "'('")
    local values = { parse_value_token(p) }
    while p:peek().type == "comma" do
      p:advance()
      table.insert(values, parse_value_token(p))
    end
    p:expect("rparen", "')'")
    return { type = "cmp", field = field_tok.value, op = "in", values = values, pos = field_tok.pos }
  end

  -- `FIELD (dropped_pct|raised_pct) <percent> within <duration>`.
  if op_tok.type == "DROPPED_PCT" or op_tok.type == "RAISED_PCT" then
    p:advance()
    local op = op_tok.type == "DROPPED_PCT" and "dropped_pct" or "raised_pct"
    local value = parse_value_token(p)
    p:expect("WITHIN", "'within'")
    local dur = parse_value_token(p)
    return { type = "cmp", field = field_tok.value, op = op, value = value, duration = dur, pos = field_tok.pos }
  end

  -- `FIELD (older_than|newer_than) <duration>`.
  if op_tok.type == "OLDER_THAN" or op_tok.type == "NEWER_THAN" then
    p:advance()
    local op = op_tok.type == "OLDER_THAN" and "older_than" or "newer_than"
    local dur = parse_value_token(p)
    return { type = "cmp", field = field_tok.value, op = op, value = dur, pos = field_tok.pos }
  end

  if op_tok.type == "op" then
    p:advance()
  elseif op_tok.type == "HAS" then
    p:advance()
    op_tok = { type = "op", value = "has", pos = op_tok.pos }
  elseif op_tok.type == "CONTAINS" then
    p:advance()
    op_tok = { type = "op", value = "contains", pos = op_tok.pos }
  elseif op_tok.type == "CHANGED_WITHIN" then
    p:advance()
    op_tok = { type = "op", value = "changed_within", pos = op_tok.pos }
  else
    error(
      string.format(
        "expected an operator (=, !=, has, contains, in, is_set, >=, <=, changed, "
          .. "changed_within, dropped_pct, raised_pct, older_than, newer_than) at position %d",
        op_tok.pos
      )
    )
  end

  local value = parse_value_token(p)

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
    if ast.op == "changed_within" or ast.op == "older_than" or ast.op == "newer_than" then
      local _, dur_err = duration.parse(ast.value)
      if dur_err then
        return string.format("semantic error at position %d: %s", ast.pos, dur_err)
      end
    end
    if ast.op == "dropped_pct" or ast.op == "raised_pct" then
      local pct = tonumber(ast.value)
      if not pct or pct < 0 then
        return string.format(
          "semantic error at position %d: '%s' expects a non-negative percent, got '%s'",
          ast.pos,
          ast.op,
          tostring(ast.value)
        )
      end
      local _, dur_err = duration.parse(ast.duration)
      if dur_err then
        return string.format("semantic error at position %d: %s", ast.pos, dur_err)
      end
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
  if ast.op == "changed" or ast.op == "changed_within" then
    local fetch_baseline = context._fetch_baseline
    if type(fetch_baseline) ~= "function" then
      return false
    end
    local seconds = ast.op == "changed" and 0 or duration.parse(ast.value) -- validated at parse time
    local baseline = fetch_baseline(seconds)
    if baseline == nil then
      return false
    end
    local current, baseline_value
    if ast.field == "payload" then
      current, baseline_value = decoded_payload(context), baseline
    else
      local path = ast.field:sub(#"payload." + 1)
      current, baseline_value = lookup_payload_path(context, path), walk_path(baseline, path)
    end
    return not deep_equal(current, baseline_value)
  end

  if ast.op == "is_set" then
    local value
    if ast.field == "payload" then
      value = decoded_payload(context)
    else
      value = lookup_payload_path(context, ast.field:sub(#"payload." + 1))
    end
    return value ~= nil
  end

  if ast.op == "dropped_pct" or ast.op == "raised_pct" then
    local fetch_baseline = context._fetch_baseline
    if type(fetch_baseline) ~= "function" then
      return false
    end
    local seconds = duration.parse(ast.duration) -- validated at parse time
    local baseline = fetch_baseline(seconds)
    if baseline == nil then
      return false
    end
    local path = ast.field:sub(#"payload." + 1)
    local current_num = tonumber(lookup_payload_path(context, path))
    local baseline_num = tonumber(walk_path(baseline, path))
    if not current_num or not baseline_num or baseline_num == 0 then
      return false
    end
    local threshold = tonumber(ast.value) -- validated at parse time
    local pct_change = (current_num - baseline_num) / math.abs(baseline_num) * 100
    if ast.op == "dropped_pct" then
      return baseline_num > current_num and -pct_change >= threshold
    else
      return current_num > baseline_num and pct_change >= threshold
    end
  end

  if ast.op == "older_than" or ast.op == "newer_than" then
    local path = ast.field:sub(#"payload." + 1)
    local raw_value = lookup_payload_path(context, path)
    if type(raw_value) ~= "string" then
      return false
    end
    local epoch = iso_date.parse(raw_value)
    if not epoch then
      return false
    end
    local seconds = duration.parse(ast.value) -- validated at parse time
    local cutoff = os.time() - seconds
    if ast.op == "older_than" then
      return epoch < cutoff
    else
      return epoch >= cutoff
    end
  end

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
    if ast.op == "in" then
      return values_include(ast.values, value)
    end
    if ast.op == "contains" then
      return contains_substring(value, ast.value)
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
    -- source, payload (raw string), severity, or any other flat field
    if ast.op == "in" then
      return values_include(ast.values, context[ast.field])
    end
    if ast.op == "contains" then
      return contains_substring(context[ast.field], ast.value)
    end
    if ORDINAL_OPS[ast.op] then
      if ast.field == "severity" then
        return compare_severity(ast.op, context[ast.field] or "", ast.value)
      end
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
