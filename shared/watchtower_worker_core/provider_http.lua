local http = require("socket.http")
local ltn12 = require("ltn12")
local cjson_safe = require("cjson.safe")
local Logger = require("watchtower_worker_core.logger")

-- Percent-encodes a query-string component (RFC 3986 unreserved chars pass
-- through unchanged).
local function url_encode(value)
  return (tostring(value):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Builds a "?k=v&k2=v2" query string from a params table: keys sorted (so a
-- given call always produces the same URL), every key/value percent-encoded,
-- nil values skipped. Returns "" when there are no params.
local function query_string(params)
  local keys = {}
  for key, value in pairs(params or {}) do
    if value ~= nil then
      table.insert(keys, key)
    end
  end
  if #keys == 0 then
    return ""
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    table.insert(parts, url_encode(key) .. "=" .. url_encode(params[key]))
  end
  return "?" .. table.concat(parts, "&")
end

-- unwrap function for calls where only success matters.
local function succeeded()
  return true
end

-- Retriever class

-- Wraps a page loader into a one-item-at-a-time generator: each call returns
-- the next cached item, refilling the cache from loader_fn(...) when it runs
-- dry. Returns nil when the loader is exhausted (or an empty page), and
-- (nil, err) when it fails.
local function make_cached_generator(loader_fn)
  local cache = {}

  return function(...)
    if #cache == 0 then
      local items, err = loader_fn(...)
      if err then
        return nil, err
      end
      if items == nil then
        return nil
      end
      for _, item in ipairs(items) do
        table.insert(cache, item)
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
    logger = Logger.new("provider_http", config.log_level),
    config = config,
    started_at = os.time(),
    context = {
      from = 0,
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
      url = self.config.server.base_url:gsub("/+$", "") .. path,
      method = method or "GET",
      source = req_body and ltn12.source.string(req_body) or nil,
      sink = ltn12.sink.table(resp_body),
      headers = req_headers,
      timeout = 10,
    })
  end)

  -- pcall failing means http.request itself raised (`res` is the error); a
  -- plain transport failure (refused, timeout, DNS) instead returns
  -- `nil, reason` from LuaSocket, so `code` holds the reason then.
  if not ok then
    return nil, "http request failed: " .. tostring(res)
  end
  if not res then
    return nil, "http request failed: " .. tostring(code)
  end

  local body_str = table.concat(resp_body)
  local code_as_number = tonumber(code)
  self.logger.debug(
    string.format("%s => [code=%s] [body=%s]", log_id, tostring(code), body_str)
  )

  if code_as_number == 401 then
    return nil, "Authentication error"
  end

  -- Content-Type may carry parameters (`application/json; charset=utf-8`),
  -- so match the media type rather than the whole header value.
  local content_type = resp_headers and resp_headers["content-type"] or ""
  local decoded_body = body_str
  local decode_err
  if content_type:find("application/json", 1, true) then
    local decoded, err = cjson_safe.decode(body_str)
    if decoded == nil then
      decode_err = err
    else
      decoded_body = decoded
    end
  end

  if code_as_number and code_as_number >= 400 then
    -- Surface the server's own explanation when it sent one (Lapis routes
    -- answer errors as `{message = ...}`).
    local detail = type(decoded_body) == "table" and (decoded_body.message or decoded_body.error) or nil
    return nil,
      "http status " .. tostring(code_as_number) .. " " .. tostring(status)
        .. (detail and (": " .. tostring(detail)) or "")
  end

  if decode_err then
    return nil, "json decode error: " .. tostring(decode_err)
  end

  return decoded_body, nil
end

function M:_request_with_auth(method, path, body, headers)
  local valid, verr = self:validate()
  if not valid then
    return nil, verr
  end

  local _headers = {
    ["x-api-key"] = self.config.server.api_key,
  }

  for k, v in pairs(headers or {}) do
    _headers[k] = v
  end

  return self:_request(method, path, body, _headers)
end

