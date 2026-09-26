-- Notification policies: rows authored the same flat-document way a rule is
-- (see plugins/rules/services/rules.lua) - a policy's `if` matches an ALERT
-- (not an observation) and its `action` is "notify these channels" instead of
-- a free-text label, hence `channels` (a comma-separated list of
-- notification_channels ids). Everything generic - deriving a row from a
-- document, CRUD, export, import, search - is lib/source_document_manager
-- (shared with rules); this module supplies only what's specific to a policy.
local db = require("lapis.db")
local source_document_manager = require("lib.source_document_manager")
local allowed_fields = require("rule_engine.notification_policy_allowed_fields")

local M = {}

-- The document keys a policy accepts.
local ALLOWED_KEYS = {
  name = true,
  description = true,
  ["if"] = true,
  channels = true,
  tags = true,
  enabled = true,
}

-- Parses a comma-separated list of bare integers into a deduplicated array
-- of numbers, in first-seen order. Returns nil (not an empty table) when
-- `raw` has no usable entries, so callers can tell "field omitted/empty"
-- from "field parsed to zero items".
local function parse_id_list(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local seen, ids = {}, {}
  for part in raw:gmatch("[^,]+") do
    local trimmed = part:match("^%s*(.-)%s*$")
    local id = tonumber(trimmed)
    if id and not seen[id] then
      seen[id] = true
      table.insert(ids, id)
    end
  end
  return #ids > 0 and ids or nil
end

-- A policy's own key: the channels it routes to, each of which must exist.
local function derive_extra(fields, manager)
  -- rule_source.lua's coerce_value turns a bare-integer value (e.g. a single
  -- channel id with no comma, "channels: 1") into a Lua number, not a string
  -- - only a multi-id list ("channels: 1,2") stays a string. A number is
  -- stringified back before parsing, so both shapes work.
  local channels_raw = fields.channels
  if type(channels_raw) == "number" then
    channels_raw = tostring(channels_raw)
  end
  if type(channels_raw) ~= "string" or channels_raw == "" then
    return nil, "channels is required (comma-separated notification_channels ids)"
  end
  local channel_ids = parse_id_list(channels_raw)
  if not channel_ids then
    return nil, "channels must be a comma-separated list of channel ids"
  end
  local count = manager._channels:count("id = any(?)", db.array(channel_ids))
  if count ~= #channel_ids then
    return nil, "channels must all reference an existing notification channel"
  end
  return { channel_ids = db.array(channel_ids) }
end

function M.new(policy_model, channels_model)
  local manager = source_document_manager.new(policy_model, {
    label = "policy",
    display_name = "Notification policy",
    plural = "notification policies",
    export_basename = "notification-policies-export",
    allowed_keys = ALLOWED_KEYS,
    allowed_fields = allowed_fields,
    derive_extra = derive_extra,
  })
  manager._channels = channels_model
  return manager
end

return M
