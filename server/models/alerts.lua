local Model = require("lapis.db.model").Model
local Items = require('models.items')
local NotificationChannels = require('models.notification_channels')
local enhance_bridge_model = require('lib.models').enhance_bridge_model
local decorate_methods = require("lib.models").decorate_methods

local a, at = Model:extend("alerts", {
    relations={
        {"item", belongs_to = "items", key="item_id"}
    },
})

local an, ant = Model:extend("alerts_notification_channels", {
    primary_key = { "alert_id", "channel_id" },
    relations={
        {"channel", belongs_to = "notification_channels"},
        {"alert", belongs_to = "alerts"}
    },
    create_channels=function(self, alert_id, channels)
        local results = {}
        for _,v in ipairs(channels) do
            local result = self:create({
                alert_id=alert_id,
                channel_id=v
            })
            table.insert(results, result.channel_id)
        end
        return results
    end,
    update_channels=function(self, alert_id, channels)
        local results = {}
        -- Step 1: Fetch existing channel_ids for the alert
        local existing = self:select("WHERE alert_id = ?", alert_id)
        local existing_map = {}
        for _, row in ipairs(existing) do
            existing_map[row.channel_id] = true
        end

        -- Step 2: Build a set of new channel_ids
        local new_map = {}
        for _, cid in ipairs(channels) do
            new_map[cid] = true
        end

        -- Step 3: Delete channel_ids that are no longer present
        for cid in pairs(existing_map) do
            if not new_map[cid] then
                self:delete({ alert_id = alert_id, channel_id = cid })
            end
        end

        -- Step 4: Insert new channel_ids that don't already exist
        for cid in pairs(new_map) do
            if not existing_map[cid] then
                local result = self:create({ alert_id = alert_id, channel_id = cid })
                table.insert(results, result.channel_id)
            end
        end
        return results
    end
})

enhance_bridge_model(ant, {"channel_id", "alert_id"})

decorate_methods(a, {"select", "find_all"}, function(t, results)
    if #results > 0 then
        an:include_channel_id_in(results, {
            filter_field="alert_id",
            select_options={fields="channel_id"},
            relation_method="get_channel",
            store_at_field="channels"
        })
    
        Items:include_in(results, "item_id")
    
        for _,record in ipairs(results) do
            record.item_id = nil
        end
    end
    return results
end)

decorate_methods(a, {"find"}, function(t, results)
    if results then
        local records = {results}
        an:include_channel_id_in(records, {
            filter_field="alert_id",
            select_options={fields="channel_id"},
            relation_method="get_channel",
            store_at_field="channels"
        })
    
        Items:include_in(records, "item_id")
    end
    return results
end)

local _orig_create = a.create
function a:create(data)
    local record = _orig_create(a, {
        name=data.name,
        enabled=data.enabled,
        item_id=data.item_id,
        trigger_on_price=data.trigger_on_price,
        trigger_on_discount=data.trigger_on_discount,
        trigger_on_available=data.trigger_on_available,
    })

    record.channels = an:create_channels(record.id, data.channels)

    return record
end

function a:update(data, id)
    local record = a:find(id)

    record:update({
        name=data.name,
        enabled=data.enabled,
        item_id=data.item_id,
        trigger_on_price=data.trigger_on_price,
        trigger_on_discount=data.trigger_on_discount,
        trigger_on_available=data.trigger_on_available,
    })

    record.channels = an:update_channels(record.id, data.channels)

    return record
end

return a, at