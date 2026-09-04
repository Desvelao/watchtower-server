local Model = require("lapis.db.model").Model

-- Fired alert instances (status/priority state machine) - the alerting
-- plugin's own resource. No longer has the old alerts_notification_channels
-- bridge or eager-loading (that only made sense for the old
-- definition-row shape); see server/lib/models.lua if a future feature
-- needs those helpers again for a different resource.
return Model:extend("alerts", {
    relations = {
        { "event", belongs_to = "events" },
        { "rule", belongs_to = "rules" },
    },
})
