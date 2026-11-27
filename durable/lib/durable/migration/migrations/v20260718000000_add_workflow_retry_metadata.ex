defmodule Durable.Migration.Migrations.V20260718000000AddWorkflowRetryMetadata do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_718_000_000

  @impl true
  def up(prefix) do
    add_column_if_not_exists(
      :workflow_executions,
      :retry_count,
      :integer,
      [null: false, default: 0],
      prefix
    )

    add_column_if_not_exists(
      :workflow_executions,
      :last_retried_at,
      :utc_datetime_usec,
      [],
      prefix
    )

    :ok
  end

  @impl true
  def down(prefix) do
    remove_column_if_exists(:workflow_executions, :last_retried_at, :utc_datetime_usec, prefix)
    remove_column_if_exists(:workflow_executions, :retry_count, :integer, prefix)

    :ok
  end
end
