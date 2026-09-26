-- OpenResty-native counterpart to pling.notifiers.email for the
-- embedded worker's "deliver" role - see notification_senders.lua's
-- SENDERS.email. That module is built on LuaSocket's own
-- socket.smtp/socket.tp/mime protocol code, which internally invokes Lua
-- callbacks *from* C functions (e.g. for line/dot-stuffing processing) -
-- yielding a cosocket op through that C boundary raises "attempt to yield
-- across C-call boundary" (a hard Lua/LuaJIT runtime restriction). A prior
-- attempt, server/lib/resty_smtp_socket.lua, tried working around this by
-- injecting a cosocket-based *socket* underneath pling's own SMTP
-- protocol code (mirroring how resty_webhook_transport.lua/
-- watchtower_observer_web_scraper's own resty_transport.lua inject a
-- cosocket transport under other LuaSocket-based code) - that was
-- confirmed broken during testing,
-- because the problem is in pling's protocol layer itself (the
-- code that walks the SMTP conversation and MIME-encodes the message),
-- not in the socket it happens to be reading/writing through. Swapping
-- the socket underneath that code can never fix a yield raised from
-- deeper inside it.
--
-- lua-resty-mail (github.com/GUI/lua-resty-mail, `resty.mail`) sidesteps
-- the whole problem by implementing the SMTP wire protocol and MIME
-- encoding itself, directly over ngx.socket.tcp/cosockets, with no
-- LuaSocket protocol code involved anywhere in the call path - so there is
-- no C-call boundary left to yield across.
--
-- Duck-types the exact same {send(self, target_cfg, alerts)} interface
-- pling.notifiers.email exposes (see notification_senders.lua's
-- SENDERS.email, which calls `email:send(target_cfg, {alert})` once per
-- alert, where target_cfg = {to = {...}, template = function(alert)
-- return {subject=, body=} end}), so it's a drop-in replacement injected
-- only for the embedded runtime - the standalone worker keeps using
-- pling's own email notifier (LuaSocket/LuaSec, unaffected by any of
-- this) unchanged.
local mail = require("resty.mail")

local M = {}

-- smtp_cfg uses this repo's existing shape (see
-- shared/watchtower_worker_core/runner.lua's build_config): {host, port,
-- user, password, from, ssl}. resty.mail's own mail.new() option names
-- differ slightly (`username`/`password` for auth, `ssl`/`starttls` for
-- transport security) - mapped explicitly below rather than passed
-- through as-is.
function M.new(smtp_cfg)
  return setmetatable({ smtp_cfg = smtp_cfg or {} }, { __index = M })
end

-- Mirrors pling.notifiers.email:send's own per-call contract: returns
-- true on success, or nil, err on failure - matching what
-- notification_senders.lua's SENDERS.email pcall-wraps and inspects as
-- `raised_ok, send_ok, send_err`.
function M:send(target_cfg, alerts)
  local smtp_cfg = self.smtp_cfg
  local mailer, mailer_err = mail.new({
    host = smtp_cfg.host,
    port = smtp_cfg.port,
    ssl = smtp_cfg.ssl,
    username = smtp_cfg.user,
    password = smtp_cfg.password,
  })
  if not mailer then
    return nil, "failed to build SMTP client: " .. tostring(mailer_err)
  end

  for _, alert in ipairs(alerts) do
    local rendered = target_cfg.template(alert)
    local ok, err = mailer:send({
      from = smtp_cfg.from,
      to = target_cfg.to,
      subject = rendered.subject,
      text = rendered.body,
    })
    if not ok then
      return nil, tostring(err)
    end
  end

  return true
end

return M
