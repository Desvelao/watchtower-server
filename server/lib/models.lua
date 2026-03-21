local function enhance_bridge_model(mt, primary_keys)

    for i, primary_key in ipairs(primary_keys) do
        mt["include_" .. primary_key .. "_in_record"] = function(self, relation_record, options) 
            local query_records = self:select(
                string.format('where %s = ?', options.filter_field),
                relation_record.id, -- TODO: allow other fields instead of id
                options.select_options
            )

            local records = {}
            for k,v in pairs(query_records) do
                table.insert(records, v[options.relation_method](v) )
            end
            relation_record[options.store_at_field] = records
        end
        mt["include_" .. primary_key .. "_in"] = function(self, records, options) 
            for i, record in ipairs(records) do
                self["include_" .. primary_key .. "_in_record"](self, record, options)
            end
        end
    end
end

local function decorate_methods(instance, methods, fn)

    for _,method in pairs(methods) do
        local _original_method = instance[method]
        instance[method] = function(t, ...)
            local args = {...}
            local result = _original_method(t, table.unpack(args))

            return fn(t, result, table.unpack(args))

        end
    end

end

return {
    enhance_bridge_model = enhance_bridge_model,
    decorate_methods=decorate_methods
}