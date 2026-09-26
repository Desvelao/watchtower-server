-- Base manager for "source document" resources: rows authored as a flat
-- `name:`/`if:`/... text document (see shared/rule_engine/source.lua) that the
-- API stores verbatim in a `source` column alongside the fields derived from
-- it. Rules (plugins/rules/services/rules.lua) and notification policies
-- (plugins/notification_channels/services/policies.lua) are the two such
-- resources, identical in everything but a few kind-specific fields, so this
-- one class owns the lot: validating/deriving a document into a row,
-- create/update/find/delete, export (one .yaml or a .zip of them), the
-- preflight/commit import flow, and the list search.
--
-- A kind supplies a `spec`:
--   label          - "rule"/"policy": names the resource in messages and in
--                    the exported block header ("# rule: name (id: 1)")
--   display_name   - "Rule"/"Notification policy": "<display_name> not found"
--   plural         - "rules"/"notification policies": "No <plural> to export"
--   export_basename - "rules-export": the exported file's name, sans extension
--   allowed_keys   - the document keys this kind accepts (anything else is an
--                    "Unknown <label> field" error)
--   allowed_fields - the field/operator vocabulary its `if` may reference
--   derive_extra(fields, manager) -> extra_row_fields | nil, err - validates
--                    and derives this kind's own keys (rules: severity/
--                    cooldown_seconds; policies: channels)
--   on_change      - optional; called after every successful create/update/
--                    delete (e.g. to invalidate a cache)
local db = require("lapis.db")
local route_helpers = require("lib.routes")
local rule_source = require("rule_engine.source")
local rule_expr = require("rule_engine.expr")
local zip_writer = require("lib.zip_writer")
local zip_reader = require("lib.zip_reader")

local M = {}
M.__index = M

local ZIP_MAGIC = "PK\3\4" -- zip local-file-header signature

function M.new(model, spec)
  return setmetatable({ _model = model, _spec = spec }, M)
end

function M:_notify_change()
  if self._spec.on_change then
    self._spec.on_change()
  end
end

-- Parses a comma-separated string into an array of trimmed, non-empty
-- entries. Returns nil when there are none.
function M.split_list(raw)
  local list = {}
  for part in raw:gmatch("[^,]+") do
    local trimmed = part:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(list, trimmed)
    end
  end
  return #list > 0 and list or nil
end

-- Parses+validates a raw `source` document into a flat row ready for
-- Model:create()/item:update(). Returns (row, nil) on success or
-- (nil, err_string) on any validation failure - the route layer uses this to
-- distinguish an expected 400 from a genuine 500.
function M:_derive(source)
  local spec = self._spec

  if type(source) ~= "string" or source == "" then
    return nil, "source is required"
  end

  local fields, parse_err = rule_source.parse(source)
  if not fields then
    return nil, "Invalid " .. spec.label .. " source: " .. parse_err
  end

  for k in pairs(fields) do
    if not spec.allowed_keys[k] then
      return nil, "Unknown " .. spec.label .. " field: " .. k
    end
  end

  local name = fields.name
  if type(name) ~= "string" or name == "" then
    return nil, "name is required"
  end

  local if_expr = fields["if"]
  if type(if_expr) ~= "string" or if_expr == "" then
    return nil, "if is required"
  end
  local _, expr_err = rule_expr.parse(if_expr, spec.allowed_fields)
  if expr_err then
    return nil, "Invalid 'if' expression: " .. expr_err
  end

  local extra, extra_err = spec.derive_extra(fields, self)
  if not extra then
    return nil, extra_err
  end

  local enabled = fields.enabled
  if enabled == nil then
    enabled = true
  elseif type(enabled) ~= "boolean" then
    return nil, "enabled must be true or false"
  end

  local description = fields.description
  if description == nil or description == "" then
    description = db.NULL
  end

  local tags = fields.tags
  if tags == nil or tags == "" then
    tags = db.NULL
  elseif type(tags) ~= "string" then
    return nil, "tags must be a comma-separated string"
  else
    local tag_list = M.split_list(tags)
    tags = tag_list and db.array(tag_list) or db.NULL
  end

  local row = {
    source = source,
    name = name,
    description = description,
    condition_expression = if_expr,
    tags = tags,
    enabled = enabled,
  }
  for k, v in pairs(extra) do
    row[k] = v
  end
  return row, nil
end

function M:create(params)
  local row, err = self:_derive(params.source)
  if not row then
    return nil, err
  end
  local item = self._model:create(row)
  self:_notify_change()
  return item, nil
end

function M:update(item_id, params)
  local item = self._model:find({ id = item_id })
  if not item then
    return nil, self._spec.display_name .. " not found"
  end

  local row, err = self:_derive(params.source)
  if not row then
    return nil, err
  end

  row.updated_at = db.format_date()

  local ok = item:update(row)
  if not ok then
    return nil, "Update failed"
  end

  self:_notify_change()
  return self._model:find({ id = item_id }), nil
end

function M:find(item_id)
  return self._model:find({ id = item_id })
end

function M:delete(item_id)
  local item = self._model:find({ id = item_id })
  if not item then
    error({ status = 404, message = self._spec.display_name .. " not found" })
  end
  local result = item:delete()
  self:_notify_change()
  return result
end

