-- One-off helper for migrating a pre-redesign database's `alerts` rows
-- (the old alert-definition shape: name/trigger_on_price/
-- trigger_on_discount/trigger_on_available/item_id/channels) into the
-- redesigned `rules` table's flat source-document shape.
--
-- Not run automatically by anything - config/dataset/init.sql is the
-- schema for a FRESH database (see CLAUDE.md: there is no migration
-- system, schema changes mean `docker compose down -v`). This script is
-- only useful if you have an existing pre-redesign deployment's data you
-- want to carry forward by hand: back up that database, stand up the new
-- schema fresh, then adapt/run the SELECT below against the OLD
-- database's `alerts` table to generate one `rules` INSERT per legacy
-- alert definition, and run the result against the new database.
--
-- `trigger_on_price` was always a free-text VARCHAR(255) with no parser
-- and no consumer anywhere in the old codebase (see the redesign's
-- Phase 3 commit) - it cannot be mechanically translated into a
-- shared/rule_expr.lua condition, so this leaves `if:` as a placeholder
-- for a human to fill in per rule. `trigger_on_discount`/
-- `trigger_on_available` (plain booleans, "alert whenever a discount
-- exists" / "alert whenever available") translate directly into
-- `discount != ""` / `available = true` conjuncts.
--
-- Run against the OLD database:
SELECT
  format(
    -- A single E'...' string, not several literals joined with `||` -
    -- only the FIRST fragment of a `||` chain needs the E prefix to make
    -- Postgres treat `\n` as an escape, but every fragment AFTER `||`
    -- reverts to being a plain (non-escaping) string literal, so a chain
    -- like `E'a\n' || 'b\n'` renders the second `\n` as two literal
    -- characters instead of a newline - a real bug caught by actually
    -- running this against a throwaway database rather than eyeballing it.
    -- `#` is a rule_source.lua comment line (only when it's the very
    -- first character of the line - see that file's header) - NOT SQL's
    -- `--`, which rule_source.lua has no concept of and would try to
    -- parse as a `key: value` line, failing since it has no colon. A
    -- real bug caught by actually parsing this output with the genuine
    -- Lua parsers rather than trusting it by inspection.
    E'# legacy alert %s (item_id=%s)\n' ||
    E'name: %s\n' ||
    E'description: "%s"\n' ||
    E'if: %s\n' ||
    E'action: %s\n' ||
    E'enabled: %s\n',
    id,
    item_id,
    regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g'),
    -- Arguments are positional, in the same order as the template's `%s`
    -- occurrences above - description comes before `if:`, so its value
    -- must too.
    'migrated from legacy alerts.id=' || id ||
      CASE WHEN trigger_on_price IS NOT NULL AND trigger_on_price <> ''
        THEN ' - replace the placeholder * with a real condition for the old trigger_on_price value: ' || trigger_on_price
        ELSE ''
      END,
    -- `if:` is only ever valid shared/rule_expr.lua syntax here (no
    -- comment support in that grammar, so nothing resembling a TODO can
    -- be embedded inline without breaking the parse) - the price
    -- condition note instead goes in `description` above, where a human
    -- reads it before ever pasting this into a real rule.
    trim(
      both ' AND ' from
      concat_ws(' AND ',
        CASE WHEN trigger_on_price IS NOT NULL AND trigger_on_price <> '' THEN '*' END,
        CASE WHEN trigger_on_discount THEN 'discount != ""' END,
        CASE WHEN trigger_on_available THEN 'available = true' END
      )
    ),
    'alert-' || id, -- action: a free-form label; rename to taste
    -- rule_source.lua's boolean coercion is an exact string match against
    -- literal "true"/"false" only (see its coerce_value) - Postgres'
    -- own boolean-to-text formatting produces "t"/"f" instead, which
    -- would fail rules.lua's `enabled must be true or false` validation
    -- if passed through %s directly. Another bug this script's own
    -- verification (actually running the output through rule_source.lua)
    -- caught rather than assuming %s would do the right thing.
    CASE WHEN enabled THEN 'true' ELSE 'false' END
  ) AS rule_source
FROM alerts
ORDER BY id;

-- Each returned `rule_source` value is what you POST as {"source": ...}
-- to /api/rules (or paste into RuleFormView's editor) on the NEW
-- database. Notification-channel associations (the old
-- alerts_notification_channels bridge) have no direct equivalent yet -
-- the rule -> channel mapping now happens in a worker's own routing
-- config (see docs/dev/worker-configuration.md), not a DB table.
