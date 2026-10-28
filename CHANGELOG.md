# Changelog

## [0.1.0-alpha2] - 2026-10-28

The server is now observer-type-agnostic: the server-side observer type
catalog (`OBSERVER_TYPE_PLUGINS`) is gone, `observer_configs` validates
fields with the default validator and hands workers generic
`{id, name, fields, mechanism_config}` rows, and the worker-side observer
plugin reshapes them. The embedded worker resolves an observer entry with
no `type` to the one type its loaded plugin registered.

- The schema now ships inside the server (`server/dataset/schema.sql`) and is
  applied once at boot by `bootstrap_schema.lua` instead of by Postgres'
  `docker-entrypoint-initdb.d`; rule and notification policy names are unique.
- Wake events: workers can long-poll `GET /api/workers/:id/events` to react
  to newly claimable work immediately (polling intervals still apply).
- Scheduler: a claimed job whose task was deleted is errored out instead of
  clogging the queue; `run_now` re-enables disabled tasks.
- Hardening: blank `sort`/search fragments, `multiple=true` property queries,
  last-administrator protection, clearer auth rejection errors.
- Import/export and delete routes for observables and observable types.
- Frontend: password visibility toggle, observer config test result panel,
  `deliver` and `observer_test` job types; the observer config tester now
  uses unsaved field/mechanism edits.
- The dev compose file no longer references a sibling repository; the
  standalone worker config mount is `WORKER_CONFIG_DIR`.

## [0.1.0-alpha1] - 2026-09-26

Initial platform-port release: Lapis/OpenResty server with a
boolean-expression rule engine, RBAC-secured users/roles/API keys,
observable-type-driven entities, a worker/job/scheduler registry,
notification channels with policy-based routing, and a shared
observe/analyze/evaluate/deliver pipeline used by both the embedded and
standalone workers. Frontend rewritten on Vue 3 + Pinia + Tailwind.
