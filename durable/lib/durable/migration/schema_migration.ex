defmodule Durable.Migration.SchemaMigration do
  @moduledoc false
  # Internal module for tracking applied Durable migrations.
  # Stores version numbers in the `durable_schema_migrations` table.
  #
  # PostgreSQL keeps the table in the Durable schema (`<prefix>.durable_schema_migrations`);
  # SQLite has no schemas, so the prefix is ignored there (see Durable.Storage.Dialect).

  use Ecto.Migration

  alias Durable.Storage.Dialect
  alias Ecto.Migration.Runner

  @table_name "durable_schema_migrations"

  @doc """
  Ensures the schema migrations table exists.
  """
  @spec ensure_table!(String.t() | nil) :: :ok
  def ensure_table!(prefix) do
    ensure_table!(get_repo(), prefix)
  end

  @spec ensure_table!(module(), String.t() | nil) :: :ok
  def ensure_table!(repo, prefix) do
    # Use direct repo query to ensure table is created immediately
    # (not deferred like Ecto.Migration's execute)
    query =
      if Dialect.sqlite?(repo) do
        """
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          version INTEGER PRIMARY KEY NOT NULL,
          inserted_at TEXT NOT NULL
        )
        """
      else
        """
        CREATE TABLE IF NOT EXISTS #{prefix}.#{@table_name} (
          version BIGINT PRIMARY KEY NOT NULL,
          inserted_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL
        )
        """
      end

    repo.query!(query, [])
    :ok
  end

  @doc """
  Checks if the migrations table exists.
  """
  @spec table_exists?(String.t() | nil) :: boolean()
  def table_exists?(prefix) do
    table_exists?(get_repo(), prefix)
  end

  @spec table_exists?(module(), String.t() | nil) :: boolean()
  def table_exists?(repo, prefix) do
    if Dialect.sqlite?(repo) do
      query = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?1"
      %{rows: [[count]]} = repo.query!(query, [@table_name])
      count > 0
    else
      query = """
      SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = $1
        AND table_name = $2
      )
      """

      %{rows: [[exists]]} = repo.query!(query, [prefix, @table_name])
      exists
    end
  end

  @doc """
  Returns all recorded migration versions in ascending order.
  """
  @spec versions(String.t() | nil) :: [pos_integer()]
  def versions(prefix) do
    versions(get_repo(), prefix)
  end

  @spec versions(module(), String.t() | nil) :: [pos_integer()]
  def versions(repo, prefix) do
    if table_exists?(repo, prefix) do
      query = "SELECT version FROM #{qualified(repo, prefix)} ORDER BY version"
      %{rows: rows} = repo.query!(query, [])
      Enum.map(rows, fn [v] -> v end)
    else
      []
    end
  end

  @doc """
  Records a migration version as applied.
  """
  @spec record_version(String.t() | nil, pos_integer()) :: :ok
  def record_version(prefix, version) do
    repo = get_repo()
    now = DateTime.utc_now()

    query =
      if Dialect.sqlite?(repo),
        do: "INSERT INTO #{@table_name} (version, inserted_at) VALUES (?1, ?2)",
        else: "INSERT INTO #{prefix}.#{@table_name} (version, inserted_at) VALUES ($1, $2)"

    repo.query!(query, [version, now])
    :ok
  end

  @doc """
  Deletes a migration version record.
  """
  @spec delete_version(String.t() | nil, pos_integer()) :: :ok
  def delete_version(prefix, version) do
    repo = get_repo()

    query =
      if Dialect.sqlite?(repo),
        do: "DELETE FROM #{@table_name} WHERE version = ?1",
        else: "DELETE FROM #{prefix}.#{@table_name} WHERE version = $1"

    repo.query!(query, [version])
    :ok
  end

  @doc """
  Drops the schema migrations table.
  """
  @spec drop_table(String.t() | nil) :: :ok
  def drop_table(prefix) do
    drop_if_exists(table(@table_name, prefix: Dialect.prefix(get_repo(), prefix)))
    :ok
  end

  defp qualified(repo, prefix), do: Dialect.table(Dialect.prefix(repo, prefix), @table_name)

  # Get repo from Ecto.Migration runner context
  defp get_repo do
    Runner.repo()
  end
end
