package = "lua-rule-engine"
version = "0.1.0-1"
source = {
  url = "git+https://github.com/Desvelao/watchtower-server",
  tag = "rule-engine-v0.1.0",
}
description = {
  summary = "A tiny, generic boolean-expression rule engine for matching context objects against rule-like conditions",
  detailed = [[
    Extracted from watchtower-server (github.com/Desvelao/watchtower-server): a
    hand-rolled recursive-descent parser/evaluator for a small boolean
    expression grammar (`tags has "prod" AND source = "sensor-1"`), a flat
    "key: value" rule-document format for authoring named conditions, and a
    generic engine that compiles+caches a caller-supplied list of such
    conditions and matches a context table against them.

    Pure Lua 5.1+, no OpenResty/ngx or database dependency of its own - the
    caller supplies how conditions are loaded (a DB query, a file, an HTTP
    call, anything) and what field/operator vocabulary a condition may
    reference. See README.md for usage and design notes.
  ]],
  homepage = "https://github.com/Desvelao/watchtower-server/tree/main/shared/rule_engine",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1, < 5.4",
  "lua-cjson >= 2.1",
}
build = {
  type = "builtin",
  modules = {
    ["rule_engine.init"] = "shared/rule_engine/init.lua",
    ["rule_engine.expr"] = "shared/rule_engine/expr.lua",
    ["rule_engine.source"] = "shared/rule_engine/source.lua",
    ["rule_engine.engine"] = "shared/rule_engine/engine.lua",
    ["rule_engine.duration"] = "shared/rule_engine/duration.lua",
    ["rule_engine.iso_date"] = "shared/rule_engine/iso_date.lua",
    -- watchtower-server's own field vocabularies, required by
    -- watchtower-worker-core's rule/policy matchers.
    ["rule_engine.allowed_fields"] = "shared/rule_engine/allowed_fields.lua",
    ["rule_engine.notification_policy_allowed_fields"] = "shared/rule_engine/notification_policy_allowed_fields.lua",
  },
}
