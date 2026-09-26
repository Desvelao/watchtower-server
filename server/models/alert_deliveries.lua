local Model = require("lapis.db.model").Model

-- Per-(alert, channel) durable delivery queue for the notify pipeline - see
-- this table's own header comment in config/dataset/init.sql,
-- shared/watchtower_worker_core/notification_policy_matcher.lua (the
-- "evaluator" role, which enqueues), and
-- plugins/notification_channels/services/delivery_queue.lua (the
-- "deliver" role, which claims/sends). Deliberately not columns on the
-- alerts model - see server/models/alerts.lua.
return Model:extend("alert_deliveries", {
    primary_key = { "alert_id", "channel_id" },
    relations = {
        { "alert", belongs_to = "alerts" },
        { "channel", belongs_to = "notification_channels" },
    },
})
