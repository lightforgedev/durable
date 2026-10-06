import Config

# `DURABLE_TEST_DB=sqlite mix test` runs the suite against SQLite (a temp
# file, WAL mode). The default is PostgreSQL. Use a separate build path per
# database to avoid recompiling on every switch:
#
#     MIX_BUILD_PATH=_build/test_sqlite DURABLE_TEST_DB=sqlite mix test
if System.get_env("DURABLE_TEST_DB") == "sqlite" do
  config :durable, test_db: :sqlite, schema_prefix: nil

  config :durable, Durable.TestRepo,
    database:
      Path.join(
        System.tmp_dir!(),
        "durable_test#{System.get_env("MIX_TEST_PARTITION")}.sqlite3"
      ),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 5,
    journal_mode: :wal,
    busy_timeout: 5_000,
    default_transaction_mode: :immediate
else
  config :durable, test_db: :postgres

  config :durable, Durable.TestRepo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    port: 54321,
    database: "durable_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
end

# Log level for tests - keep higher to reduce noise, but allow info for log capture tests
config :logger, level: :info
