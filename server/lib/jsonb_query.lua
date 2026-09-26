-- JSONB-aware where-clause/search-clause building, sibling to lib/routes.lua
-- (reuses its escaping discipline - every value still goes through
-- db.escape_literal, never raw string interpolation). See
-- docs/dev/observable-types-storage.md for the full rationale/reference.
--
-- Query-param convention for a jsonb `properties` column, given a property
-- definition `{name="price", type="number", ...}`:
--   properties.price          -> `@>` containment (exact match; also the
--                                 correct "array contains this value" test
--                                 for a multiple=true property)
--   properties.price.gt/.gte/
--   properties.price.lt/.lte  -> cast-compare, only for number/date typed
--                                 properties (see RANGE_CAST_BY_TYPE)
local db = require("lapis.db")
local cjson = require("cjson")
local cjson_safe = require("cjson.safe")

local M = {}

-- SQL cast used for `(column->>name)::<cast>` range comparisons, keyed by
-- property `type`. A type with no entry here (string/url/enum/boolean) only
-- gets exact/contains (`@>`) query params, never a range one.
M.RANGE_CAST_BY_TYPE = { number = "numeric", date = "timestamp" }

local RANGE_OPERATORS = { gt = ">", gte = ">=", lt = "<", lte = "<=" }

local function coerce(prop, raw)
  if prop.type == "number" then
    return tonumber(raw)
  elseif prop.type == "boolean" then
    return raw == "true" or raw == true
  end
  return raw
end

-- db.raw() wrapping a jsonb literal for INSERT/UPDATE, e.g.
-- jsonb_query.encode({price=9.99}) -> db.raw(`'{"price":9.99}'::jsonb`) -
-- the one JSONB-write idiom used everywhere a `properties` column is
-- written.
function M.encode(value)
  return db.raw(db.escape_literal(cjson.encode(value or {})) .. "::jsonb")
end

-- Defensive read-side decode: handles both a Lua table (if the DB driver
-- already decoded the jsonb column) and a JSON string (if it didn't) -
-- there was no existing jsonb column in this codebase to copy a confirmed
-- idiom from.
function M.decode(value)
  if type(value) == "table" then
    return value
  end
  if type(value) == "string" then
    return cjson_safe.decode(value) or {}
  end
  return {}
end

-- Builds an array of lib.routes-shaped where_params entries
-- ({key=..., map_clause=fn}) - one exact/contains entry per property in
-- `schema`, plus range entries for number/date properties - scoped to
-- jsonb column `column` (e.g. "properties"). Splice the result into a
-- route's existing where_params list.
function M.where_params_for_schema(column, schema)
  local params = {}

  for _, prop in ipairs(schema or {}) do
    local key = "properties." .. prop.name

    table.insert(params, {
      key = key,
      map_clause = function(p)
        local encoded = cjson.encode({ [prop.name] = coerce(prop, p.value) })
        return column .. " @> " .. db.escape_literal(encoded) .. "::jsonb"
      end,
    })

    local cast = M.RANGE_CAST_BY_TYPE[prop.type]
    if cast then
      for suffix, operator in pairs(RANGE_OPERATORS) do
        table.insert(params, {
          key = key .. "." .. suffix,
          map_clause = function(p)
            return string.format(
              "(%s->>%s)::%s %s %s",
              column,
              db.escape_literal(prop.name),
              cast,
              operator,
              db.escape_literal(coerce(prop, p.value))
            )
          end,
        })
      end
    end
  end

  return params
end

-- Returns column specs (for lib.routes.create_search_map_clause) covering
-- every `searchable` string/url/enum property in `schema`, ILIKE-matching
-- `column->>'<name>'`.
function M.searchable_columns(column, schema)
  local route_helpers = require("lib.routes")
  local columns = {}

  for _, prop in ipairs(schema or {}) do
    if prop.searchable and (prop.type == "string" or prop.type == "url" or prop.type == "enum") then
      table.insert(columns, {
        key = string.format("%s->>%s", column, db.escape_literal(prop.name)),
        map_clause = function(p)
          return route_helpers.escaped_like_clause(p.key, p.value, "ILIKE")
        end,
      })
    end
  end

  return columns
end

return M
