defmodule Durable.ErrorNormalizationTest do
  @moduledoc """
  Regression test for executor error-path normalization.

  If a step returns `{:error, value}` where `value` is not a map, the raw
  value must be normalized before being persisted into the workflow
  execution's `error :map` column. Otherwise `mark_failed` hits an Ecto
  cast error, the real cause is lost, and the caller only sees the
  secondary MatchError.

  See fix/normalize-error-on-step-failure.
  """

  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule AtomErrorWorkflow do
    use Durable

    workflow "atom_error" do
      step(:boom, fn _ -> {:error, :something_bad} end)
    end
  end

  defmodule TupleErrorWorkflow do
    use Durable

    workflow "tuple_error" do
      step(:boom, fn _ -> {:error, {:contract_not_frozen, :draft}} end)
    end
  end

  defmodule StringErrorWorkflow do
    use Durable

    workflow "string_error" do
      step(:boom, fn _ -> {:error, "nope"} end)
    end
  end

  defmodule ContextThenErrorWorkflow do
    use Durable

    workflow "context_then_error" do
      step(:boom, fn _ ->
        Durable.Context.put_context(:failure_evidence, %{
          "reason" => "review_not_passed",
          "pr_url" => "https://github.com/lightforgedev/aegis-api-phoenix/pull/2610"
        })

        {:error, :review_not_passed}
      end)
    end
  end

  test "atom errors are normalized into a map before persistence" do
    execution = run_workflow(AtomErrorWorkflow)
    assert execution.status == :failed
    assert is_map(execution.error)
    assert execution.error["message"] == "something_bad"
  end

  test "tuple errors are normalized into a map before persistence" do
    execution = run_workflow(TupleErrorWorkflow)
    assert execution.status == :failed
    assert is_map(execution.error)
    assert execution.error["message"] =~ "contract_not_frozen"
  end

  test "binary errors are normalized into a map before persistence" do
    execution = run_workflow(StringErrorWorkflow)
    assert execution.status == :failed
    assert is_map(execution.error)
    assert execution.error["message"] == "nope"
  end

  test "context written before a step error is persisted on the failed execution" do
    execution = run_workflow(ContextThenErrorWorkflow)

    assert execution.status == :failed
    assert execution.error["message"] == "review_not_passed"

    assert execution.context["failure_evidence"] == %{
             "reason" => "review_not_passed",
             "pr_url" => "https://github.com/lightforgedev/aegis-api-phoenix/pull/2610"
           }
  end

  defp run_workflow(module) do
    config = Config.get(Durable)
    repo = config.repo
    {:ok, workflow_def} = module.__default_workflow__()

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: "default",
      priority: 0,
      input: %{},
      context: %{}
    }

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(attrs)
      |> repo.insert()

    _ = Executor.execute_workflow(execution.id, config)
    repo.get!(WorkflowExecution, execution.id)
  end
end
