-- Tiny memoizing cache over observable types, mode-agnostic: the only thing
-- that differs between the standalone and embedded workers is `loader_fn`
-- (an HTTP GET vs. a direct model read) - see shared/watchtower_worker_core/provider_http.lua's
-- get_observable_type and server/workers/observe_pending_worker.lua's inline
-- loader for the two implementations.
local M = {}

-- How long (seconds) a loaded observable type is trusted before being
-- re-fetched - the same staleness bound the rule/policy caches use (see
-- provider_http.lua's RULE_CACHE_REFRESH_INTERVAL), so an edited
-- observation_schema takes effect without a worker restart.
M.DEFAULT_TTL = 60

-- loader_fn(id) -> (observable_type, nil) | (nil, err)
-- ttl (seconds, default M.DEFAULT_TTL); `false`/0 disables expiry.
function M.new(loader_fn, ttl)
  if ttl == nil then
    ttl = M.DEFAULT_TTL
  end
  return setmetatable({ _loader = loader_fn, _ttl = ttl, _cache = {} }, { __index = M })
end

-- A failed lookup is never cached, so a transient failure retries on the
-- next call. If a refresh of an already-cached (expired) entry fails, the
-- stale entry keeps being served rather than failing the observe over a
-- transient blip - it's retried on the next call.
function M:get(id)
  local entry = self._cache[id]
  local now = os.time()
  if entry and (not self._ttl or self._ttl == 0 or (now - entry.at) < self._ttl) then
    return entry.value
  end

  local observable_type, err = self._loader(id)
  if not observable_type then
    if entry then
      return entry.value
    end
    return nil, err
  end

  self._cache[id] = { value = observable_type, at = now }
  return observable_type
end

-- Drops every cached entry, forcing the next get() of each id to reload.
function M:invalidate()
  self._cache = {}
end

return M
