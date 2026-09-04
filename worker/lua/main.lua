#!/usr/bin/env lua
-- Standalone scrape worker: polls the server's HTTP API for enabled
-- items, scrapes them, posts an observation back, and reports job status.
-- Ported from pibuzz's worker/lua/main.lua.

local Logger = require("logger")
local cjson_safe = require("cjson.safe")
local HTTP_PROVIDER = require("provider_http")
local worker_runner = require("worker_runner")
local worker_config_report = require("worker_config_report")

local config = worker_runner.build_config("standalone")
local scraper, capabilities = require("scraper_creator").new(config.sites)
config.capabilities = capabilities

if config.report_config then
  config.reportable_config_json =
    cjson_safe.encode(worker_config_report.build_reportable_config(config))
end

worker_runner({
  mode = "standalone",
  config = config,
  notify = HTTP_PROVIDER.new(config.server),
  scraper = scraper,
  logger_name = "price-monitor-worker",
  extra_ctx = {
    http_provider = HTTP_PROVIDER,
  },
})
