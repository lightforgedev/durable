defmodule Durable.Lightforge.RetryEpochTest do
  @moduledoc """
  Lightforge carry: every retry bumps the run's retry epoch
  (`Durable.Context.retry_epoch/0`), which the engine turns into its
  attempt-scoped identity (`workflow_attempt = epoch + 1`).
  """
  use Durable.DataCase, async: false

  import Durable.DataCase, only: [create_and_execute_workflow: 2, execute_while_pending: 1]

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule Agentish do
    use Durable

    workflow "lf_retry_epoch" do
      step :prepare, fn data ->
        Process.put(:lf_prepare_runs, Process.get(:lf_prepare_runs, 0) + 1)
        {:ok, data}
      end

      step :agent, [retry: [max_attempts: 1]], fn data ->
        epoch = Durable.Context.retry_epoch()
        Process.put(:lf_seen_epochs, Process.get(:lf_seen_epochs, []) ++ [epoch])
        if Process.get(:lf_broken, false), do: raise("agent step down"), else: {:ok, data}
      end
    end
  end

  setup do
    Process.put(:lf_broken, true)
    :ok
  end

  defp reload(id), do: Config.get(Durable).repo.get!(WorkflowExecution, id)

  test "each retry gets the next epoch; the first attempt has none" do
    {:ok, run} = create_and_execute_workflow(Agentish, %{})
    assert run.status == :failed
    refute Map.has_key?(run.engine_state, "__retry_epoch__")

    {:ok, _} = Durable.retry(run.id)
    assert reload(run.id).engine_state["__retry_epoch__"] == 1
    assert execute_while_pending(run.id).status == :failed

    Process.put(:lf_broken, false)
    {:ok, _} = Durable.retry(run.id)
    assert execute_while_pending(run.id).status == :completed

    assert Process.get(:lf_seen_epochs) == [0, 1, 2]
    assert Process.get(:lf_prepare_runs) == 1
    assert reload(run.id).engine_state["__retry_epoch__"] == 2
  end

  test "a keyed run's retry bumps the epoch too" do
    {:ok, id} =
      Durable.start(Agentish, %{}, key: "lf-epoch-#{System.unique_integer([:positive])}")

    assert execute_while_pending(id).status == :failed

    Process.put(:lf_broken, false)
    {:ok, _} = Durable.retry(id)
    assert execute_while_pending(id).status == :completed
    assert reload(id).engine_state["__retry_epoch__"] == 1
  end

  test "a run that failed before saving a context is still handed its input" do
    defmodule EchoInput do
      use Durable

      workflow "lf_retry_epoch_input" do
        step :echo, fn data ->
          send(Process.get(:lf_test_pid), {:handed, data})
          {:ok, data}
        end
      end
    end

    Process.put(:lf_test_pid, self())
    {:ok, id} = Durable.start(EchoInput, %{"rev" => 2})
    repo = Config.get(Durable).repo

    {1, _} =
      repo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
        set: [status: :failed, error: %{"type" => "x"}, completed_at: DateTime.utc_now()]
      )

    {:ok, _} = Durable.retry(id)
    assert execute_while_pending(id).status == :completed
    assert_received {:handed, %{"rev" => 2}}
  end

  test "user data can't set the epoch" do
    Process.put(:lf_broken, false)
    {:ok, run} = create_and_execute_workflow(Agentish, %{"__retry_epoch__" => 99})
    assert run.status == :completed
    assert Process.get(:lf_seen_epochs) == [0]
  end

  test "a refused retry leaves the epoch alone" do
    Process.put(:lf_broken, false)
    {:ok, run} = create_and_execute_workflow(Agentish, %{})
    assert run.status == :completed

    assert Durable.retry(run.id) == {:error, :not_failed}
    refute Map.has_key?(reload(run.id).engine_state, "__retry_epoch__")
  end
end