-- Authenticated request + response unwrapping + error decoration - the one
-- place every simple API method below goes through, so none of them repeats
-- the request / `if not response` / unwrap dance. opts:
--   body   - table, JSON-encoded as the request body
--   unwrap - a field name of the response's JSON envelope to return (e.g.
--            "item"/"items"), or a function(response) -> value; omitted
--            returns the whole decoded response
--   err    - failure prefix ("failed to fetch observable type"): the
--            failure is returned as "<prefix>: <cause>"
-- Returns (value, nil) on success (`value` may be nil/false when the
-- envelope simply doesn't carry one), or (nil, err) on failure.
function M:_call(method, path, opts)
  opts = opts or {}
  local response, err = self:_request_with_auth(method, path, opts.body)
  if not response then
    return nil, opts.err and (opts.err .. ": " .. tostring(err)) or err
  end
  local unwrap = opts.unwrap
  if type(unwrap) == "string" then
    return response[unwrap], nil
  elseif type(unwrap) == "function" then
    return unwrap(response), nil
  end
  return response, nil
end

-- PUT /api/jobs/:type/:ref_id/:verb (triggering|ack|error) with this
-- worker's id merged into `fields` - the one shape every job report shares.
function M:_job_report(type_, ref_id, verb, fields)
  local body = { worker_id = self.config.worker_id }
  for key, value in pairs(fields or {}) do
    body[key] = value
  end
  return self:_request_with_auth(
    "PUT",
    string.format("/api/jobs/%s/%s/%s", tostring(type_), tostring(ref_id), verb),
    body
  )
end

-- One page of a from/size-paginated list route (`path` e.g.
-- "/api/observables", `params` its extra filters), advancing `context.from`
-- - the cursor lives in an explicit `context` table so a caller that needs
-- its OWN independent pagination cursor (see the new_*_pager functions
-- below) doesn't share/corrupt M.next's (self.context). Returns (items, nil),
-- (nil) once exhausted (an empty page also resets the cursor, so the next
-- call starts a fresh sweep), or (nil, err). `what` names the resource in
-- errors.
--
-- No cooldown/backoff query param exists yet (see
-- observe_pending_worker.lua's get_pending_observable comment - same
-- simplification on both workers), so a sweep just paginates through every
-- matching row on each full pass.
function M:_fetch_page(context, path, params, what)
  local page_params = { from = context.from, size = self.config.server.batch_size }
  for key, value in pairs(params or {}) do
    page_params[key] = value
  end
  local uri = path .. query_string(page_params)

  local response, err = self:_request_with_auth("GET", uri)
  if not response then
    return nil, "fetch " .. what .. " failed: " .. tostring(err)
  end

  local items = response.items
  if type(items) ~= "table" or #items == 0 then
    context.from = 0
    return nil
  end

  self.logger.info(
    string.format("GET %s => [items=%d] [total=%s]", uri, #items, tostring(response.total_items))
  )
  context.from = context.from + #items
  return items, nil
end

-- M.next's page loader: the enabled observables, from `context` (default
-- self.context, M.next's own cursor).
function M:_fetch_observable_batch(context)
  return self:_fetch_page(context or self.context, "/api/observables", { enabled = "true" }, "observables")
end

-- Hands out a fresh, independent pagination cursor for a full drain of
-- every currently enabled observable - deliberately NOT self.context/
-- M.next's own cursor, so this can run concurrently with observer's own
-- interval-mode polling (which does use M.next) on the same worker process
-- without corrupting either drain's pagination. Returns a generator: each
-- call returns the next page's items array, or nil once exhausted - same
-- (page, err) contract _fetch_observable_batch already has. Used by
-- shared/watchtower_worker_core/processors.lua's do_run_interval_analyze_all
-- (analyzer.source = "interval").
function M:new_enabled_observables_pager()
  local context = { from = 0 }
  return function()
    return self:_fetch_observable_batch(context)
  end
end

-- POST /api/observations only - no job report. Used by both
-- observer.source = "queue" (do_run_pending_observe_batch, one call per
-- observable in a claimed batch) and observer.source = "interval"
-- (shared/watchtower_worker_core/processors.lua's process_observable, via
-- ctx.post_observation) - neither creates/updates a per-observable `jobs`
-- row for this.
function M:post_observation(observable, observation_result)
  local ok, err = self:_request_with_auth("POST", "/api/observations", {
    id = observable.id,
    timestamp = os.date("!%Y-%m-%d %H:%M:%S"),
    worker_id = self.config.worker_id,
    properties = observation_result,
  })
  if not ok then
    return nil, "failed to post observation: " .. tostring(err)
  end
  return ok, nil
end

-- Unwraps the route's {item = ...} envelope (see
-- server/plugins/entities/observable_types_routes.lua). The returned item's
-- properties/observation_schema are already decoded arrays - no further
-- jsonb decode needed client-side, cjson_safe already parsed the whole JSON
-- response body in :_request.
function M:get_observable_type(id)
  return self:_call("GET", "/api/observable_types/" .. tostring(id), {
    unwrap = "item",
    err = "failed to fetch observable type",
  })
end

-- watchtower_observer_web_scraper.observer_config_test_poller's `deps` for
-- the standalone worker's async test flow (type='observer_test') - see
-- worker/lua/main.lua. `worker_id` is required now: the server claims the
-- candidate atomically (inserting its own 'triggering' jobs row) as part of
-- resolving it, rather than handing out a still-unclaimed candidate for a
-- separate PUT to claim later (see server/plugins/observer_configs/
-- plugin.lua's own header comment on this route for why).
function M:next_observer_test()
  return self:_call("GET", "/api/observer_configs/test_requests/pending" .. query_string({ worker_id = self.config.worker_id }), {
    unwrap = "item",
    err = "failed to fetch pending observer config test",
  })
end

function M:observer_test_triggering(test_id)
  return self:_job_report("observer_test", test_id, "triggering")
end

function M:observer_test_ack(test_id, result)
  return self:_job_report("observer_test", test_id, "ack", { action = "tested", result = result })
end

function M:observer_test_error(test_id, message)
  return self:_job_report("observer_test", test_id, "error", { message = message })
end

-- Scoped to one observer_configs row by id (the list route already
-- supports an `id` query param) - used to resolve a `type='saved'` observer
-- config test request without fetching every row.
function M:get_observer_config(id)
  local row, err = self:_call("GET", "/api/observer_configs" .. query_string({ id = id }), {
    unwrap = function(response) return response.items and response.items[1] end,
    err = "failed to fetch observer config",
  })
  if err then
    return nil, err
  end
  if not row then
    return nil, "observer config not found: " .. tostring(id)
  end
  return row, nil
end

-- Already pre-reshaped to scraper_creator.new's `sites` entry shape by the
-- server (see server/plugins/observer_configs/plugin.lua's GET .../site) -
-- no further reshaping needed client-side.
-- observer_type isn't configured anywhere (see
-- server/lib/observer_type_catalog.lua's header comment - exactly one
-- observer type is implemented, so the server always resolves that one),
-- so this only ever needs to name the observable_type_id.
function M:list_observer_config_sites(observable_type_id)
  return self:_call("GET", "/api/observer_configs/site" .. query_string({
    observable_type_id = observable_type_id,
  }), {
    unwrap = "items",
    err = "failed to fetch observer config sites",
  })
end

-- "scheduler"-role tick: asks the server to evaluate every due
-- scheduler_tasks row and queue the resulting pending `jobs` rows - see
-- server/plugins/scheduler/services/scheduler.lua's fire_due.
-- Returns {fired}.
function M:fire_due_tasks()
  return self:_request_with_auth("PUT", "/api/scheduler/fire-due", {})
end

-- Housekeeping tick, called only for a "scheduler"-role worker (gating
-- happens at the call site, shared/watchtower_worker_core/processors.lua's
-- build_tasks/run_once): resets any `jobs` row stuck in
-- 'triggering' past `timeout_seconds` back to 'error' - see
-- server/plugins/jobs/services/jobs.lua's reap_stale and
-- shared/watchtower_worker_core/pollers/reap_stale.lua. Returns
-- {reaped, items}.
function M:reap_stale_jobs(timeout_seconds)
  return self:_request_with_auth("PUT", "/api/jobs/reap-stale", { timeout_seconds = timeout_seconds })
end

-- A role's priority pickup: atomically claims the oldest pending `jobs` row
-- of `type_` queued by a scheduler task firing (if any) - for `type_ =
-- "observe"`, ahead of the normal :next() stalest-observable polling. The
-- response already carries the full, freshly-resolved target for that
-- firing (`observables` for observe/analyze; for notify, the evaluation
-- outcome {enqueued, alerts_matched} - claiming already matched alerts
-- against notification_policies and enqueued the result onto
-- alert_deliveries server-side, see
-- server/plugins/scheduler/plugin.lua's PUT /claim route and
-- .../scheduler.lua's claim_next_batch) - no follow-up round trips needed.
-- Returns (item, nil) | (nil, nil) when nothing is pending | (nil, err) on
-- failure. Used by shared/watchtower_worker_core/processors.lua's
-- do_run_pending_observe_batch/do_run_pending_analyze_batch/
-- do_run_pending_evaluate_batch via the matching pollers/*.lua
-- (notify's own sending is a fully separate pipeline - see
-- :claim_deliveries/:report_deliveries below).
function M:claim_batch(type_)
  return self:_call("PUT", "/api/scheduler/claim", {
    body = { worker_id = self.config.worker_id, type = type_ },
    unwrap = "item",
    err = "failed to claim scheduled job",
  })
end

-- Reports the single aggregate result for one scheduler-fired batch job -
-- see shared/watchtower_worker_core/pollers/observe.lua/pollers/analyze.lua/
-- pollers/notify.lua. Mirrors :observer_test_ack's route shape
-- (PUT /api/jobs/:type/:ref_id/ack), with ref_id = the scheduler_tasks id
-- rather than an observable id, hence skip_rollup=true (see
-- plugins/jobs/services/jobs.lua's M:report header comment).
function M:report_batch_result(type_, task_id, action, message, result)
  return self:_job_report(type_, task_id, "ack", {
    action = action,
    message = message,
    result = result,
    skip_rollup = true,
  })
end

function M:report_batch_error(type_, task_id, message)
  return self:_job_report(type_, task_id, "error", { message = message, skip_rollup = true })
end

-- "deliver"-role work: claims a batch directly off the alert_deliveries
-- queue - fully independent of scheduler_tasks/jobs, unlike :claim_batch
-- above (see server/plugins/notification_channels/services/
-- delivery_queue.lua's claim_batch). Returns (item, nil) | (nil, nil) when
-- nothing is pending | (nil, err) on failure. Used by
-- shared/watchtower_worker_core/processors.lua's do_run_pending_notify_batch
-- via pollers/notify.lua.
function M:claim_deliveries()
  return self:_call("PUT", "/api/alert_deliveries/claim", {
    body = { worker_id = self.config.worker_id },
    unwrap = "item",
    err = "failed to claim deliveries",
  })
end

-- Reports each (alert, channel) delivery attempt's own outcome directly
-- onto its alert_deliveries row - see delivery_queue.lua's :report. No
-- `jobs` row involved at all, unlike :report_batch_result/:report_batch_error
-- above.
function M:report_deliveries(channel_results)
  return self:_request_with_auth(
    "PUT",
    "/api/alert_deliveries/report",
    { worker_id = self.config.worker_id, channel_results = channel_results }
  )
end

-- Housekeeping tick, called only for an "evaluator"-role worker (gating
-- happens at the call site, shared/watchtower_worker_core/plugins/evaluator.lua):
-- resets any `alert_deliveries` row stuck in 'triggering' past
-- `timeout_seconds` back to 'error' - see
-- server/plugins/notification_channels/services/delivery_queue.lua's
-- reap_stale and shared/watchtower_worker_core/pollers/reap_stale_deliveries.lua.
-- Returns {reaped, items}.
function M:reap_stale_deliveries(timeout_seconds)
  return self:_request_with_auth("PUT", "/api/alert_deliveries/reap-stale", { timeout_seconds = timeout_seconds })
end

-- "analyzer"-role work (see M:analyze_observable below): re-runs rule matching
-- against an observable's latest stored observation (no re-observe) and
-- creates any resulting alert(s) - all client-side, in this worker process,
-- via shared/watchtower_worker_core/worker_rule_matcher.lua (reusing the same
-- pure-Lua rule_engine.expr/engine matching core the server's own rule
-- engine uses). Only the DB-bound inputs/output - current rules, its latest
-- observation, recent-alert history for the cooldown check, and the alert
-- insert itself - go over HTTP, via the M:* methods below.

-- deps.load_rules for worker_rule_matcher.lua's rule_engine.engine instance
-- - engine.lua's own `load()` contract is a bare return, no (value, err)
-- pair, and any error should propagate as a Lua error (caught by
-- worker_rule_matcher's own pcall around :match()), so this raises rather
-- than returning nil+err like every other method here.
function M:list_enabled_rules()
  local rules, err = self:_call("GET", "/api/rules" .. query_string({ enabled = "true" }), {
    unwrap = function(response) return response.items or {} end,
    err = "failed to fetch rules",
  })
  if rules == nil then
    error(err)
  end
  return rules
end

-- deps.fetch_latest_observation: the most recent observation for
-- `observable_id`, or (nil, nil) if it has none yet (mirrors
-- reanalyze.lua's own graceful no-op).
function M:latest_observation(observable_id)
  return self:_call(
    "GET",
    "/api/observations" .. query_string({ observable_id = observable_id, sort = "timestamp:desc", size = 1 }),
    {
      unwrap = function(response) return response.items and response.items[1] or nil end,
      err = "failed to fetch latest observation",
    }
  )
end

-- deps.fetch_baseline (worker_rule_matcher.lua's "changed"/"changed_within"
-- support): the most recent observation for `observable_id` at or before
-- `before_timestamp`, excluding `exclude_id` (the observation currently
-- being analyzed - see shared/analyzer.lua's own fetch_baseline_properties
-- for why: at `seconds = 0`, before_timestamp equals that observation's own
-- timestamp, so without excluding it by id it would match itself instead of
-- a genuinely earlier row). Fetches size=2 and skips exclude_id client-side
-- rather than adding a server-side exclude-id query param - `timestamp_before`
-- is `<=`, so at most one of the top 2 rows can be the excluded one. Returns
-- the decoded `properties` table (matching shared/analyzer.lua's own
-- cjson_safe.decode(row.properties) return shape), or nil if none qualify.
function M:observation_baseline(observable_id, before_timestamp, exclude_id)
  local observations, err = self:_call(
    "GET",
    "/api/observations" .. query_string({
      observable_id = observable_id,
      timestamp_before = before_timestamp,
      sort = "timestamp:desc",
      size = 2,
    }),
    { unwrap = "items", err = "failed to fetch baseline observation" }
  )
  if err then
    return nil, err
  end
  for _, observation in ipairs(observations or {}) do
    if observation.id ~= exclude_id then
      return observation.properties, nil
    end
  end
  return nil, nil
end

-- Whether a GET /api/alerts query (always size=1) matches any alert.
-- (true|false, nil) | (nil, err) - the nil-vs-false distinction is what
-- fail_closed (below) keys off.
function M:_any_alert(params, err_prefix)
  params.size = 1
  return self:_call("GET", "/api/alerts" .. query_string(params), {
    unwrap = function(response) return response.items ~= nil and #response.items > 0 end,
    err = err_prefix,
  })
end

-- deps.has_alert_for_observation: true if this exact (rule_id,
-- observation_id) pair already has an alert - mirrors shared/analyzer.lua's
-- own already_alerted check, independent of cooldown_seconds. Uses the
-- already-existing rule_id/observation_id filters on GET /api/alerts (see
-- plugins/alerting/plugin.lua's fields_query_params) - no server change
-- needed.
function M:has_alert_for_observation(rule_id, observation_id)
  return self:_any_alert(
    { rule_id = rule_id, observation_id = observation_id },
    "failed to check existing alerts"
  )
end

-- deps.has_recent_alert (the cooldown check): true if an alert for
-- (rule_id, observable_id) was already created within the last
-- `cooldown_seconds`. nil/<=0 short-circuits to false with no request,
-- mirroring shared/analyzer.lua's own is_in_cooldown.
function M:has_recent_alert(rule_id, observable_id, cooldown_seconds)
  if not cooldown_seconds or cooldown_seconds <= 0 then
    return false, nil
  end
  local cutoff = os.date("!%Y-%m-%d %H:%M:%S", os.time() - cooldown_seconds)
  return self:_any_alert(
    { rule_id = rule_id, observable_id = observable_id, created_after = cutoff },
    "failed to check recent alerts"
  )
end

-- deps.create_alert: POST /api/alerts - see server/plugins/alerting/plugin.lua's
-- own header comment for why this exists as a narrow, validating create
-- rather than a general-purpose alerts write API.
function M:create_alert(fields)
  local ok, err = self:_call("POST", "/api/alerts", {
    body = fields,
    unwrap = succeeded,
    err = "failed to create alert",
  })
  if not ok then
    return false, err
  end
  return true, nil
end

-- deps.load_policies for notification_policy_matcher.lua's rule_engine.engine
-- instance - mirrors M:list_enabled_rules's own raise-rather-than-nil+err
-- convention exactly, for the same reason (engine.lua's `load()` contract).
function M:list_enabled_notification_policies()
  local policies, err = self:_call("GET", "/api/notification_policies" .. query_string({ enabled = "true" }), {
    unwrap = function(response) return response.items or {} end,
    err = "failed to fetch notification policies",
  })
  if policies == nil then
    error(err)
  end
  return policies
end

-- deps.new_candidate_alerts_pager for notification_policy_matcher.lua: a
-- fresh generator over every alert that still needs a delivery
-- (GET /api/alerts?needs_delivery=true). Each call returns the next page's
-- items array, nil once exhausted, or (nil, err) on a failed fetch.
--
-- Keyset-paged (`after_id` + `sort=id:asc`), not offset-paged like
-- M:new_enabled_observables_pager: the matcher enqueues deliveries WHILE
-- draining this set, and each enqueue removes that alert from it, so an
-- offset cursor would skip rows. The cursor is local to the generator, so a
-- new pass always starts from the beginning.
function M:new_needs_delivery_alerts_pager()
  local after_id
  return function()
    local alerts, err = self:_call(
      "GET",
      "/api/alerts" .. query_string({
        needs_delivery = "true",
        after_id = after_id,
        sort = "id:asc",
        size = self.config.server.batch_size,
      }),
      { unwrap = "items", err = "fetch alerts failed" }
    )
    if err then
      return nil, err
    end
    if type(alerts) ~= "table" or #alerts == 0 then
      return nil
    end
    after_id = alerts[#alerts].id
    return alerts, nil
  end
end

-- deps.enqueue_delivery: POST /api/alert_deliveries - see
-- server/plugins/notification_channels/plugin.lua's own header comment for
-- why this exists as a narrow, validating create rather than a
-- general-purpose write, mirroring M:create_alert's identical precedent.
-- Returns (true, nil) if a delivery row was inserted/reset for retry,
-- (false, nil) if an existing non-error row was left untouched (already
-- pending/triggering/sent), (nil, err) on failure.
function M:enqueue_delivery(alert_id, channel_id)
  return self:_call("POST", "/api/alert_deliveries", {
    body = { alert_id = alert_id, channel_id = channel_id },
    unwrap = function(response) return response.enqueued == true end,
    err = "failed to enqueue delivery",
  })
end

-- Lazily built once per provider instance and reused across every
-- :analyze_observable call, rather than rebuilt per call - avoids an extra
-- GET /api/rules round trip per observable in a batch/interval drain.
-- worker_rule_matcher's own rule_engine.engine caches its compiled AST list
-- internally after the first :match() (see rule_engine.engine's own
-- :invalidate() header comment) and, left alone, would never see a rule
-- created/edited/deleted after that first call for the life of this
-- process - the same staleness problem server/workers/observe_pending_worker.lua's
-- own long-lived rule_engine instance has, solved there by a periodic
-- rule_engine:invalidate() on a timer (start_rule_engine_refresh,
-- ENGINE_CACHE_REFRESH_INTERVAL = 60s). This worker has no timer/thread
-- primitive of its own, so the same bound is enforced inline here instead:
-- :invalidate() is called if more than RULE_CACHE_REFRESH_INTERVAL seconds
-- have passed since the matcher was last (re)built, right before handing it
-- back - cheap (a plain os.time() check on every call), and bounds a rule
-- edit's worst-case staleness to that interval, same as the embedded
-- worker's own bound.
local RULE_CACHE_REFRESH_INTERVAL = 60

-- Wraps a `(result, err)` existence check so a failure (result == nil)
-- RAISES instead of being read as "no": treating "couldn't check" as "not in
-- cooldown / not alerted yet, create anyway" would flood duplicate alerts
-- during a network blip. The raise is caught by whichever caller pcalls
-- analyze_observable (pollers/analyze.lua, do_run_interval_analyze_all),
-- which reports that one observable as failed rather than crashing the whole
-- pass - the same reliance shared/analyzer.lua has on its callers for DB
-- failures.
local function fail_closed(check)
  return function(...)
    local result, err = check(...)
    if result == nil then
      error(err)
    end
    return result
  end
end

function M:_get_rule_matcher()
  if self._rule_matcher and (os.time() - self._rule_matcher_built_at) >= RULE_CACHE_REFRESH_INTERVAL then
    self._rule_matcher:invalidate()
    self._rule_matcher_built_at = os.time()
  end
  if not self._rule_matcher then
    self._rule_matcher_built_at = os.time()
    self._rule_matcher = require("watchtower_worker_core.worker_rule_matcher").new({
      load_rules = function() return self:list_enabled_rules() end,
      fetch_latest_observation = function(observable_id) return self:latest_observation(observable_id) end,
      -- reference_timestamp is a "YYYY-MM-DD HH:MM:SS" UTC string (the
      -- observation's own `timestamp`, same format M:post_observation
      -- writes) - parsed via rule_engine.iso_date (deliberately NOT
      -- os.time(), which interprets a date TABLE as the process's LOCAL
      -- timezone; iso_date.parse always treats it as UTC, matching how it
      -- was written) into epoch seconds, subtracts `seconds`, then
      -- re-formats via os.date's `!` (UTC) flag - safe/portable regardless
      -- of the container's local timezone. Mirrors shared/analyzer.lua's
      -- own SQL equivalent: (?::timestamp - (? * INTERVAL '1 second')).
      fetch_baseline = function(observable_id, reference_timestamp, seconds, exclude_id)
        local epoch, parse_err = require("rule_engine.iso_date").parse(reference_timestamp)
        if not epoch then
          self.logger.warn("failed to parse observation timestamp for baseline lookup: " .. tostring(parse_err))
          return nil
        end
        local cutoff = os.date("!%Y-%m-%d %H:%M:%S", epoch - seconds)
        return self:observation_baseline(observable_id, cutoff, exclude_id)
      end,
      -- Both existence checks fail CLOSED (see fail_closed above).
      has_alert_for_observation = fail_closed(function(rule_id, observation_id)
        return self:has_alert_for_observation(rule_id, observation_id)
      end),
      has_recent_alert = fail_closed(function(rule_id, observable_id, cooldown_seconds)
        return self:has_recent_alert(rule_id, observable_id, cooldown_seconds)
      end),
      create_alert = function(fields) return self:create_alert(fields) end,
      -- ERROR, not WARN: an alert silently failing to fire is a real
      -- failure, not a warning - matches the embedded worker's own severity
      -- for this same failure class (server/workers/observe_pending_worker.lua's
      -- analyzer.new(..., worker_logger.error)).
      log_error = function(message) self.logger.error(message) end,
    })
  end
  return self._rule_matcher
end

-- Re-runs rule matching against `observable`'s latest stored observation (no
-- re-observe). `observable` is a full observable row - what a scheduler claim
-- and the enabled-observables pager already return, so no GET per observable
-- is needed to look it up.
function M:analyze_observable(observable)
  -- Cached (TTL'd) so a full analyze sweep doesn't re-GET the same
  -- observable type once per observable.
  if not self._observable_types then
    self._observable_types = require("watchtower_worker_core.observable_type_cache").new(function(id)
      return self:get_observable_type(id)
    end)
  end
  local observable_type, observable_type_err = self._observable_types:get(observable.observable_type_id)
  if not observable_type then
    return nil, "failed to analyze observable: " .. tostring(observable_type_err)
  end

  local matches, ok = self:_get_rule_matcher():analyze_observable(observable.id, {
    observable_name = observable.name,
    observable_type_name = observable_type.name,
  })
  return { matches = #matches, ok = ok }, nil
end

-- Lazily built once per provider instance. Unlike the rule matcher above
-- there's no staleness bound to enforce here: the matcher re-reads the
-- enabled policies itself at the start of every pass.
function M:_get_policy_matcher()
  if not self._policy_matcher then
    self._policy_matcher = require("watchtower_worker_core.notification_policy_matcher").new({
      load_policies = function() return self:list_enabled_notification_policies() end,
      new_candidate_alerts_pager = function() return self:new_needs_delivery_alerts_pager() end,
      enqueue_delivery = function(alert_id, channel_id) return self:enqueue_delivery(alert_id, channel_id) end,
      log_error = function(message) self.logger.warn(message) end,
    })
  end
  return self._policy_matcher
end

-- "evaluator" role's whole job, both "queue" mode (per
-- claimed notify task, scoped to its `policy_ids`) and "interval" mode (every
-- enabled policy): drains every currently "needs delivery" alert, matches
-- each against the enabled policies, and enqueues the resulting deliveries -
-- all client-side (see notification_policy_matcher.lua's own header comment
-- for why this never delegates to a server-side "evaluate" endpoint).
-- Returns ({enqueued, alerts_matched}, ok) - `ok` false = the pass only
-- partly completed.
function M:evaluate_notify_policies(policy_ids)
  return self:_get_policy_matcher():evaluate_and_enqueue(policy_ids)
end

function M:heartbeat(fields)
  return self:_request_with_auth(
    "PUT",
    "/api/workers/" .. tostring(self.config.worker_id) .. "/heartbeat",
    {
      connection_type = fields.connection_type,
      version = fields.version,
      capabilities = fields.capabilities,
      uptime_seconds = fields.uptime_seconds,
      config = fields.config,
      roles = fields.roles,
      properties = fields.properties,
    }
  )
end

function M:validate()
  if not self.config or not self.config.server then
    return false, "Configuration not provided"
  end
  if not self.config.server.base_url or self.config.server.base_url == "" then
    return false, "server.address is required"
  end
  if not self.config.server.api_key or self.config.server.api_key == "" then
    return false, "SERVER_API_KEY is required"
  end
  return true, nil
end

M.next = make_cached_generator(function(self)
  return self:_fetch_observable_batch()
end)

return M
