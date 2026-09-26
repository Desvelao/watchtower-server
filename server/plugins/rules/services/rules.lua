-- Rules: rows authored as a flat `name`/`if`/`severity`/... source document
-- (see shared/rule_engine/source.lua). Everything generic - deriving a row
-- from a document, CRUD, export, import, search - is lib/source_document_manager
-- (shared with notification policies); this module supplies only what's
-- specific to a rule.
local db = require("lapis.db")
local source_document_manager = require("lib.source_document_manager")
local allowed_fields = require("rule_engine.allowed_fields")

local M = {}

local VALID_SEVERITIES = { low = true, medium = true, high = true, critical = true }

-- The document keys a rule accepts.
local ALLOWED_KEYS = {
  name = true,
  description = true,
  ["if"] = true,
  severity = true,
  tags = true,
  enabled = true,
  cooldown_seconds = true,
}

-- A rule's own keys: an optional severity (overrides the matched alert's,
-- see services/rule_engine.lua) and an optional cooldown (suppresses
-- re-alerting this rule for the same observable within this many seconds of
-- it last firing - see shared/watchtower_worker_core/rule_matching.lua).
local function derive_extra(fields)
  local severity = fields.severity
  if severity == nil or severity == "" then
    severity = db.NULL
  elseif type(severity) ~= "string" or not VALID_SEVERITIES[severity] then
    return nil, "severity must be one of low, medium, high, critical"
  end

  local cooldown_seconds = fields.cooldown_seconds
  if cooldown_seconds == nil or cooldown_seconds == "" then
    cooldown_seconds = db.NULL
  elseif type(cooldown_seconds) ~= "number" or cooldown_seconds < 0 then
    return nil, "cooldown_seconds must be a non-negative number"
  end

  return { severity = severity, cooldown_seconds = cooldown_seconds }
end

-- config.on_change is called after every successful create/update/delete, so
-- callers (rule_engine's cache, see its `invalidate`) can react to a change.
function M.new(rule_model, config)
  return source_document_manager.new(rule_model, {
    label = "rule",
    display_name = "Rule",
    plural = "rules",
    export_basename = "rules-export",
    allowed_keys = ALLOWED_KEYS,
    allowed_fields = allowed_fields,
    derive_extra = derive_extra,
    on_change = config and config.on_change,
  })
end

return M
