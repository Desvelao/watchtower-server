local Model = require("lapis.db.model").Model

-- Fired alert instances - the alerting plugin's own resource. No longer
-- has the old alerts_notification_channels
-- bridge or eager-loading (that only made sense for the old
-- definition-row shape); see server/lib/models.lua if a future feature
-- needs those helpers again for a different resource. Notify-delivery
-- status is deliberately not a field here either - see
-- server/models/alert_deliveries.lua: alerts records what fired, that
-- sibling table records whether/how it was delivered.
return Model:extend("alerts", {
    relations = {
        { "observation", belongs_to = "observations" },
        { "rule", belongs_to = "rules" },
        { "deliveries", has_many = "alert_deliveries" },
    },
})
