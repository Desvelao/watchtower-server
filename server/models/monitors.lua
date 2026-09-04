local Model = require("lapis.db.model").Model

-- Scraping-agent registry. Primary key is monitor_id (a string, chosen by
-- the monitor itself - "embedded", "worker-lua", etc), not the usual
-- auto-increment id.
return Model:extend("monitors", {
    primary_key = "monitor_id",
})
