local Model = require("lapis.db.model").Model

-- Was Model:extend("monitoring") - table renamed to "observations" to free
-- "monitoring"/"monitors" (now "workers") for the worker registry
-- (server/models/workers.lua).
return Model:extend("observations", {
    relations={
        {"observables", belongs_to="Observables", key="observable_id"}
    }
})
