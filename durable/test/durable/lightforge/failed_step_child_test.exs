defmodule Durable.Lightforge.FailedStepChildTest do
  @moduledoc """
  Lightforge carry: a failed step's context save keeps the children the step
  recorded in the run's engine state, so a retry reuses them (PR #24 review).
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.TestRepo, as: Repo

  defmodule Side do
    use Durable
    workflow("lf_putback_side", do: step(:work, fn data -> {:ok, data} end))
  end

  defmodule StartsThenFails do
    use Durable
    use Durable.Orchestration

    workflow "lf_putback_starts_then_fails" do
      step :go, [retry: [max_attempts: 1]], fn data ->
        {:ok, _child} = start_workflow(Side, %{}, ref: :side)
        Durable.Context.put_context(:evidence, "before failing")
        if :persistent_term.get(:lf_putback_broken, true), do: {:error, :down}, else: {:ok, data}
      end
    end
  end

  setup do
    :persistent_term.put(:lf_putback_broken, true)
    on_exit(fn -> :persistent_term.erase(:lf_putback_broken) end)
  end

  defp children(run),
    do: Repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id))

  test "a failed step's context save keeps the child the step started; the retry reuses it" do
    run = run_workflow(StartsThenFails)
    assert run.status == :failed
    assert run.context["evidence"] == "before failing"
    assert [child] = children(run)
    assert run.engine_state["__fire_forget:side"] == child.id

    :persistent_term.put(:lf_putback_broken, false)
    {:ok, _} = Durable.retry(run.id)
    assert drain(run).status == :completed
    assert Enum.map(children(run), & &1.id) == [child.id]
  end
end
