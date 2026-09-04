local http = require("socket.http")
local ltn12 = require("ltn12")
local cjson_safe = require("cjson.safe")
local Logger = require("logger")

-- Retriever class

local function make_cached_generator(loader_fn)
  if type(loader_fn) ~= "function" then
    error("make_cached_generator expects a function", 2)
  end

  local cache = {}

  return function(...)
    while #cache == 0 do
      local items, err = loader_fn(...)
      if err then
        return nil, err
      end
      if items == nil then
        return nil
      end
      if type(items) ~= "table" then
        table.insert(cache, items)
      else
        for _, item in ipairs(items) do
          table.insert(cache, item)
        end
      end
      if #cache == 0 then
        return nil
      end
    end

    return table.remove(cache, 1)
  end
end

local M = {}

function M.new(config)
  local _instance = {
    logger = Logger.new("provider_http"),
    config = config,
    started_at = os.time(),
    context = {
      from = 0,
      total = nil,
    },
  }

  local instance = setmetatable(_instance, { __index = M })

  return instance
end

function M:_request(method, path, body, headers)
  local log_id = string.format("[%s %s]", method:upper(), path)
  local req_body = body and type(body) == "table" and cjson_safe.encode(body)
    or nil
  local resp_body = {}
  self.logger.debug(log_id)

  local req_headers = {}
  for k, v in pairs(headers or {}) do
    req_headers[k] = v
  end
  if req_body then
    -- Without this, the server's json_params middleware never parses the
    -- body (it only decodes JSON when Content-Type says so), so any
    -- params sent in the body silently come through as missing.
    req_headers["Content-Type"] = "application/json"
    req_headers["Content-Length"] = tostring(#req_body)
  end

  local ok, res, code, resp_headers, status = pcall(function()
    return http.request({
      url = self.config.base_url:gsub("/+$", "") .. path,
      method = method or "GET",
      source = req_body and ltn12.source.string(req_body) or nil,
      sink = ltn12.sink.table(resp_body),
      headers = req_headers,
      timeout = 10,
    })
  end)

  self.logger.debug(
    string.format(
      "%s => [code=%s] [headers=%s]",
      log_id,
      code,
      cjson_safe.encode(resp_headers)
    )
  )

  if not res then
    return nil, "http request failed"
  end

  local body_str = table.concat(resp_body)
  self.logger.debug(string.format("%s => Decoding body", log_id))

  local body = body_str

  if resp_headers and resp_headers["content-type"] == "application/json" then
    local decoded, err = cjson_safe.decode(body_str)
    if not decoded then
      return nil, "json decode error: " .. tostring(err)
    end
    body = decoded
  end

  self.logger.debug(
    string.format(
      "%s => [code=%s] [headers=%s] [body=%s]",
      log_id,
      code,
      cjson_safe.encode(resp_headers),
      body_str
    )
  )

  local code_as_number = tonumber(code)

  if code_as_number == 401 then
    return nil, "Authentication error"
  end

  if code_as_number >= 400 then
    return nil,
      "http status " .. tostring(code_as_number) .. " " .. tostring(status)
  end

  return body, nil
end

function M:_request_with_auth(method, path, body, headers)
  local valid, verr = self:validate()
  if not valid then
    return nil, verr
  end

  local _headers = {
    ["x-api-key"] = self.config.api_key,
  }

  if headers then
    for k, v in pairs(headers) do
      _headers[k] = headers[k]
    end
  end

  return self:_request(method, path, body, _headers)
end

function M:_reset_context()
  self.context.from = 0
  self.context.total = nil
end

-- No cooldown/backoff query param exists yet (see
-- scrape_pending_worker.lua's get_pending_item comment - same
-- simplification on both workers), so this just paginates through every
-- enabled item on each full pass.
function M:_fetch_item_batch()
  self.logger.debug("Fetching batch...")
  if not self.config.api_key then
    return nil, "API key is not configured"
  end

  local method = "GET"
  local path = string.format(
    "/api/items?enabled=true&from=%s&size=%s",
    tostring(self.context.from),
    tostring(self.config.batch_size)
  )

  local log_id = string.format("[%s %s]", method:upper(), path)
  self.logger.debug(string.format("%s => Fetching", log_id))

  local pending_items, err = self:_request_with_auth(method, path, nil, {
    ["Accept"] = "application/json",
  })

  if not pending_items then
    return nil, "fetch items failed: " .. tostring(err)
  end

  local items = pending_items.items
  if type(items) ~= "table" or #items == 0 then
    self:_reset_context()
    return nil
  end
  local total_items = pending_items.total_items
  self.logger.info(
    string.format("%s => [items=%d] [total=%d]", log_id, #items, total_items)
  )

  self.context.from = self.context.from + #items
  self.context.total = total_items

  if self.context.total and self.context.from >= self.context.total then
    self:_reset_context()
  end

  return items, nil
end

function M:processing(item)
  return self:_request_with_auth(
    "PUT",
    "/api/jobs/scrape/" .. tostring(item.id) .. "/triggering",
    { monitor_id = self.config.monitor_id }
  )
end

function M:complete(item, action, message, scrape_result)
  local ok, err = self:_request_with_auth("POST", "/api/observations", {
    id = item.id,
    price = scrape_result and scrape_result.price,
    discount = scrape_result and scrape_result.discount,
    available = scrape_result and scrape_result.available,
    url = (scrape_result and scrape_result.url) or item.url,
    timestamp = os.date("!%Y-%m-%d %H:%M:%S"),
  })
  if not ok then
    return nil, "failed to post observation: " .. tostring(err)
  end

  return self:_request_with_auth(
    "PUT",
    "/api/jobs/scrape/" .. tostring(item.id) .. "/ack",
    {
      monitor_id = self.config.monitor_id,
      action = action,
      message = message,
    }
  )
end

function M:error(item, message)
  return self:_request_with_auth(
    "PUT",
    "/api/jobs/scrape/" .. tostring(item.id) .. "/error",
    { monitor_id = self.config.monitor_id, message = message }
  )
end

function M:heartbeat(fields)
  return self:_request_with_auth(
    "PUT",
    "/api/monitors/" .. tostring(self.config.monitor_id) .. "/heartbeat",
    {
      connection_type = fields.connection_type,
      version = fields.version,
      capabilities = fields.capabilities,
      item_filter = fields.item_filter,
      uptime_seconds = fields.uptime_seconds,
      config = fields.config,
    }
  )
end

function M:validate()
  if not self.config then
    return false, "Configuration not provided"
  end
  if not self.config.base_url or self.config.base_url == "" then
    return false, "server.address is required"
  end
  if not self.config.api_key or self.config.api_key == "" then
    return false, "SERVER_API_KEY is required"
  end
  return true, nil
end

M.next = make_cached_generator(function(self)
  return self:_fetch_item_batch()
end)

return M
