defmodule Durable.StepExecutionSessionIdTest do
  use Durable.DataCase, async: false

  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  test "complete changeset extracts session_id from string-keyed step output" do
    workflow = insert_workflow_execution!()
    step_execution = insert_step_execution!(workflow.id)

    output = %{
      "session_id" => "session-123",
      "result" => "ok"
    }

    updated =
      step_execution
      |> StepExecution.complete_changeset(output, [], 12)
      |> TestRepo.update!()

    assert updated.status == :completed
    assert updated.session_id == "session-123"
    assert updated.output == output
  end

  test "complete changeset leaves session_id nil when output has no session_id" do
    workflow = insert_workflow_execution!()
    step_execution = insert_step_execution!(workflow.id)

    updated =
      step_execution
      |> StepExecution.complete_changeset(%{"result" => "ok"}, [], 12)
      |> TestRepo.update!()

    assert updated.status == :completed
    assert updated.session_id == nil
  end

  defp insert_workflow_execution! do
    attrs = %{
      workflow_module: "Durable.StepExecutionSessionIdTest.Workflow",
      workflow_name: "step_session_id",
      status: :running,
      queue: "default",
      priority: 0,
      input: %{},
      context: %{}
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> TestRepo.insert!()
  end

  defp insert_step_execution!(workflow_id) do
    attrs = %{
      workflow_id: workflow_id,
      step_name: "agent_review",
      step_type: "step",
      status: :running
    }

    %StepExecution{}
    |> StepExecution.changeset(attrs)
    |> TestRepo.insert!()
  end
end
