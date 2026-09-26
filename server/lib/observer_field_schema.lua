-- Field-definition validator for observer_configs.fields
-- (see plugins/observer_configs/plugin.lua). Same {selector: string[]} |
-- {compute: string} (+ optional transform/validate/temporal) field-definition
-- shape by default, but parameterized instead of hardcoding a required-field
-- list or the field-definition validator itself:
--   - required_field_names is derived by the caller from the target
--     observable_type's own observer_config_schema (authored on
--     observable_types, see config/dataset/init.sql), not a module-level
--     constant - a "product" required list would say nothing about a
--     future "widget" type.
--   - field_def_validator lets a future observer_type (see
--     lib/observer_type_catalog.lua) supply its own field-entry shape
--     without changing this module.
local M = {}

local NAME_PATTERN = "^[a-z][a-z0-9_]*$"

-- Default field-definition validator.
function M.default_field_def_validator(name, def)
  if type(def) ~= "table" then
    return nil, "field '" .. name .. "' must be an object"
  end

  local has_selector = def.selector ~= nil
  local has_compute = def.compute ~= nil

  if has_selector and has_compute then
    return nil, "field '" .. name .. "' cannot declare both selector and compute"
  end
  if not has_selector and not has_compute then
    return nil, "field '" .. name .. "' must declare either selector or compute"
  end

  local normalized = { temporal = def.temporal == true }

  if has_selector then
    if type(def.selector) ~= "table" or #def.selector == 0 then
      return nil, "field '" .. name .. "'.selector must be a non-empty array"
    end
    for _, s in ipairs(def.selector) do
      if type(s) ~= "string" or #s == 0 then
        return nil, "field '" .. name .. "'.selector entries must be non-empty strings"
      end
    end
    normalized.selector = def.selector
  else
    if type(def.compute) ~= "string" or #def.compute == 0 then
      return nil, "field '" .. name .. "'.compute must be a non-empty string"
    end
    normalized.compute = def.compute
  end

  if def.transform ~= nil then
    if type(def.transform) ~= "string" then
      return nil, "field '" .. name .. "'.transform must be a string"
    end
    normalized.transform = def.transform
  end
  if def.validate ~= nil then
    if type(def.validate) ~= "string" then
      return nil, "field '" .. name .. "'.validate must be a string"
    end
    normalized.validate = def.validate
  end

  return normalized
end

-- Every property-definition name with required=true in an already-normalized
-- PropertyDefinition[] (e.g. observable_type.observer_config_schema).
-- Schema-shape-agnostic - works on any property_schema.lua-normalized array.
function M.required_field_names(schema)
  local names = {}
  for _, prop in ipairs(schema or {}) do
    if prop.required then
      names[#names + 1] = prop.name
    end
  end
  return names
end

-- Validates a raw `fields` map against `required_field_names` (array of
-- strings; any number of additional named fields beyond these are allowed)
-- using `field_def_validator` (defaults to M.default_field_def_validator)
-- for each individual field's own shape. Returns (true, normalized_fields)
-- or (false, error_message).
function M.validate_fields(fields, required_field_names, field_def_validator)
  field_def_validator = field_def_validator or M.default_field_def_validator

  if type(fields) ~= "table" then
    return false, "fields must be an object"
  end

  local normalized = {}
  for name, def in pairs(fields) do
    if type(name) ~= "string" or not name:match(NAME_PATTERN) then
      return false, "field name must match ^[a-z][a-z0-9_]*$: " .. tostring(name)
    end
    local normalized_def, err = field_def_validator(name, def)
    if not normalized_def then
      return false, err
    end
    normalized[name] = normalized_def
  end

  for _, required in ipairs(required_field_names or {}) do
    if not normalized[required] then
      return false, "missing required field: " .. required
    end
  end

  return true, normalized
end

return M
