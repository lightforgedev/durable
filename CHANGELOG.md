# Changelog

## Unreleased (branch `feat/sqlite`, from `lightforge-main` @ 86aa946)

### Added
- SQLite storage. Durable picks the dialect from the repo's Ecto adapter
  (`Durable.Storage.Dialect`). `ecto_sqlite3 ~> 0.23.0` is an optional
  dependency. The 0.23 line is the last on `ecto ~> 3.13.0` and decimal 2.x.
- `Durable.Queue.Adapters.SQLite`: it claims jobs and wakes sleepers inside
  one `BEGIN IMMEDIATE` transaction. Every other callback is shared with the
  PostgreSQL adapter.
- `:queue_adapter` option. It defaults to the adapter for the repo's database.
- `Durable.Queue.Adapter.default_adapter/1` and `for_config/1`.
- `config :durable, schema_prefix: nil`: a compile-time switch for the Ecto
  schema prefix. It defaults to `"durable"`, so nothing changes on PostgreSQL.
- The supervisor raises at startup if the repo is SQLite but the schemas were
  compiled with a prefix.

### Changed (PostgreSQL behaviour unchanged)
- Row locks (`FOR UPDATE`, `FOR UPDATE SKIP LOCKED`) go through
  `Durable.Storage.Dialect`. On PostgreSQL they generate the same SQL as before.
- `Durable.Repo.transaction/3` passes `mode: :immediate` on SQLite.
- Migrations use dialect helpers:
  - `json_type/0` gives `jsonb` on PostgreSQL and JSON text on SQLite.
  - `add_column_if_not_exists/5` and `remove_column_if_exists/4` inspect the
    table first on SQLite.
  - `postgres_only/1` wraps the GIN index and the v20260723 fix-up of old
    data.
  - The migrator skips `CREATE SCHEMA` on SQLite.
- `Durable.Query` filters by id prefix with `CAST(? AS TEXT)` instead of
  `?::text`.

### Tests
- `DURABLE_TEST_DB=sqlite mix test` runs the suite on SQLite.
- The adapter and integration-concurrency tests run against whichever adapter
  the test database uses.
- Three tests that cover PostgreSQL schemas (prefixes) are tagged
  `:postgres_only`.
