defmodule Durable.Storage.DialectTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Durable.Config
  alias Durable.Queue.Adapter
  alias Durable.Storage.Dialect
  alias Durable.Storage.Schemas.WorkflowExecution

  @test_db Application.compile_env(:durable, :test_db, :postgres)

  defmodule FakeSQLiteRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3
  end

  defmodule FakePostgresRepo do
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  test "the dialect follows the repo's Ecto adapter" do
    assert Dialect.of(FakeSQLiteRepo) == :sqlite
    assert Dialect.of(FakePostgresRepo) == :postgres
    assert Dialect.of(Durable.TestRepo) == @test_db
  end

  test "SQLite drops the schema prefix and row locks; PostgreSQL keeps them" do
    assert Dialect.prefix(FakeSQLiteRepo, "durable") == nil
    assert Dialect.prefix(FakePostgresRepo, "durable") == "durable"
    assert Dialect.table(nil, "workflow_executions") == "workflow_executions"
    assert Dialect.table("durable", "workflow_executions") == "durable.workflow_executions"

    query = from(w in WorkflowExecution)
    assert Dialect.for_update(query, FakeSQLiteRepo).lock == nil
    assert Dialect.for_update(query, FakePostgresRepo).lock == "FOR UPDATE"

    assert Dialect.for_update_skip_locked(query, FakePostgresRepo).lock ==
             "FOR UPDATE SKIP LOCKED"

    assert Dialect.transaction_opts(FakeSQLiteRepo) == [mode: :immediate]
    assert Dialect.transaction_opts(FakePostgresRepo) == []
  end

  test "config resolves prefix and queue adapter from the repo" do
    sqlite = Config.new!(repo: FakeSQLiteRepo, prefix: "durable")
    assert sqlite.prefix == nil
    assert sqlite.queue_adapter == Durable.Queue.Adapters.SQLite

    postgres = Config.new!(repo: FakePostgresRepo)
    assert postgres.prefix == "durable"
    assert postgres.queue_adapter == Durable.Queue.Adapters.Postgres

    custom = Config.new!(repo: FakePostgresRepo, queue_adapter: MyAdapter)
    assert Adapter.for_config(custom) == MyAdapter
  end

  test "startup refuses a SQLite repo when schemas were compiled with a prefix" do
    case Dialect.schema_prefix() do
      nil ->
        assert Dialect.validate!(FakeSQLiteRepo) == :ok

      prefix ->
        assert_raise ArgumentError, ~r/compiled with schema prefix "#{prefix}"/, fn ->
          Dialect.validate!(FakeSQLiteRepo)
        end
    end

    assert Dialect.validate!(FakePostgresRepo) == :ok
  end
end
