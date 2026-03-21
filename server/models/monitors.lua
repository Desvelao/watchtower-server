local Model = require("lapis.db.model").Model

return Model:extend("monitoring", {
    relations={
        {"items", belongs_to="Items", key="item_id"}
    }
})