package = "watchtower-worker-core"
version = "0.1.0-1"
source = {
  url = "git+https://github.com/Desvelao/watchtower-server",
  tag = "watchtower-worker-core-v0.1.0",
}
description = {
  summary = "A reusable, dependency-injected Lua worker runtime: config loading, a per-role task loop, observer-type routing, and one independently-requireable poller per worker role.",
  detailed = [[
    Extracted from watchtower-server. Owns only the
    orchestration/DI seams for an observing-agent-style worker: config
    loading (three-tier secret resolution), a per-role task loop,
    observable-type routing (bring your own observer type), and one
    poller per role (observe/analyze/evaluate/notify/scheduler, plus a
    stale-job reaper) whose concrete claim/process/report implementations
    are all caller-supplied.
    No DB/ngx-specific code of its own; the one exception is
    `provider_http.lua`, a ready-made plain-LuaSocket HTTP transport
    implementing every claim/report/read call these pollers need, shipped
    as a reusable reference implementation for a caller who wants one
    instead of writing their own.
  ]],
  homepage = "https://github.com/Desvelao/watchtower-server/tree/main/shared/watchtower_worker_core",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1, < 5.4",
  "lua-cjson >= 2.1",
  "lua-rule-engine == 0.1.0-1",
  "pling == 0.1.0-1",
  "luasocket",
  "luasec",
}
build = {
  type = "builtin",
  modules = {
    ["watchtower_worker_core.init"] = "shared/watchtower_worker_core/init.lua",
    ["watchtower_worker_core.logger"] = "shared/watchtower_worker_core/logger.lua",
    ["watchtower_worker_core.config_provider"] = "shared/watchtower_worker_core/config_provider.lua",
    ["watchtower_worker_core.config_provider_file"] = "shared/watchtower_worker_core/config_provider_file.lua",
    ["watchtower_worker_core.runner"] = "shared/watchtower_worker_core/runner.lua",
    ["watchtower_worker_core.loop"] = "shared/watchtower_worker_core/loop.lua",
    ["watchtower_worker_core.processors"] = "shared/watchtower_worker_core/processors.lua",
    ["watchtower_worker_core.observer_registry"] = "shared/watchtower_worker_core/observer_registry.lua",
    ["watchtower_worker_core.observable_type_cache"] = "shared/watchtower_worker_core/observable_type_cache.lua",
    ["watchtower_worker_core.roles"] = "shared/watchtower_worker_core/roles.lua",
    ["watchtower_worker_core.cron"] = "shared/watchtower_worker_core/cron.lua",
    ["watchtower_worker_core.notification_senders"] = "shared/watchtower_worker_core/notification_senders.lua",
    ["watchtower_worker_core.config_report"] = "shared/watchtower_worker_core/config_report.lua",
    ["watchtower_worker_core.rule_matching"] = "shared/watchtower_worker_core/rule_matching.lua",
    ["watchtower_worker_core.worker_rule_matcher"] = "shared/watchtower_worker_core/worker_rule_matcher.lua",
    ["watchtower_worker_core.notification_policy_matcher"] = "shared/watchtower_worker_core/notification_policy_matcher.lua",
    ["watchtower_worker_core.provider_http"] = "shared/watchtower_worker_core/provider_http.lua",
    ["watchtower_worker_core.pollers.common"] = "shared/watchtower_worker_core/pollers/common.lua",
    ["watchtower_worker_core.pollers.observe"] = "shared/watchtower_worker_core/pollers/observe.lua",
    ["watchtower_worker_core.pollers.analyze"] = "shared/watchtower_worker_core/pollers/analyze.lua",
    ["watchtower_worker_core.pollers.evaluate"] = "shared/watchtower_worker_core/pollers/evaluate.lua",
    ["watchtower_worker_core.pollers.notify"] = "shared/watchtower_worker_core/pollers/notify.lua",
    ["watchtower_worker_core.pollers.scheduler"] = "shared/watchtower_worker_core/pollers/scheduler.lua",
    ["watchtower_worker_core.pollers.reap_stale"] = "shared/watchtower_worker_core/pollers/reap_stale.lua",
  },
}
