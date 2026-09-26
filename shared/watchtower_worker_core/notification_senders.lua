-- Sends a group of alerts to one notification_channels row - the first
-- outbound-notification code in this codebase (notification_channels was,
-- until now, pure CRUD over channel *definitions*; see
-- plugins/notification_channels/services/notification_policy_engine.lua for
-- how a channel gets matched to an alert in the first place). No DB access,
-- only outbound HTTP - delegated to `pling` (github.com/Desvelao/pling, a
-- published LuaRocks package - see dev/docker-compose.yml for the
-- sibling-repo mount used only for local iteration on unpublished changes).
-- One call per channel per firing, but one OUTBOUND MESSAGE PER ALERT in
-- that group (not one aggregate message) - this is what lets a channel's
-- message/body template interpolate a single alert's own fields
-- (`{{alert.id}}`, `{{alert.item_name}}`, ...) instead of a predefined
-- batch summary. Still a low-volume, admin-configured tool.
--
-- Only the specific notifiers actually needed are required directly
-- (never top-level `require("pling")`, whose init.lua eagerly loads
-- every notifier - audio/gpio/mqtt/email included - pulling in deps
-- (luamqtt, luabitop, ...) neither worker image installs).
--
-- The one thing that differs between the standalone and embedded workers
-- is the outbound HTTP transport itself: pling's own
-- webhook_transport.lua (LuaSocket/LuaSec-based) works fine in the
-- standalone worker's plain Lua 5.1 process, but LuaSocket/LuaSec cannot
-- run inside an nginx worker process (ngx_lua breaks LuaSocket's real,
-- blocking socket.tcp() there by design) - the embedded worker needs
-- server/lib/resty_webhook_transport.lua (lua-resty-http-based) instead.
-- Mirroring shared/watchtower_worker_core/observable_type_cache.lua's/shared/analyzer.lua's own
-- dependency-injection convention for this exact kind of runtime
-- difference, M.new(transport) builds an instance from any given
-- transport; M.send is a default instance built from pling's own
-- transport, so the standalone worker's call site
-- (shared/watchtower_worker_core/processors.lua) needs no changes, while the embedded
-- worker's call site (server/workers/observe_pending_worker.lua) builds
-- its own instance with the resty-based transport instead.
local pling_discord = require("pling.notifiers.discord")
local pling_webhook = require("pling.notifiers.webhook")
local pling_webhook_transport = require("pling.notifiers.webhook_transport")
local pling_email = require("pling.notifiers.email")
local cjson_safe = require("cjson.safe")

