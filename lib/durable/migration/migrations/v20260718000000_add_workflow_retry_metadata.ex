defmodule Durable.Migration.Migrations.V20260718000000AddWorkflowRetryMetadata do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_718_000_000

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:retry_count, :integer, null: false, default: 0)
      add_if_not_exists(:last_retried_at, :utc_datetime_usec)
    end

    :ok
  end

  @impl true
  def down(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:last_retried_at, :utc_datetime_usec)
      remove_if_exists(:retry_count, :integer)
    end

    :ok
  end
end
