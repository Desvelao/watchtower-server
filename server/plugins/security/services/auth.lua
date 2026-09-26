local M = {}

M.PROVIDERS = {
  jwt = require("plugins.security.services.auth_jwt"),
  api_key = require("plugins.security.services.auth_api_key"),
}

-- Utils
local function toboolean(v)
  if type(v) == "boolean" then
    return v
  end

  if type(v) == "string" then
    v = v:lower()
    if v == "true" then
      return true
    elseif v == "false" then
      return false
    end
  end

  if v then
    return true
  else
    return false
  end
end

local function includes(t, value)
  local result = false
  for k, v in pairs(t) do
    if t[k] == value then
      result = true
      break
    end
  end
  return result
end

function M.new(providers, get_user)
  local _providers = providers or {}
  local instance = {
    providers = {},
    get_user = get_user,
  }

  for k, v in pairs(_providers) do
    local provider_name = k
    local provider_type = v.type or provider_name
    local provider = M.PROVIDERS[provider_type] and M.PROVIDERS[provider_type].new(v)

    if not provider then
      error(string.format("Auth provider not found for %s", k))
    end
    instance.providers[provider_name] = provider
  end
  return setmetatable(instance, { __index = M })
end

function M:get_provider(provider_name)
  local provider
  for k, v in pairs(self.providers) do
    if not provider and k == provider_name then
      provider = self.providers[k]
    end
  end

  if not provider then
    return nil, "Auth provider not found"
  end

  return provider, nil
end

function M:authenticate(provider_name, username, context, ...)
  local provider, err = self:get_provider(provider_name)

  if not provider then
    return nil, err
  end

  return provider:authenticate(username, context, ...)
end

function M:get_context_from_request(request, config)
  local data, err
  for k, v in pairs(self.providers) do
    if not data and (not config.providers or config.providers and includes(config.providers, k)) then
      data, err = self.providers[k]:get_context_from_request(request)
    end
  end

  if not data then
    return nil, "Missing Authorization"
  end

  return data, nil
end

function M:with(_config)
  local config = _config or {}
  return function(fn)
    return function(that)
      local payload, err = self:get_context_from_request(that, config)

      if config.require and not payload then
        return { status = 401, json = { error = "Unauthorized", message = err } }
      end

      local user = payload and payload.user and self.get_user(payload.user) or nil

      -- Checked live on every request (not just at login), so disabling an
      -- account takes effect immediately for any already-issued token/key.
      if user and user.enabled == false then
        return { status = 401, json = { error = "Unauthorized", message = "Account disabled" } }
      end

      that.auth = {
        is_authenticated = toboolean(payload),
        context = payload,
        user = user,
      }

      return fn(that)
    end
  end
end

return M
