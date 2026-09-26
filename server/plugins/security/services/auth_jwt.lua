local jwt = require("resty.jwt")

local M = {}

function M.new(config)
  local _config = config or {}
  if not _config.jwt_secret then
    error("JWT secret is required")
  end
  local instance = {
    config = {
      jwt_secret = config.jwt_secret,
    },
  }
  return setmetatable(instance, { __index = M })
end

-- `user_id` is the users.id primary key, not the username - keeping the
-- identity carried through the whole auth chain (JWT payload, api_key
-- rows, users:find) numeric avoids the defect a bare stored username would
-- have: a rename would silently orphan it.
function M:authenticate(user_id, role)
  local payload = {
    sub = user_id,
    role = role,
    iat = os.time(),
    exp = os.time() + 86400,
  }

  return jwt:sign(self.config.jwt_secret, {
    header = { typ = "JWT", alg = "HS256" },
    payload = payload,
  })
end

function M:get_context_from_request(request)
  local auth = request.req
    and request.req.headers
    and request.req.headers["authorization"]
  if not auth then
    return nil, "Missing Authorization header"
  end

  local prefix = "Bearer "
  if auth:sub(1, #prefix) ~= prefix then
    return nil, "Invalid Authorization header format"
  end

  local token = auth:sub(#prefix + 1)
  local decoded = jwt:verify(self.config.jwt_secret, token)

  if not decoded.verified then
    return nil, "Invalid or expired token"
  end

  local payload = decoded.payload

  return {
    user = tonumber(payload.sub),
    auth_type = "jwt",
    role = payload.role,
  }
end

return M
