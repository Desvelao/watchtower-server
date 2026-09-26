# rule_engine (`lua-rule-engine` rock)

A tiny, generic boolean-expression rule engine, extracted from
[watchtower-server](https://github.com/Desvelao/watchtower-server)'s own
observation-rule and notification-policy matching so it can be reused by
other Lua projects - including watchtower-server's own standalone worker
process, which has no OpenResty/ngx or Postgres access at all.

Pure Lua 5.1+ (tested under LuaJIT/OpenResty and plain PUC-Lua alike), no
`ngx.*` API and no database driver anywhere in this package - see each
module's own header comment for the full grammar/format/API.

## Modules

- **`rule_engine.expr`** - the boolean expression grammar's parser +
  evaluator (`tags has "prod" AND source = "sensor-1"`, `payload.price
  dropped_pct 10 within 1h`, etc). `M.parse(expr_string, allowed_fields)`
  compiles a string into an AST (or `nil, err`); `M.evaluate(ast, context)`
  runs it against a plain `context` table. The field/operator vocabulary an
  expression may reference (`allowed_fields`) is entirely caller-supplied -
  this module has no fixed idea of what a "rule" or "observation" is.
- **`rule_engine.source`** - a small, deliberately limited flat
  `key: value` document parser (NOT YAML) for authoring a named condition
  (`name` / `if` / `enabled` / ...) as a single text blob - the format
  watchtower-server's rules and notification policies are both written in.
- **`rule_engine.engine`** - the generic "match a context against a
  compiled list of rule-like items" engine. `Engine.new({load, condition_field,
  allowed_fields, on_parse_error})` builds an instance around a
  caller-supplied `load()` function (returning the current array of items
  to consider - a DB query, a file read, anything); `:match(context, filter?)`
  compiles+caches each item's condition into an AST on first use,
  optionally filters items before evaluating (cheaper than evaluating and
  discarding), and returns the matching items themselves for the caller to
  project into whatever shape it needs. `:invalidate()` drops the cache so
  the next `:match()` reloads.
- **`rule_engine.duration`** / **`rule_engine.iso_date`** - small
  dependency-free helpers `rule_engine.expr` uses internally for its
  `within <duration>` / `older_than`/`newer_than <duration>` operators.
  Exposed as their own modules since they're independently useful, but not
  part of the "rule engine" concept itself.

## Install

```console
luarocks install lua-rule-engine
```

or, during watchtower-server's own development, nothing extra is needed at
all: this directory lives inside `shared/`, which is already bind-mounted
into both the server and standalone-worker dev containers with
`rule_engine.*` on `LUA_PATH` (see `shared/README.md`) - the same
in-repo-path tradeoff watchtower-server's `pling` dependency makes
explicit in `dev/docker-compose.yml`'s own comments, except this package
needs no separate mount at all since it's part of this repo, not an
external sibling one. The published rock (built from this same
subdirectory via this rockspec's `build.modules` paths - see
`lua-rule-engine-0.1.0-1.rockspec`) is what an *external* consumer (a
project outside this repo) would install instead.

## Design note: reuse by watchtower-server's notification-policy engine

`server/plugins/notification_channels/services/notification_policy_engine.lua`
mirrors `server/plugins/rules/services/rule_engine.lua`'s shape exactly, and
both are now thin wrappers around one `rule_engine.engine.Engine` instance
each:

- **Moves into this lib** (identical between the two, zero
  domain-specific logic): the AST parser/evaluator (`rule_engine.expr`),
  the flat rule-document parser (`rule_engine.source`, already reused
  directly by both `plugins/rules/services/rules.lua` and
  `plugins/notification_channels/services/policies.lua` before this
  extraction), and the compiled-cache-and-match loop itself
  (`rule_engine.engine`) - loading rows, parsing+caching each one's
  condition, skip-and-log on a parse failure, and returning whichever
  items match a context.
- **Stays in each plugin** (consumer-specific, not engine logic): *what*
  `load()` queries (`Rules:select(...)` vs `NotificationPolicies:select(...)`),
  *which* `allowed_fields` vocabulary a condition may reference (an
  observation's `source`/`payload`/... vs an alert's `severity`/`tags`/
  `rule_id`/...), *what* gets projected off a matched item
  (`{id, severity, tags, cooldown_seconds}` vs `{id, channel_ids}`), and
  the extra `policy_ids` allow-list filter the notification-policy engine
  supports (passed straight through as `engine:match(context, filter)`'s
  `filter` argument) that the rule engine has no equivalent of. None of
  that is data this library could sensibly own - it's each plugin's own
  domain vocabulary and DB access, exactly the kind of thing `opts.load`/
  `opts.allowed_fields`/the returned item shape were designed to keep
  caller-supplied.
