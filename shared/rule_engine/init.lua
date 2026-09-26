-- Public entry point for the `rule_engine` LuaRocks package - see
-- README.md in this directory. Requiring the individual submodules
-- directly (`require("rule_engine.expr")`, `require("rule_engine.source")`,
-- `require("rule_engine.engine")`) works identically and is what
-- watchtower-server's own server code does; `require("rule_engine")` is just a
-- convenience for external consumers that want the whole package behind
-- one require.
return {
  expr = require("rule_engine.expr"),
  source = require("rule_engine.source"),
  engine = require("rule_engine.engine"),
  duration = require("rule_engine.duration"),
  iso_date = require("rule_engine.iso_date"),
}
