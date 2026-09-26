-- Validates observable-type property-schema definitions and the values
-- submitted against them. Used by plugins/entities for observable_types
-- (validate_schema) and for observables/observations properties payloads
-- (validate_values). See docs/dev/observable-types-storage.md for the
-- full shape reference and rationale.
--
-- A property-definition object looks like:
--   { name, label, description?, group?,
--     type: "string"|"number"|"boolean"|"date"|"url"|"enum"|"map",
--     multiple: bool, required: bool, searchable: bool, list_column: bool,
--     validations: {...} }
--
-- list_column is schema-agnostic here (like searchable) - it's only ever
-- surfaced/consumed for observer_config_schema/observer_mechanism_schema,
-- where it lets an admin mark a field to appear as an extra column in the
-- Observer Configs table when that observable type is the active filter
-- (public/src/plugins/observer_configs/views/ObserverConfigsListView.vue).
--
-- description/group are purely informational passthrough (no validation
-- beyond "must be a string if present") - description is shown near a
-- field's input by consumers that render a schema as a form (see
-- public/src/components/common/SchemaFieldsForm.vue); group is a UI
-- grouping label, fields sharing the same group string rendered together
-- under one heading, in schema order.
--
-- Allowed `validations` keys per type:
--   string/url: minLength, maxLength, pattern (a Lua pattern)
--   number/date: min, max
--   enum: options (required, non-empty array of strings)
--   boolean/map: none
local M = {}

M.TYPES = { "string", "number", "boolean", "date", "url", "enum", "map" }

local TYPE_SET = {}
for _, t in ipairs(M.TYPES) do
  TYPE_SET[t] = true
end

local ALLOWED_VALIDATIONS = {
  string = { minLength = true, maxLength = true, pattern = true },
  url = { minLength = true, maxLength = true, pattern = true },
  number = { min = true, max = true },
  date = { min = true, max = true },
  enum = { options = true },
  boolean = {},
  -- map: a JSON object of string -> string (e.g. HTTP headers) - no
  -- per-type validations today.
  map = {},
}

local NAME_PATTERN = "^[a-z][a-z0-9_]*$"

local function validate_definition(def, seen_names)
  if type(def) ~= "table" then
    return nil, "each property must be an object"
  end

  local name = def.name
  if type(name) ~= "string" or not name:match(NAME_PATTERN) then
    return nil, "property name must match ^[a-z][a-z0-9_]*$: " .. tostring(name)
  end
  if seen_names[name] then
    return nil, "duplicate property name: " .. name
  end
  seen_names[name] = true

  local ptype = def.type
  if not TYPE_SET[ptype] then
    return nil, "unknown property type for '" .. name .. "': " .. tostring(ptype)
  end

  local validations = def.validations
  if validations == nil then
    validations = {}
  elseif type(validations) ~= "table" then
    return nil, "validations must be an object for property: " .. name
  end

  local allowed = ALLOWED_VALIDATIONS[ptype]
  local normalized_validations = {}
  for k, v in pairs(validations) do
    if not allowed[k] then
      return nil, string.format("validation '%s' is not allowed for type '%s' (property '%s')", k, ptype, name)
    end
    normalized_validations[k] = v
  end

  if ptype == "enum" then
    local options = normalized_validations.options
    if type(options) ~= "table" or #options == 0 then
      return nil, "enum property '" .. name .. "' requires a non-empty validations.options array"
    end
    for _, opt in ipairs(options) do
      if type(opt) ~= "string" then
        return nil, "enum options must be strings (property '" .. name .. "')"
      end
    end
  end

  if def.description ~= nil and type(def.description) ~= "string" then
    return nil, "description must be a string for property: " .. name
  end
  if def.group ~= nil and type(def.group) ~= "string" then
    return nil, "group must be a string for property: " .. name
  end

  return {
    name = name,
    label = type(def.label) == "string" and def.label or name,
    description = type(def.description) == "string" and def.description or nil,
    group = type(def.group) == "string" and def.group or nil,
    type = ptype,
    multiple = def.multiple == true,
    required = def.required == true,
    searchable = def.searchable == true,
    list_column = def.list_column == true,
    validations = normalized_validations,
  }
end

-- Validates a raw property-definition array (as decoded from
-- observable_types.properties or .observation_schema). Returns
-- (true, normalized_schema) or (false, error_message).
function M.validate_schema(schema)
  if schema == nil then
    return true, {}
  end
  if type(schema) ~= "table" then
    return false, "schema must be an array"
  end

  local normalized = {}
  local seen_names = {}
  for i, def in ipairs(schema) do
    local normalized_def, err = validate_definition(def, seen_names)
    if not normalized_def then
      return false, err
    end
    normalized[i] = normalized_def
  end

  return true, normalized
end

