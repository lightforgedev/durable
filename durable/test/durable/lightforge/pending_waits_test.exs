defmodule Durable.Lightforge.PendingWaitsTest do
  @moduledoc "Lightforge carry: `Durable.pending_waits/2`."
  use Durable.DataCase, async: false

  import Durable.DataCase, only: [create_and_execute_workflow: 2]

  alias Durable.Config
  alias Durable.Storage.Schemas.PendingEvent

  defmodule AsksApproval do
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "lf_pending_waits_input" do
      step(:ask, fn data ->
        {:ok, assign(data, :answer, wait_for_approval("manager_approval", prompt: "OK?"))}
      end)
    end
  end

  defmodule AwaitsEvent do
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "lf_pending_waits_event" do
      step(:await, fn data ->
        {:ok, assign(data, :paid, wait_for_event("payment_confirmed"))}
      end)
    end
  end

  test "returns every pending wait of one run and none of another run's" do
    repo = Config.get(Durable).repo
    {:ok, asks} = create_and_execute_workflow(AsksApproval, %{})
    {:ok, other} = create_and_execute_workflow(AwaitsEvent, %{})
    assert asks.status == :waiting and other.status == :waiting

    %PendingEvent{}
    |> PendingEvent.changeset(%{
      workflow_id: asks.id,
      event_name: "follow_up",
      step_name: "manual_follow_up"
    })
    |> repo.insert!()

    assert {:ok, waits} = Durable.pending_waits(asks.id)
    assert [%{kind: :input, name: "manager_approval"}, %{kind: :event, name: "follow_up"}] = waits
    assert Enum.all?(waits, &(&1.workflow_id == asks.id))
    assert Durable.pending_waits!(asks.id) == waits
  end

  test "leaves out an event buffered before the run waits for it" do
    {:ok, asks} = create_and_execute_workflow(AsksApproval, %{})
    :ok = Durable.send_event(asks.id, "later", %{}, buffer: true)

    assert {:ok, [%{kind: :input}]} = Durable.pending_waits(asks.id)
  end

  test "is empty for a run with no pending waits" do
    {:ok, id} = Durable.start(AsksApproval, %{})
    assert Durable.pending_waits(id) == {:ok, []}
  end

  test "says :not_found for an id that isn't a run's" do
    assert Durable.pending_waits(Ecto.UUID.generate()) == {:error, :not_found}
    assert Durable.pending_waits("not-a-uuid") == {:error, :not_found}
    assert Durable.pending_waits(nil) == {:error, :not_found}
  end
end
