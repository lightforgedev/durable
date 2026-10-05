defmodule Durable.Migration.Migrations.V20260609000000AddStepExecutionSessionId do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_609_000_000

  @impl true
  def up(prefix) do
    add_column_if_not_exists(:step_executions, :session_id, :string, [], prefix)

    create_if_not_exists(index(:step_executions, [:workflow_id, :session_id], prefix: prefix))

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(index(:step_executions, [:workflow_id, :session_id], prefix: prefix))

    remove_column_if_exists(:step_executions, :session_id, :string, prefix)

    :ok
  end
end
