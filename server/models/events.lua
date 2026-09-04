local Model = require("lapis.db.model").Model

return Model:extend("events", {
    relations = {
        { "item", belongs_to = "items" },
    },
})
