defmodule Durable.Lightforge.RetryPutBackTest do
  @moduledoc """
  Lightforge carry: every lane and called child a retry puts back gets the next
  retry epoch, not only the run retried (PR #24 review).
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Storage.Schemas.{PendingEvent, WorkflowExecution}
  alias Durable.TestRepo, as: Repo

  defmodule Lanes do
    use Durable

    workflow "lf_putback_lanes" do
      parallel :sides do
        step :left, fn data -> {:ok, data} end

        step :right, [retry: [max_attempts: 1]], fn data ->
          send_epoch(:right)

          if :persistent_term.get(:lf_putback_broken, true),
            do: {:error, :down},
            else: {:ok, data}
        end
      end
    end

    def send_epoch(who),
      do:
        send(:persistent_term.get(:lf_putback_pid), {:epoch, who, Durable.Context.retry_epoch()})
  end

  defmodule Charge do
    use Durable
    use Durable.Wait

    workflow "lf_putback_charge" do
      step :await, fn data ->
        Lanes.send_epoch(:charge)
        {:ok, Map.put(data, "paid", wait_for_event("bank_confirmed"))}
      end
    end
  end

  defmodule Order do
    use Durable
    use Durable.Orchestration

    workflow "lf_putback_order", timeout: :timer.hours(1) do
      step :pay, fn data ->
        case call_workflow(Charge, %{}, ref: :charge) do
          {:ok, _} -> {:ok, data}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  setup do
    :persistent_term.put(:lf_putback_broken, true)
    :persistent_term.put(:lf_putback_pid, self())

    on_exit(fn ->
      :persistent_term.erase(:lf_putback_broken)
      :persistent_term.erase(:lf_putback_pid)
    end)
  end

  defp children(run),
    do: Repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id))

  test "a failed lane put back by its block's retry gets the next epoch" do
    run = run_workflow(Lanes)
    assert run.status == :failed
    assert_received {:epoch, :right, 0}

    :persistent_term.put(:lf_putback_broken, false)
    {:ok, _} = Durable.retry(run.id)
    assert drain(run).status == :completed
    assert_received {:epoch, :right, 1}

    right = Enum.find(children(run), &(&1.engine_state["__retry_epoch__"] == 1))

    assert right,
           "the requeued lane's row has no epoch: #{inspect(Enum.map(children(run), & &1.engine_state))}"
  end

  test "a called child cancelled with its parent and put back by the retry gets the next epoch" do
    run = run_workflow(Order)
    assert run.status == :waiting
    assert_received {:epoch, :charge, 0}

    # Its deadline passes: the timeout sweep fails it and cancels the child.
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
      set: [deadline_at: past, status: :pending]
    )

    Repo.update_all(from(e in PendingEvent, where: e.workflow_id == ^run.id),
      set: [status: :timeout]
    )

    assert %{status: :failed} = drain(run)
    assert [%{status: :cancelled} = charge] = children(run)
    refute Map.has_key?(charge.engine_state, "__retry_epoch__")

    {:ok, _} = Durable.retry(run.id)
    assert drain(run).status == :waiting
    assert [%{status: :waiting} = charge] = children(run)
    assert charge.engine_state["__retry_epoch__"] == 1
    assert_received {:epoch, :charge, 1}
  end
end
