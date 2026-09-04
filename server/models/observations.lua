local Model = require("lapis.db.model").Model

-- Was Model:extend("monitoring") - table renamed to "observations" to free
-- "monitoring"/"monitors" for the scraping-agent registry
-- (server/models/monitors.lua).
return Model:extend("observations", {
    relations={
        {"items", belongs_to="Items", key="item_id"}
    }
})