local function validate_scalar(prop, value)
  local t = prop.type
  local v = prop.validations or {}

  if t == "string" or t == "url" then
    if type(value) ~= "string" then
      return nil, prop.name .. " must be a string"
    end
    if v.minLength and #value < v.minLength then
      return nil, prop.name .. " must be at least " .. v.minLength .. " characters"
    end
    if v.maxLength and #value > v.maxLength then
      return nil, prop.name .. " must be at most " .. v.maxLength .. " characters"
    end
    if v.pattern and not value:match(v.pattern) then
      return nil, prop.name .. " does not match the required pattern"
    end
    if t == "url" and not value:match("^https?://") then
      return nil, prop.name .. " must be a valid http(s) URL"
    end
    return value
  elseif t == "number" then
    local n = tonumber(value)
    if not n then
      return nil, prop.name .. " must be a number"
    end
    if v.min and n < v.min then
      return nil, prop.name .. " must be >= " .. tostring(v.min)
    end
    if v.max and n > v.max then
      return nil, prop.name .. " must be <= " .. tostring(v.max)
    end
    return n
  elseif t == "boolean" then
    if type(value) ~= "boolean" then
      return nil, prop.name .. " must be a boolean"
    end
    return value
  elseif t == "date" then
    if type(value) ~= "string" or not value:match("^%d%d%d%d%-%d%d%-%d%d") then
      return nil, prop.name .. " must be an ISO 8601 date/datetime string"
    end
    if v.min and value < v.min then
      return nil, prop.name .. " must be on/after " .. v.min
    end
    if v.max and value > v.max then
      return nil, prop.name .. " must be on/before " .. v.max
    end
    return value
  elseif t == "enum" then
    if type(value) ~= "string" then
      return nil, prop.name .. " must be a string"
    end
    for _, opt in ipairs(v.options or {}) do
      if opt == value then
        return value
      end
    end
    return nil, prop.name .. " must be one of: " .. table.concat(v.options or {}, ", ")
  elseif t == "map" then
    if type(value) ~= "table" then
      return nil, prop.name .. " must be an object of string values"
    end
    for mk, mv in pairs(value) do
      if type(mk) ~= "string" or type(mv) ~= "string" then
        return nil, prop.name .. " must be an object of string values"
      end
    end
    return value
  end

  return nil, "unsupported type: " .. tostring(t)
end

-- Validates+coerces a `values` table (decoded from a request's `properties`
-- JSON) against `schema` (an already-normalized property-definition array,
-- e.g. from an observable_type row's .properties/.observation_schema).
-- Returns (true, normalized_values) or (false, error_message).
function M.validate_values(schema, values)
  if values == nil then
    values = {}
  end
  if type(values) ~= "table" then
    return false, "properties must be an object"
  end

  schema = schema or {}

  local by_name = {}
  for _, prop in ipairs(schema) do
    by_name[prop.name] = prop
  end

  for key in pairs(values) do
    if not by_name[key] then
      return false, "unknown property: " .. tostring(key)
    end
  end

  local normalized = {}
  for _, prop in ipairs(schema) do
    local raw = values[prop.name]

    if raw == nil then
      if prop.required then
        return false, prop.name .. " is required"
      end
    elseif prop.multiple then
      if type(raw) ~= "table" then
        return false, prop.name .. " must be an array"
      end
      local arr = {}
      for i, element in ipairs(raw) do
        -- v == nil (not `not v`): validate_scalar's only falsy success
        -- value is the boolean `false` itself (a valid "boolean" property
        -- value) - `not v` would misread that as a failure, since `err`
        -- is nil on every success path.
        local v, err = validate_scalar(prop, element)
        if v == nil then
          return false, err
        end
        arr[i] = v
      end
      normalized[prop.name] = arr
    else
      -- "map" is the one non-multiple type whose own valid value is itself
      -- a Lua table (a JSON object, not an array) - this guard exists to
      -- catch an array mistakenly sent for a scalar-typed property, so it
      -- must not fire for "map" itself; validate_scalar's own `type(value)
      -- ~= "table"` check below still rejects a genuine array (Lua can't
      -- distinguish a JSON array from an empty/mixed object once decoded,
      -- but a non-empty array's own elements would fail the map's
      -- string-keys check).
      if type(raw) == "table" and prop.type ~= "map" then
        return false, prop.name .. " must be a single value, not a list"
      end
      local v, err = validate_scalar(prop, raw)
      if v == nil then
        return false, err
      end
      normalized[prop.name] = v
    end
  end

  return true, normalized
end

-- The first non-multiple url-typed property in `schema`, if any - shared by
-- plugins/entities/observables_routes.lua (defaults an observable's `name`)
-- and plugins/observer_configs/plugin.lua (resolves the URL to observe out of a
-- test request's submitted `properties`, since no per-observable-type
-- "which property is the URL" concept exists anywhere server-side beyond
-- this convention - see that plugin's own test routes).
function M.find_url_property(schema)
  for _, prop in ipairs(schema or {}) do
    if prop.type == "url" and not prop.multiple then
      return prop
    end
  end
  return nil
end

return M
