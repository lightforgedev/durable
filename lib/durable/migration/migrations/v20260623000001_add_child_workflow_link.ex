defmodule Durable.Migration.Migrations.V20260623000001AddChildWorkflowLink do
  @moduledoc false
  # Adds a queryable step→child link (`step_executions.child_workflow_id`).
  #
  # A step that spawns a sub-workflow via `call_workflow`/`start_workflow` could
  # previously only be tied back to its child WorkflowExecution by parsing the
  # parent's `__call_children` JSONB context — mutable, lossy if the context is
  # rewritten, and not queryable. This column records the spawned child id
  # directly on the parent's step_execution row.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_623_000_001

  @impl true
  def up(prefix) do
    add_column_if_not_exists(:step_executions, :child_workflow_id, :binary_id, [], prefix)

    create_if_not_exists(index(:step_executions, [:child_workflow_id], prefix: prefix))

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(index(:step_executions, [:child_workflow_id], prefix: prefix))

    remove_column_if_exists(:step_executions, :child_workflow_id, :binary_id, prefix)

    :ok
  end
end
