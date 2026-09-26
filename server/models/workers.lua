local Model = require("lapis.db.model").Model

-- Worker registry. Primary key is worker_id (a string, chosen by
-- the worker itself - "embedded", "worker-lua", etc), not the usual
-- auto-increment id.
return Model:extend("workers", {
    primary_key = "worker_id",
})
