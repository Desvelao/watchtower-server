local Model = require("lapis.db.model").Model

return Model:extend("scheduler_tasks", {
    relations = {
        {"observable_type", belongs_to = "ObservableTypes", key = "observable_type_id"}
    }
})
