local cjson = require("cjson")
local Model = require("lapis.db.model").Model
local decorate_methods = require("lib.models").decorate_methods

local nc, ncmt = Model:extend("notification_channels")

local DiscordNotificationChannels = Model:extend("notification_channels_discord", {
    relations= {
        {"channel", belongs_to="notification_channels"}
    }
})

local WebhookNotificationChannels = Model:extend("notification_channels_webhook", {
    relations= {
        {"channel", belongs_to="notification_channels"}
    }
})

local EmailNotificationChannels = Model:extend("notification_channels_email", {
    relations= {
        {"channel", belongs_to="notification_channels"}
    }
})

nc.__relation_by_type = {
    discord = DiscordNotificationChannels,
    webhook = WebhookNotificationChannels,
    email = EmailNotificationChannels
}

function nc:get_resolver_options(record)
    return self.__relation_by_type[record.type]
end

function nc:resolve_channel_options(record)
    local record_options = self:get_resolver_options(record):find({channel_id = record.id})
    if record_options then
        record_options.channel_id = nil -- TODO: remove foreign key
        record_options.id = nil -- TODO: remove notification channels options id
    end
    return record_options
end

function nc:include_options_in(records)
    for _,record in ipairs(records) do
        record.options = self:resolve_channel_options(record)
    end
end

decorate_methods(nc, {"select", "find_all"}, function(t, results)
    if #results > 0 then
        t:include_options_in(results)
    end
    return results
end)

decorate_methods(nc, {"find"}, function(t, results)
    if results then
        t:include_options_in({results})
    end
    return results
end)

local _orig_create = nc.create
function nc:create(data)
    local channel = _orig_create(nc,{
        name=data.name,
        type=data.type
    })

    local options = data.options
    options.channel_id = channel.id

    channel.options = self:get_resolver_options(data):create(options)
    return channel
end

function nc:update(data, notification_channel_id)
    local record = nc:find(notification_channel_id)

    record:update({
        name=data.name,
        type=data.type
    })

    record.options = self:get_resolver_options(data):find({channel_id=record.id}):update(data.options)
    return record
end

return nc, ncmt