-- Escapes a Lua string for safe embedding inside a JSON string literal
-- (`"`, `\`, and control characters per JSON's own string grammar - RFC
-- 8259 section 7). Neither cjson nor cjson.safe exposes a standalone
-- string-escaping helper (only whole-value `encode`/`decode`), so this is
-- a small hand-rolled one, used only by render_template's `escape` param
-- below - specifically by SENDERS.webhook, the one sender that round-trips
-- its rendered template back through cjson_safe.decode (see that sender's
-- own header comment).
local JSON_ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
}
local function json_escape(str)
  return (str:gsub('[%c"\\]', function(c)
    return JSON_ESCAPES[c] or string.format('\\u%04x', c:byte())
  end))
end

-- Replaces `{{token}}` placeholders in `template` with values from `vars`
-- (a {token = string} table, one level of dot-nesting allowed - e.g.
-- `{{alert.id}}` looks up vars.alert.id) - deliberately minimal, no
-- conditionals or loops, mirroring this project's other hand-rolled small
-- template/parsing needs (see shared/rule_engine/source.lua's own
-- header comment on scope). A missing key (at any step of a dotted path)
-- renders as "". `escape` is an optional function applied to each
-- substituted value's string form before it's spliced into the template -
-- e.g. `json_escape` above, when the rendered template will itself be
-- parsed back as JSON (SENDERS.webhook only; SENDERS.discord/email splice
-- the rendered text directly into a Lua table, never re-parsing it, so
-- they call this with no `escape` and get the old, literal behavior).
local function render_template(template, vars, escape)
  return (template:gsub("{{%s*([%w_.]+)%s*}}", function(token)
    local value = vars
    for part in token:gmatch("[^.]+") do
      if type(value) ~= "table" then
        value = nil
        break
      end
      value = value[part]
    end
    local rendered = value ~= nil and tostring(value) or ""
    return escape and escape(rendered) or rendered
  end))
end

-- Builds the per-message template vars for one alert - every column on
-- `alert` (every alerts.* column, plus observable_id/observable_name/rule_name/payload
-- joined in by plugins/notification_channels/services/delivery_queue.lua's
-- claim_batch, the same enrichment plugins/alerting/plugin.lua's
-- GET /api/alerts already exposes) is reachable as alert.<column> -
-- `tags` (a Postgres array) is comma-joined into a string, and `payload`
-- (the observation's properties, arriving as a JSON string via that
-- query's `properties::text` cast) is decoded into a nested table so
-- {{alert.payload.<field>}} works through render_template's dotted-path
-- walk - same defensive table-or-string handling as
-- server/lib/jsonb_query.lua's M.decode, replicated here rather than
-- required directly since that module lives under server/lib, off the
-- standalone worker's Lua path.
local function alert_vars(alert)
  local vars_alert = {}
  for k, v in pairs(alert) do
    vars_alert[k] = v
  end
  vars_alert.tags = alert.tags and table.concat(alert.tags, ", ") or ""
  vars_alert.payload = cjson_safe.decode(alert.payload or "") or {}
  return {
    alert = vars_alert,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
  }
end

local M = {}

-- Builds a {send(channel, alerts) -> [{alert_id, ok, err}] | nil, err}
-- instance, sending every discord/webhook channel through the given
-- `transport` (an object
-- exposing the same {send(self, url, payload, headers, method)}
-- interface pling's own webhook_transport.lua does; defaults to that
-- module's own LuaSocket/LuaSec transport when omitted, so callers that
-- only care about overriding `smtp_cfg` don't need to require it
-- themselves) and every email channel through the SMTP relay described by
-- `smtp_cfg` (see shared/watchtower_worker_core/runner.lua's build_config -
-- {host, port, user, password, from, ssl} - a single app-wide setting, not
-- per-channel) via `email_notifier` (a module exposing `.new(smtp_cfg)` ->
-- an instance with the same `{send(self, target_cfg, alerts)}` interface
-- pling.notifiers.email itself exposes; defaults to that module when
-- omitted, so the standalone worker's
-- shared/watchtower_worker_core/processors.lua, which passes only the SMTP
-- config, keeps working unchanged). The embedded worker
-- passes server/lib/resty_mail_notifier.lua instead, since
-- pling.notifiers.email is built on LuaSocket's own SMTP/MIME protocol
-- code, which cannot run inside an nginx worker process (see that module's
-- header comment for why, and why lua-resty-mail avoids the problem
-- entirely rather than working around it). A nil/host-less smtp_cfg just
-- means email sends fail per-alert with a clear reason, not a crash.
function M.new(transport, smtp_cfg, email_notifier)
  transport = transport or pling_webhook_transport.new({})
  email_notifier = email_notifier or pling_email
  local discord = pling_discord.new(transport)
  local webhook = pling_webhook.new(transport)

  local SENDERS = {}

  -- channel.options.headers is plain user-authored text (see
  -- config/dataset/init.sql's notification_channels_webhook) - expected to
  -- be a JSON object of extra header names/values, decoded here; an
  -- unparseable/absent value just means no extra headers, not an error.
  -- channel.options.body is rendered fresh per alert (see alert_vars
  -- above) - the rendered body is a JSON string already, so the template
  -- callback hands it to the transport as-is (decoded back into a table,
  -- since webhook_transport re-encodes whatever `template` returns).
  -- render_template is called with `json_escape` here specifically because
  -- of that decode: an interpolated value containing a `"`, `\`, or a raw
  -- control character (e.g. a scraped title with a quote in it) would
  -- otherwise corrupt the surrounding JSON text and make cjson_safe.decode
  -- return nil below, silently breaking (or nulling) the whole delivery.
  -- One HTTP call per alert, each independently pcall'd so one alert's
  -- failure doesn't stop the rest of the channel's sends; returns an array
  -- of {alert_id, ok, err}.
  SENDERS.webhook = function(channel, alerts)
    local headers = {}
    local decoded_headers = cjson_safe.decode(channel.options.headers or "")
    if type(decoded_headers) == "table" then
      for k, v in pairs(decoded_headers) do
        headers[k] = v
      end
    end

    local results = {}
    for _, alert in ipairs(alerts) do
      local body = render_template(channel.options.body or "", alert_vars(alert), json_escape)
      local target_cfg = {
        url = channel.options.url,
        headers = headers,
        method = channel.options.method,
        template = function(_) return cjson_safe.decode(body) end,
      }
      local ok, err = pcall(function() return webhook:send(target_cfg, { alert }) end)
      table.insert(results, { alert_id = alert.id, ok = ok, err = (not ok) and err or nil })
    end
    return results
  end

  -- Discord's incoming-webhook contract: POST {content: "..."} as JSON.
  -- One HTTP call per alert (see SENDERS.webhook's header comment - same
  -- per-alert/pcall/{alert_id, ok, err} shape).
  SENDERS.discord = function(channel, alerts)
    local results = {}
    for _, alert in ipairs(alerts) do
      local message = render_template(channel.options.message or "", alert_vars(alert))
      local target_cfg = {
        url = channel.options.url,
        template = function(_) return { content = message } end,
      }
      local ok, err = pcall(function() return discord:send(target_cfg, { alert }) end)
      table.insert(results, { alert_id = alert.id, ok = ok, err = (not ok) and err or nil })
    end
    return results
  end

  -- channel.options.to_addresses is a comma-separated recipient list (same
  -- free-text convention as SENDERS.webhook's own `headers` field). Subject
  -- and body are both rendered per alert, same as webhook's body/discord's
  -- message. Unlike webhook/discord's own sender (which only inspects
  -- pcall's own success and ignores the notifier's own {false, err}
  -- return), email:send can fail *without* raising - so both layers are
  -- checked here: `raised_ok` (pcall didn't error) and `send_ok` (the
  -- notifier's own reported result).
  SENDERS.email = function(channel, alerts)
    local results = {}

    -- smtp_cfg.unsupported, if a caller ever sets it, means this runtime
    -- can't send email at all right now, distinct from smtp_cfg being
    -- merely unconfigured - both fail the same way (every alert in the
    -- batch, no attempt), just with a different, more actionable reason
    -- string. Neither runtime sets this today - both the standalone
    -- worker's own pling.notifiers.email and the embedded worker's
    -- lua-resty-mail-based notifier (server/lib/resty_mail_notifier.lua)
    -- can send email now.
    local unsupported_reason = smtp_cfg and smtp_cfg.unsupported
    if unsupported_reason or not smtp_cfg or not smtp_cfg.host or smtp_cfg.host == "" then
      for _, alert in ipairs(alerts) do
        table.insert(results, { alert_id = alert.id, ok = false, err = unsupported_reason or "smtp is not configured" })
      end
      return results
    end

    local email = email_notifier.new(smtp_cfg)
    local to = {}
    for address in (channel.options.to_addresses or ""):gmatch("[^,%s]+") do
      table.insert(to, address)
    end

    for _, alert in ipairs(alerts) do
      local vars = alert_vars(alert)
      local subject = render_template(channel.options.subject or "", vars)
      local body = render_template(channel.options.body or "", vars)
      local target_cfg = {
        to = to,
        template = function(_) return { subject = subject, body = body } end,
      }
      local raised_ok, send_ok, send_err = pcall(function() return email:send(target_cfg, { alert }) end)
      local ok = raised_ok and send_ok and true or false
      local err = (not raised_ok) and send_ok or ((not send_ok) and send_err or nil)
      table.insert(results, { alert_id = alert.id, ok = ok, err = err })
    end
    return results
  end

  -- Sends `alerts` (an array of alert rows) through `channel` (a
  -- notification_channels row, with its subtype's `.options` already
  -- resolved - see server/models/notification_channels.lua) - one outbound
  -- message per alert. Returns an array of {alert_id, ok, err} (err nil on
  -- success), or (nil, err) if `channel.type` itself is unrecognized.
  local function send(channel, alerts)
    local sender = SENDERS[channel.type]
    if not sender then
      return nil, "unknown channel type: " .. tostring(channel.type)
    end
    return sender(channel, alerts)
  end

  return { send = send }
end

return M
