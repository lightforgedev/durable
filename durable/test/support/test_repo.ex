defmodule Durable.TestRepo do
  @moduledoc false

  # `DURABLE_TEST_DB=sqlite mix test` runs the suite against SQLite; the
  # default is PostgreSQL. config/test.exs sets `:test_db` from that variable,
  # and compile_env makes Mix recompile this module when it changes.
  @adapter (case Application.compile_env(:durable, :test_db, :postgres) do
              :sqlite -> Ecto.Adapters.SQLite3
              :postgres -> Ecto.Adapters.Postgres
            end)

  use Ecto.Repo,
    otp_app: :durable,
    adapter: @adapter
end
