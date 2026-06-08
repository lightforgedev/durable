defmodule Durable.ContextInputTest do
  @moduledoc """
  Regression test for `Durable.Context.input/0`.

  The executor must populate the process dictionary with the workflow input
  before executing any step, so step functions can use the documented
  `Durable.Context.input/0` API.
  """

  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule EchoInputWorkflow do
    use Durable

    workflow "echo_input" do
      step(:echo, fn _ ->
        case Durable.Context.input() do
          %{"payload" => payload} ->
            {:ok, %{echoed: payload}}

          _ ->
            {:error, :missing_payload}
        end
      end)
    end
  end

  test "step functions can read workflow input via Durable.Context.input/0" do
    config = Config.get(Durable)
    repo = config.repo
    {:ok, workflow_def} = EchoInputWorkflow.__default_workflow__()

    attrs = %{
      workflow_module: Atom.to_string(EchoInputWorkflow),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: "default",
      priority: 0,
      input: %{"payload" => "hello"},
      context: %{}
    }

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(attrs)
      |> repo.insert()

    _ = Executor.execute_workflow(execution.id, config)
    reloaded = repo.get!(WorkflowExecution, execution.id)

    assert reloaded.status == :completed,
           "expected :completed, got error=#{inspect(reloaded.error)}"

    assert Map.get(reloaded.context, "echoed") == "hello" or
             Map.get(reloaded.context, :echoed) == "hello"
  end
end
