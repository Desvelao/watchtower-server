local Model = require("lapis.db.model").Model
local decorate_methods = require("lib.models").decorate_methods
local jsonb_query = require("lib.jsonb_query")

local m, mt = Model:extend("observer_configs")

-- Decodes the `fields`/`mechanism_config` JSONB columns on every read. Kept
-- here (rather than a route-level decode, the observable_types convention)
-- because server/workers/observe_pending_worker.lua's embedded_provider
-- calls this model's :select()/:find() directly and expects ready-to-use
-- tables.
function m:include_options_in(records)
    for _, record in ipairs(records) do
        record.fields = jsonb_query.decode(record.fields)
        record.mechanism_config = jsonb_query.decode(record.mechanism_config)
    end
    return records
end

decorate_methods(m, {"select", "find_all"}, function(t, results)
    if #results > 0 then
        t:include_options_in(results)
    end
    return results
end)

decorate_methods(m, {"find"}, function(t, results)
    if results then
        t:include_options_in({results})
    end
    return results
end)

return m, mt
