local Model = require("lapis.db.model").Model
local decorate_methods = require("lib.models").decorate_methods

local m, mt = Model:extend("scraper_remote_sites")

local function get_from_db_prop(selector, prop)

  local extra = ''

  if prop then
    extra = '_' .. prop
  end

  return 'fields_' .. selector .. extra
end

function m:include_options_in(records)
    for _,record in ipairs(records) do
      record.fields = {
        price={
          selector=record[get_from_db_prop('price', 'selector')],
          transform=record[get_from_db_prop('price', 'transform')],
          validate=record[get_from_db_prop('price', 'validate')]
        },
        discount={
          selector=record[get_from_db_prop('discount', 'selector')],
          transform=record[get_from_db_prop('discount', 'transform')],
          validate=record[get_from_db_prop('discount', 'validate')]
        },
        available={
          selector=record[get_from_db_prop('available', 'selector')],
          transform=record[get_from_db_prop('available', 'transform')],
          validate=record[get_from_db_prop('available', 'validate')]
        }
      }

      for _,v in ipairs({'price', 'discount', 'available'}) do
        record['fields_' .. v ..'_selector'] = nil
        record['fields_' .. v ..'_transform'] = nil
        record['fields_' .. v ..'_validate'] = nil
      end
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