-- Filesystem-safe entry name for one item inside a multi-item export zip.
-- The trailing "-<id>" the caller adds guarantees uniqueness even when two
-- items share a name; slugifying the name alone would not.
local function slugify(name, default)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    slug = default
  end
  return slug
end

-- Renders one row back into its own authored `source` text with a plain
-- comment header - not a real YAML file (rule_source.lua isn't a general YAML
-- parser either), just enough for the exported file to be self-descriptive.
function M:_format_block(item)
  return string.format("# %s: %s (id: %d)\n%s", self._spec.label, item.name, item.id, item.source)
end

-- `ids`, if given, is an array of ids to export; nil/empty exports every
-- row. Manual escape_literal-per-id concatenation matches this codebase's
-- convention rather than introducing db.list/interpolate_query.
--
-- Returns (content, content_type, filename) on success. A single matching
-- row stays a plain text/yaml file; 2+ are packed into a zip, one file per
-- row, via lib/zip_writer - built server-side instead of pulling in a
-- client-side zip library. Zero matching rows returns (nil, nil, nil,
-- error_message) rather than silently succeeding with an empty file.
function M:export(ids)
  local spec = self._spec
  local query = "order by id asc"
  if ids and #ids > 0 then
    local escaped = {}
    for _, id in ipairs(ids) do
      table.insert(escaped, db.escape_literal(tonumber(id)))
    end
    query = "where id in (" .. table.concat(escaped, ", ") .. ") order by id asc"
  end

  local items = self._model:select(query)

  if #items == 0 then
    return nil, nil, nil, "No " .. spec.plural .. " to export"
  end

  if #items == 1 then
    return self:_format_block(items[1]), "text/yaml; charset=utf-8", spec.export_basename .. ".yaml"
  end

  local files = {}
  for _, item in ipairs(items) do
    table.insert(files, {
      name = slugify(item.name, spec.label) .. "-" .. item.id .. ".yaml",
      content = self:_format_block(item),
    })
  end
  return zip_writer.build(files), "application/zip", spec.export_basename .. ".zip"
end

-- Parses (but does not save) an uploaded file or zip of files. `bytes` is
-- sniffed for the zip signature rather than trusted from the client-supplied
-- filename/extension; a zip yields one candidate per entry, anything else is
-- treated as a single document. Returns an array of either `{ file, error }`
-- (failed to parse) or `{ file, name, source, conflict: {id, name}|nil }`
-- (parsed ok, with an existing same-named row flagged for the caller to
-- resolve). Nothing is written to the DB - see M:commit_import for that.
function M:preflight_import(filename, bytes)
  local entries
  if bytes:sub(1, 4) == ZIP_MAGIC then
    local files, err = zip_reader.read(bytes)
    if not files then
      return nil, "Could not read zip: " .. err
    end
    entries = files
  else
    entries = { { name = filename, content = bytes } }
  end

  local candidates = {}
  for _, entry in ipairs(entries) do
    local row, err = self:_derive(entry.content)
    if not row then
      table.insert(candidates, { file = entry.name, error = err })
    else
      local candidate = { file = entry.name, name = row.name, source = entry.content }
      local existing = self._model:find({ name = row.name })
      if existing then
        candidate.conflict = { id = existing.id, name = existing.name }
      end
      table.insert(candidates, candidate)
    end
  end

  return candidates
end

-- `items` is the frontend's resolved decisions from a preflight_import
-- result: `{ source, action = "create" | "update", existing_id? }[]`. Reuses
-- M:create/M:update exactly as the single-document form does - no
-- validation logic is duplicated here. Any `action` other than exactly
-- "create" or "update" (with a truthy `existing_id`) - including the
-- documented "skip" option, nil, or a typo - is rejected as a no-op rather
-- than falling through to create, since the bundled frontends already
-- filter "skip" items out client-side before POSTing and this route has no
-- other validation of `action`. Returns a parallel array of `{ ok, error? }`,
-- one per item, mirroring the existing bulk delete/revoke "N of M succeeded"
-- pattern rather than failing the whole batch over one bad item.
function M:commit_import(items)
  local results = {}
  for _, item in ipairs(items) do
    local ok, row, err = pcall(function()
      if item.action == "update" and item.existing_id then
        return self:update(item.existing_id, { source = item.source })
      elseif item.action == "create" then
        return self:create({ source = item.source })
      end
      return nil, "Unsupported action '" .. tostring(item.action) .. "' (expected 'create', or 'update' with existing_id)"
    end)

    if ok and row then
      table.insert(results, { ok = true })
    elseif ok then
      table.insert(results, { ok = false, error = err })
    else
      table.insert(results, { ok = false, error = tostring(row) })
    end
  end
  return results
end

function M:search(request)
  local params = {
    "id",
    "name",
    "enabled",
    route_helpers.created_after_param(),
    route_helpers.created_before_param(),
    {
      key = "search",
      map_clause = route_helpers.create_search_map_clause({
        {
          key = "name",
          map_clause = function(p)
            return route_helpers.escaped_like_clause("name", p.value)
          end,
        },
        {
          key = "description",
          map_clause = function(p)
            return route_helpers.escaped_like_clause("description", p.value)
          end,
        },
      }),
    },
  }

  local query = route_helpers.get_db_query_params_from_request_params(request, params)
  local where_clause = route_helpers.get_db_where_clause_from_request_params(request, params)

  return {
    items = self._model:select(query),
    total_items = self._model:count(where_clause),
  }
end

return M
