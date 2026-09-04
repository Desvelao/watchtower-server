local kdf = require("resty.openssl.kdf")
local random = require("resty.random")
local secure_compare = require("plugins.security.services.secure_compare")

local M = {}

-- scrypt cost parameters. N=16384 (2^14), r=8, p=1 needs ~16MiB of working
-- memory (128*N*r bytes) - scrypt_maxmem must be raised above OpenSSL's
-- ~1MiB EVP_PBE_scrypt default or derivation fails with "memory limit
-- exceeded". This only runs on login/user-create/password-reset, never on
-- every request, so the cost is acceptable.
local SCRYPT_N = 16384
local SCRYPT_R = 8
local SCRYPT_P = 1
local SCRYPT_MAXMEM = 64 * 1024 * 1024
local OUTLEN = 32

local function derive(password, salt, n, r, p)
  return kdf.derive({
    type = kdf.SCRYPT,
    pass = password,
    salt = salt,
    scrypt_N = n,
    scrypt_r = r,
    scrypt_p = p,
    scrypt_maxmem = SCRYPT_MAXMEM,
    outlen = OUTLEN,
  })
end

-- Encodes as a self-describing string ("scrypt$n=..,r=..,p=..$<b64
-- salt>$<b64 hash>") so cost parameters can be tuned later without
-- invalidating already-stored hashes - M.verify always re-derives with the
-- parameters read back out of the stored string, never today's constants.
function M.hash(password)
  local salt = random.bytes(16, true)
  local digest, err = derive(password, salt, SCRYPT_N, SCRYPT_R, SCRYPT_P)
  if not digest then
    return nil, "Failed to hash password: " .. tostring(err)
  end

  return string.format(
    "scrypt$n=%d,r=%d,p=%d$%s$%s",
    SCRYPT_N,
    SCRYPT_R,
    SCRYPT_P,
    ngx.encode_base64(salt),
    ngx.encode_base64(digest)
  )
end

function M.verify(password, encoded)
  if type(password) ~= "string" or type(encoded) ~= "string" then
    return false
  end

  local algo, params, salt_b64, hash_b64 = encoded:match("^(%w+)%$([^$]+)%$([^$]+)%$([^$]+)$")
  if algo ~= "scrypt" then
    return false
  end

  local n, r, p = params:match("^n=(%d+),r=(%d+),p=(%d+)$")
  if not n then
    return false
  end

  local salt = ngx.decode_base64(salt_b64)
  local stored_hash = ngx.decode_base64(hash_b64)
  if not salt or not stored_hash then
    return false
  end

  local digest, err = derive(password, salt, tonumber(n), tonumber(r), tonumber(p))
  if not digest then
    return false
  end

  return secure_compare.equals(digest, stored_hash)
end

return M
