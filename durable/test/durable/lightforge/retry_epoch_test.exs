defmodule Durable.Lightforge.RetryEpochTest do
  @moduledoc """
  Lightforge carry: every retry bumps `context.__durable_retry_epoch`, which the
  engine turns into its attempt-scoped identity (`workflow_attempt = epoch + 1`).
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
        epoch = Durable.Context.get_context(:__durable_retry_epoch, 0)
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
    refute Map.has_key?(run.context, "__durable_retry_epoch")

    {:ok, _} = Durable.retry(run.id)
    assert reload(run.id).context["__durable_retry_epoch"] == 1
    assert execute_while_pending(run.id).status == :failed

    Process.put(:lf_broken, false)
    {:ok, _} = Durable.retry(run.id)
    assert execute_while_pending(run.id).status == :completed

    assert Process.get(:lf_seen_epochs) == [0, 1, 2]
    assert Process.get(:lf_prepare_runs) == 1
    assert reload(run.id).context["__durable_retry_epoch"] == 2
  end

  test "a keyed run's retry bumps the epoch too" do
    {:ok, id} =
      Durable.start(Agentish, %{}, key: "lf-epoch-#{System.unique_integer([:positive])}")

    assert execute_while_pending(id).status == :failed

    Process.put(:lf_broken, false)
    {:ok, _} = Durable.retry(id)
    assert execute_while_pending(id).status == :completed
    assert reload(id).context["__durable_retry_epoch"] == 1
  end

  test "a refused retry leaves the epoch alone" do
    Process.put(:lf_broken, false)
    {:ok, run} = create_and_execute_workflow(Agentish, %{})
    assert run.status == :completed

    assert Durable.retry(run.id) == {:error, :not_failed}
    refute Map.has_key?(reload(run.id).context, "__durable_retry_epoch")
  end
end
