# Observable type property storage: JSONB-first, with an escape hatch

`observable_types` lets an admin define an arbitrary kind of monitorable thing at
runtime: a set of input properties (used to create Observables of that type) and
an observation schema (the shape recorded each time an observable of that type is
observed). This document explains how those property *values* are stored and
queried, and why.

## Why JSONB-first

Observable types are defined by users at runtime, through the UI - not by a
developer editing code. This repository also has **no migration system**:
schema changes mean hand-editing `config/dataset/init.sql` and recreating the
whole dev DB volume (`docker compose down -v`). A design where each observable
type got its own real columns (or its own child table, the way
`notification_channels`'s discord/webhook split works) would require running
DDL every time someone defines a new type - either a human editing `init.sql`
per type (defeating the point of a user-facing "create an observable type" form),
or the application executing dynamic `CREATE TABLE`/`ALTER TABLE` statements
from user input at runtime (a real injection/lock/rollback risk, and a
schema-drift nightmare with nothing tracking it in version control).

Storing property values in a `properties JSONB` column on `observables` and
`observations`, validated in Lua against the owning observable type's schema
(`server/lib/property_schema.lua`), sidesteps all of that: defining a new
observable type is a plain `INSERT`, and adding/removing/renaming a property on
an existing type is a plain `UPDATE` - no DDL, ever, for the common case.

## Property-definition shape reference

Both `observable_types.properties` and `observable_types.observation_schema` are a
JSON array of property-definition objects:

```json
{
  "name": "price",
  "label": "Price",
  "type": "number",
  "multiple": false,
  "required": true,
  "searchable": false,
  "validations": { "min": 0 }
}
```

- `name` - the key this property is stored under in `properties`. Must match
  `^[a-z][a-z0-9_]*$` and be unique within the schema.
- `label` - display label; defaults to `name`.
- `type` - one of `string`, `number`, `boolean`, `date`, `url`, `enum`, `map`.
- `multiple` - if `true`, the value is a JSON array of the base type instead
  of a single value.
- `required` - if `true`, the property must be present on create/update.
- `searchable` - if `true` (string/url/enum types only), the property's
  value is included in the resource's free-text `search` query param.
- `validations` - allowed keys depend on `type`:
  - `string` / `url`: `minLength`, `maxLength`, `pattern` (a Lua pattern)
  - `number` / `date`: `min`, `max`
  - `enum`: `options` (required, a non-empty array of strings)
  - `boolean`: none

All of this is validated by `server/lib/property_schema.lua`'s
`validate_schema` (the definitions themselves) and `validate_values` (a
payload checked against a schema) - never by a DB constraint.

## Query pattern

`server/lib/jsonb_query.lua` translates query params into JSONB SQL clauses
for both `/api/observables` and `/api/observations`, scoped by the observable type
resolved from `observable_type_id`:

- `properties.<name>=<value>` - exact/contains match via Postgres' `@>`
  containment operator. This is also the correct "array contains this value"
  test for a `multiple: true` property.
- `properties.<name>.gt=<value>` / `.gte=` / `.lt=` / `.lte=` - a cast
  comparison (`(properties->>'<name>')::numeric`/`::timestamp <op> <value>`),
  available only for `number`/`date`-typed properties.
- The free-text `search` param additionally matches (`ILIKE`) every property
  marked `searchable: true`.

Examples:

```
GET /api/observables?observable_type_id=1&properties.url=https://example.com/product
GET /api/observables?observable_type_id=2&properties.location=warehouse-3
GET /api/observations?observable_type_id=1&properties.price.lt=100
```

A plain GIN index (`jsonb_path_ops`) on both `observables.properties` and
`observations.properties` makes the containment (`@>`) path fast generically,
with no per-property setup - this is built unconditionally, for every
observable type, from day one.

## Escape hatch: promoting a hot property to a real column

The GIN-indexed containment path is fast for exact/multi-value matches, but a
cast comparison (`(properties->>'price')::numeric > 100`) or an `ORDER BY` on
a JSONB field doesn't benefit from that index - Postgres has to scan and cast
per row. If a specific property on a specific type turns out to be queried
or sorted often enough that this matters, promote it to a real, indexed
column with an **additive**, targeted `init.sql` change - no redesign of the
overall storage model required:

```sql
ALTER TABLE observables
  ADD COLUMN price_num NUMERIC
  GENERATED ALWAYS AS ((properties->>'price')::numeric) STORED;

CREATE INDEX observables_price_num_idx ON observables (price_num);
```

Postgres keeps `price_num` in sync automatically on every insert/update (it's
`GENERATED ALWAYS`, not writable directly) - `properties->>'price'` stays the
source of truth, this is just a cached, indexed projection of it. Queries can
then use the plain, fast, indexed column:

```sql
SELECT * FROM observables WHERE price_num > 100 ORDER BY price_num;
```

If a stored generated column isn't desirable (e.g. the value needs
normalization the generation expression can't express, or you'd rather not
add a new column to every row), an expression index over the same cast
achieves the same query-plan benefit without adding a column - but the query
text has to match the indexed expression exactly for Postgres to use it, and
it can't be selected as a plain output column the way a generated column can:

```sql
CREATE INDEX observables_price_expr_idx ON observables (((properties->>'price')::numeric));
```

**When to reach for this:** only once a specific property is demonstrably
"hot" - high query volume, a real need to `ORDER BY` it, or it shows up in
slow-query logs. No property qualifies yet; this is a fresh generalization
with only the seeded `product` observable type in use. Do not pre-emptively index
every property "just in case" - that reintroduces the DDL-per-property
problem this design exists to avoid.
