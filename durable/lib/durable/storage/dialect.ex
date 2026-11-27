defmodule Durable.Storage.Dialect do
  @moduledoc """
  The storage dialect seam: what differs between PostgreSQL and SQLite.

  Durable keeps one set of Ecto schemas and queries. The few places that
  need database-specific SQL ask this module instead of assuming PostgreSQL:

  | Concern | PostgreSQL | SQLite |
  | --- | --- | --- |
  | Table namespace | schema prefix (`"durable"`) | none (one database file) |
  | Row lock for read-modify-write | `FOR UPDATE` | an `IMMEDIATE` transaction (single writer) |
  | Job claim | `FOR UPDATE SKIP LOCKED` | claim inside an `IMMEDIATE` transaction |
  | JSON columns | `jsonb` | `TEXT` holding JSON (JSON1 functions) |

  The dialect is derived from the repo's Ecto adapter, so hosts do not
  configure it. SQLite needs `ecto_sqlite3` (an optional dependency) and
  Durable compiled with `config :durable, schema_prefix: nil`, because Ecto
  schema prefixes are compile-time and SQLite has no schemas.
  """

  import Ecto.Query, only: [lock: 2]

  @type t :: :postgres | :sqlite

  @doc """
  The table prefix Durable's Ecto schemas were compiled with
  (`config :durable, schema_prefix: ...`, default `"durable"`).
  """
  @spec schema_prefix() :: String.t() | nil
  # apply/3: a direct call is a compile-time constant the type checker folds,
  # which turns the nil check in validate!/1 into a "disjoint types" warning.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  def schema_prefix, do: apply(Durable.Storage.Schemas.WorkflowExecution, :__schema__, [:prefix])

  @doc """
  Returns the dialect for a repo module or a `Durable.Config`.
  """
  @spec of(module() | %{repo: module()}) :: t()
  def of(%{repo: repo}), do: of(repo)

  def of(repo) when is_atom(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 -> :sqlite
      _ -> :postgres
    end
  end

  @doc "True when the repo (or config) stores into SQLite."
  @spec sqlite?(module() | %{repo: module()}) :: boolean()
  def sqlite?(repo_or_config), do: of(repo_or_config) == :sqlite

  @doc """
  The runtime prefix for raw SQL and migrations: the configured one on
  PostgreSQL, `nil` on SQLite.
  """
  @spec prefix(module() | %{repo: module()}, String.t() | nil) :: String.t() | nil
  def prefix(repo_or_config, prefix) do
    if sqlite?(repo_or_config), do: nil, else: prefix
  end

  @doc """
  Qualifies `table` for raw SQL: `prefix.table`, or `table` with no prefix.
  """
  @spec table(String.t() | nil, String.t()) :: String.t()
  def table(nil, table), do: table
  def table(prefix, table), do: "#{prefix}.#{table}"

  @doc """
  Adds `FOR UPDATE` on PostgreSQL. On SQLite the enclosing transaction is
  `IMMEDIATE` (see `transaction_opts/1`), which already serialises writers.
  """
  @spec for_update(Ecto.Query.t(), module() | %{repo: module()}) :: Ecto.Query.t()
  def for_update(query, repo_or_config) do
    if sqlite?(repo_or_config), do: query, else: lock(query, "FOR UPDATE")
  end

  @doc """
  Adds `FOR UPDATE SKIP LOCKED` on PostgreSQL; nothing on SQLite (see
  `for_update/2`).
  """
  @spec for_update_skip_locked(Ecto.Query.t(), module() | %{repo: module()}) :: Ecto.Query.t()
  def for_update_skip_locked(query, repo_or_config) do
    if sqlite?(repo_or_config), do: query, else: lock(query, "FOR UPDATE SKIP LOCKED")
  end

  @doc """
  Transaction options. SQLite transactions start `IMMEDIATE` so a
  read-then-write cannot fail half way with `SQLITE_BUSY` on lock upgrade,
  and so two writers serialise the way `FOR UPDATE` serialises them on
  PostgreSQL.
  """
  @spec transaction_opts(module() | %{repo: module()}) :: keyword()
  def transaction_opts(repo_or_config) do
    if sqlite?(repo_or_config), do: [mode: :immediate], else: []
  end

  @doc """
  The migration column type for JSON documents: `:jsonb` on PostgreSQL,
  `:map` (TEXT with JSON) on SQLite.
  """
  @spec json_type(module()) :: atom()
  def json_type(repo), do: if(sqlite?(repo), do: :map, else: :jsonb)

  @doc """
  Raises unless the compiled schema prefix fits the repo. A SQLite repo
  with schemas compiled for the `"durable"` PostgreSQL schema would fail on
  every query, so this fails at startup instead.
  """
  @spec validate!(module()) :: :ok
  def validate!(repo) do
    compiled = schema_prefix()

    if sqlite?(repo) and compiled != nil do
      raise ArgumentError,
            "Durable is compiled with schema prefix #{inspect(compiled)}, but " <>
              "#{inspect(repo)} is a SQLite repo. Add `config :durable, schema_prefix: nil` " <>
              "to the host's config/config.exs and recompile Durable (`mix deps.compile durable --force`)."
    end

    :ok
  end
end
