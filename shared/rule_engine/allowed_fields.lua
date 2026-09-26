-- The grammar rule_engine.expr's condition language (`if:`) is allowed to
-- reference, for this project's domain. rule_engine.expr's comparison
-- evaluator is already generic for any flat field (`context[ast.field]`),
-- so this is purely a vocabulary/config change, not a parser change.
--
-- Lives alongside the generic engine (not under server/plugins/rules/) so
-- it's require-able with zero DB/plugin dependency by anything that builds
-- its own rule_engine.engine instance against the same vocabulary - today
-- that's server/plugins/rules/services/rule_engine.lua (DB-backed) and
-- shared/watchtower_worker_core/worker_rule_matcher.lua (the standalone
-- worker's own HTTP-backed matcher) - both need the identical field/operator
-- set or a rule that matches server-side could silently fail to match
-- worker-side (or vice versa).
--
-- Deliberately observable-type-agnostic on SCHEMA fields: no
-- observation-schema field (e.g. "product"'s price/discount/available/url)
-- is listed here directly - an observable type's own fields are only
-- reachable via `payload.<name>` (payload.* below), since the field
-- names/shapes an observation carries are entirely defined per observable
-- type (see observable_types.observation_schema) and a fixed rule
-- vocabulary can't represent all of them. `worker` and `observable_type`
-- are both universal observation metadata (present regardless of which
-- observable type an observable belongs to), so they're listed directly -
-- `observable_type` matches the observable type's `name` (a stable,
-- unique, human-typeable identifier - not its `label`, which is nullable
-- and unenforced), letting a rule target one type explicitly (e.g.
-- `observable_type = "product"`) without needing to know that type's
-- payload field names.
--
-- A rule's `if` is evaluated against the context built in
-- shared/analyzer.lua's build_match_context:
--   { source, observable_id, worker, observable_type, payload }
return {
  source = { ["="] = true, ["!="] = true, ["in"] = true, contains = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  observable_id = { ["="] = true, ["!="] = true, ["in"] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  worker = { ["="] = true, ["!="] = true, ["in"] = true },
  observable_type = { ["="] = true, ["!="] = true, ["in"] = true },
  payload = {
    ["="] = true, ["!="] = true, ["in"] = true, contains = true, is_set = true,
    [">"] = true, ["<"] = true, [">="] = true, ["<="] = true, changed = true, changed_within = true,
  },
  ["payload.*"] = {
    ["="] = true, ["!="] = true, has = true, ["in"] = true, contains = true, is_set = true,
    dropped_pct = true, raised_pct = true, older_than = true, newer_than = true,
    [">"] = true, ["<"] = true, [">="] = true, ["<="] = true, changed = true, changed_within = true,
  },
}
