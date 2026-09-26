-- Server-side catalog of observer types usable by plugins/observer_configs.
-- Each observer_type owns two things a generic observer_configs row can't
-- express on its own:
--   - validate_field_def(name, def): the per-entry shape of observer_configs.fields
--     (see lib/observer_field_schema.lua, which this is threaded into).
--   - to_site(row): reshapes an already-decoded observer_configs row into
--     whatever shape that observer_type's real worker-side implementation
--     expects (for web_scraper: watchtower_observer_web_scraper.scraper_creator's
--     `sites` entry shape).
-- `mechanism_config` itself is NOT validated here - it's validated generically,
-- exactly like `fields`, against the target observable_type's own
-- `observer_mechanism_schema` (an admin-authored PropertyDefinition[], see
-- config/dataset/init.sql's observable_types column comment) via
-- lib/property_schema.lua's validate_values, in
-- plugins/observer_configs/plugin.lua's derive_observer_config_fields -
-- property_schema.lua's "map" type (added alongside `description`/`group`)
-- is what makes this possible now (it previously couldn't express
-- `headers: {string:string}`, hence this catalog's own hand-rolled
-- validators before this file was simplified).
-- Only 'web_scraper' is implemented today; a future second observer_type is
-- meant to be addable here alone, with no schema/plugin changes elsewhere.
-- Which catalog entry applies to a given observable type is NOT itself
-- configured anywhere (observable_types has no observer_type column) -
-- everything just resolves M.default(), the sole implemented type, via
-- this module. A real second observer type would decide how a target
-- resolves to one of several entries here, in this one place, rather than
-- reintroducing a stored per-observable-type field.
local observer_field_schema = require("lib.observer_field_schema")

local M = {}

-- The one observer type every observable type implicitly resolves to,
-- since there's currently nothing else to choose between (see this file's
-- header comment).
M.DEFAULT_TYPE = "web_scraper"

M.CATALOG = {
  web_scraper = {
    label = "Web scraper",

    validate_field_def = observer_field_schema.default_field_def_validator,

    -- Reshapes one already-decoded observer_configs row into the
    -- {name, urls_match, fields, expect_selector, block_selector,
    -- block_text, headers, ssl_verify} shape
    -- watchtower_observer_web_scraper.scraper_creator.new's `sites` param
    -- expects. Field names read off `mechanism_config` here are meaningful
    -- because this observer type's own worker-side code expects exactly
    -- these names - the admin authoring observer_mechanism_schema on the
    -- observable type is responsible for using them (see this file's
    -- header comment).
    to_site = function(row)
      local mc = row.mechanism_config or {}
      return {
        name = row.name,
        urls_match = mc.urls_match,
        fields = row.fields,
        expect_selector = mc.expect_selector,
        block_selector = mc.block_selector,
        block_text = mc.block_text,
        headers = mc.headers,
        ssl_verify = mc.ssl_verify,
      }
    end,
  },
}

function M.get(observer_type)
  return M.CATALOG[observer_type]
end

-- Returns (catalog_entry, observer_type) for M.DEFAULT_TYPE - the one seam
-- every current caller uses instead of resolving a per-observable-type
-- observer_type value that no longer exists.
function M.default()
  return M.CATALOG[M.DEFAULT_TYPE], M.DEFAULT_TYPE
end

function M.names()
  local names = {}
  for name in pairs(M.CATALOG) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

return M
