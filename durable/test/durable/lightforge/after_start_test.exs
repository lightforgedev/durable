defmodule Durable.Lightforge.AfterStartTest do
  @moduledoc """
  Lightforge carry: `call_workflow/3` and `start_workflow/3` take `:after_start`,
  the host's gate on a child (the engine checks its tenancy tag). It runs in
  the insert's transaction; a child that fails it is never committed.
  """
  use Durable.DataCase, async: false

  import Durable.DataCase, only: [create_and_execute_workflow: 2]

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule Child do
    use Durable
    workflow("lf_after_start_child", do: step(:work, fn data -> {:ok, data} end))
  end

  defmodule Gate do
    @moduledoc false
    # The gate looks the child up, as the engine's tag check does: it must see
    # the uncommitted row.
    def check(child_id) do
      send(Process.get(:lf_test_pid), {:gate_saw, child_id, seen?(child_id)})
      Process.get(:lf_gate_result, :ok)
    end

    defp seen?(id), do: Config.get(Durable).repo.get(WorkflowExecution, id) != nil
  end

  defmodule Caller do
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    workflow "lf_after_start_caller" do
      step :call, fn data ->
        case call_workflow(Child, %{}, ref: :child, after_start: &Gate.check/1) do
          {:ok, _result} -> {:ok, assign(data, :outcome, "child_done")}
          {:error, {:child_start_callback_failed, why}} -> {:ok, assign(data, :outcome, inspect(why))}
        end
      end
    end
  end

  defmodule Starter do
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    workflow "lf_after_start_starter" do
      step :start, fn data ->
        case start_workflow(Child, %{}, ref: :child, after_start: &Gate.check/1) do
          {:ok, id} -> {:ok, assign(data, :child, id)}
          {:error, {:child_start_callback_failed, why}} -> {:ok, assign(data, :outcome, inspect(why))}
        end
      end
    end
  end

  defmodule BadGate do
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    workflow "lf_after_start_bad_gate" do
      step :call, fn data ->
        case call_workflow(Child, %{}, after_start: fn _id -> :yes end) do
          {:error, {:child_start_callback_failed, why}} -> {:ok, assign(data, :outcome, inspect(why))}
        end
      end
    end
  end

  setup do
    Process.put(:lf_test_pid, self())
    :ok
  end

  defp children(parent_id) do
    Config.get(Durable).repo.all(
      from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent_id)
    )
  end

  test "a passing gate sees the inserted child, which then runs" do
    {:ok, parent} = create_and_execute_workflow(Caller, %{})
    assert parent.status == :waiting
    assert_received {:gate_saw, child_id, true}
    assert [%{id: ^child_id, status: :pending}] = children(parent.id)
  end

  test "call_workflow: a failing gate leaves no child and returns the reason" do
    Process.put(:lf_gate_result, {:error, :tenancy_mismatch})
    {:ok, parent} = create_and_execute_workflow(Caller, %{})

    assert parent.status == :completed, inspect(parent.error)
    assert parent.context["outcome"] == ":tenancy_mismatch"
    assert_received {:gate_saw, child_id, true}
    assert children(parent.id) == []
    assert Config.get(Durable).repo.get(WorkflowExecution, child_id) == nil
  end

  test "start_workflow: a failing gate leaves no child and returns the reason" do
    Process.put(:lf_gate_result, {:error, :tenancy_mismatch})
    {:ok, parent} = create_and_execute_workflow(Starter, %{})

    assert parent.status == :completed, inspect(parent.error)
    assert parent.context["outcome"] == ":tenancy_mismatch"
    assert children(parent.id) == []
  end

  test "a gate that returns neither :ok nor an error tuple fails closed" do
    {:ok, parent} = create_and_execute_workflow(BadGate, %{})

    assert parent.status == :completed, inspect(parent.error)
    assert parent.context["outcome"] == "{:invalid_after_start_result, :yes}"
    assert children(parent.id) == []
  end
end
