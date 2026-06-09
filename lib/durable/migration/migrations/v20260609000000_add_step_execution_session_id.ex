defmodule Durable.Migration.Migrations.V20260609000000AddStepExecutionSessionId do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_609_000_000

  @impl true
  def up(prefix) do
    alter table(:step_executions, prefix: prefix) do
      add_if_not_exists(:session_id, :string)
    end

    create_if_not_exists(index(:step_executions, [:workflow_id, :session_id], prefix: prefix))

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(index(:step_executions, [:workflow_id, :session_id], prefix: prefix))

    alter table(:step_executions, prefix: prefix) do
      remove_if_exists(:session_id, :string)
    end

    :ok
  end
end
