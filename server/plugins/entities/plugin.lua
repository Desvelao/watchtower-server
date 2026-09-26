-- Entities: generalizes "product price monitoring" to arbitrary observable
-- types. Owns observable_types (schema definitions - see
-- lib/property_schema.lua) plus the relocated/rewritten observables and
-- observations routes (previously separate plugins/items,
-- plugins/observations - merged here since both are now driven by an
-- observable_type's schema and the frontend groups their views under one
-- "Entities" app, see public/src/plugins/entities/plugin.js).
local Plugin = {
  name = "entities",
  dependencies = { "security" },
}

function Plugin.setup(app, deps)
  local observable_type_manager = require("plugins.entities.observable_types_routes")(app, deps)
  require("plugins.entities.observables_routes")(app, deps, observable_type_manager)
  require("plugins.entities.observations_routes")(app, deps, observable_type_manager)

  return {
    observable_type_manager = observable_type_manager,
  }
end

return Plugin
