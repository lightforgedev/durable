defmodule Durable.Repo.Migrations.AddStepExecutionSessionId do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      add_if_not_exists :session_id, :string
    end

    create_if_not_exists index(:step_executions, [:workflow_id, :session_id])
  end
end
