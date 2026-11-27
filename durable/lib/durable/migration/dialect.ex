defmodule Durable.Migration.Dialect do
  @moduledoc false
  # Migration helpers that differ between PostgreSQL and SQLite.
  #
  # Durable's migrations stay one set of modules. Where SQLite cannot run the
  # PostgreSQL form, they call these helpers:
  #
  # | Helper | PostgreSQL | SQLite |
  # | --- | --- | --- |
  # | `json_type/0` | `:jsonb` | `:map` (TEXT holding JSON) |
  # | `add_column_if_not_exists/5` | `ADD COLUMN IF NOT EXISTS` | checks `PRAGMA table_info` first |
  # | `remove_column_if_exists/4` | `DROP COLUMN IF EXISTS` | checks `PRAGMA table_info` first |
  # | `postgres_only/1` | runs the function | skips it (GIN indexes, data fix-ups for pre-SQLite installs) |

  use Ecto.Migration

  alias Durable.Storage.Dialect
  alias Ecto.Migration.Runner

  @doc "True when the running migration targets SQLite."
  @spec sqlite?() :: boolean()
  def sqlite?, do: Dialect.sqlite?(Runner.repo())

  @doc "Column type for JSON documents."
  @spec json_type() :: atom()
  def json_type, do: Dialect.json_type(Runner.repo())

  @doc "Runs `fun` on PostgreSQL only."
  @spec postgres_only((-> term())) :: :ok
  def postgres_only(fun) do
    unless sqlite?(), do: fun.()
    :ok
  end

  @doc """
  Adds a column unless it exists. SQLite has no `ADD COLUMN IF NOT EXISTS`,
  so queued commands are flushed and the table is inspected first.
  """
  @spec add_column_if_not_exists(atom(), atom(), term(), keyword(), String.t() | nil) :: :ok
  def add_column_if_not_exists(table, column, type, opts, prefix) do
    if sqlite?() do
      unless column_exists?(table, column) do
        alter table(table, prefix: prefix) do
          add(column, type, opts)
        end
      end
    else
      alter table(table, prefix: prefix) do
        add_if_not_exists(column, type, opts)
      end
    end

    :ok
  end

  @doc "Removes a column if it exists (see `add_column_if_not_exists/5`)."
  @spec remove_column_if_exists(atom(), atom(), term(), String.t() | nil) :: :ok
  def remove_column_if_exists(table, column, type, prefix) do
    if sqlite?() do
      if column_exists?(table, column) do
        alter table(table, prefix: prefix) do
          remove(column)
        end
      end
    else
      alter table(table, prefix: prefix) do
        remove_if_exists(column, type)
      end
    end

    :ok
  end

  defp column_exists?(table, column) do
    flush()
    %{rows: rows} = Runner.repo().query!("PRAGMA table_info(#{table})", [], log: false)
    name = Atom.to_string(column)
    Enum.any?(rows, fn [_cid, col | _] -> col == name end)
  end
end
