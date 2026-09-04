local config = require("lapis.config")
local user = os.getenv("POSTGRES_USER")
local password = os.getenv("POSTGRES_PASSWORD")
local database = os.getenv("POSTGRES_DB")
local host = os.getenv("POSTGRES_HOST")
local port = os.getenv("POSTGRES_PORT")

config("development", {
  server = "nginx",
  code_cache = "off",
  num_workers = "1",
  port = 8080,
	postgres = {
    host = host,
    port = port,
    user = user,
    password = password,
    database = database
  }
})

config("production", {
  server = "nginx",
  code_cache = "on",  -- Enable code caching for performance
  num_workers = 4,  -- Number of worker processes
  port = 8080,  -- Default HTTP port
  postgres = {
    host = host,
    port = port,
    user = user,
    password = password,
    database = database
  }
})