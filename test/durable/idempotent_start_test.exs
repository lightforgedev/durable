defmodule Durable.IdempotentStartTest do
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  defmodule Workflow do
    use Durable

    workflow "idempotent_start" do
      step(:complete, fn data -> {:ok, data} end)
    end
  end

  test "same key and request returns the original run" do
    assert {:ok, workflow_id} =
             Durable.start(Workflow, %{order_id: "order-1"}, idempotency_key: "request-1")

    assert {:ok, ^workflow_id} =
             Durable.start(Workflow, %{"order_id" => "order-1"}, idempotency_key: "request-1")

    repo = Config.get(Durable).repo

    assert repo.aggregate(
             from(w in WorkflowExecution, where: w.idempotency_key == "request-1"),
             :count
           ) == 1
  end

  test "callers can distinguish a new admission from a reused run" do
    opts = [idempotency_key: "request-with-admission", return_admission: true]

    assert {:ok, workflow_id, :started} = Durable.start(Workflow, %{order_id: "order-1"}, opts)

    assert {:ok, ^workflow_id, :existing} =
             Durable.start(Workflow, %{order_id: "order-1"}, opts)
  end

  @tag :postgres_only
  test "duplicate admission composes inside a caller transaction" do
    repo = Config.get(Durable).repo
    opts = [idempotency_key: "transaction-request", return_admission: true]

    assert {:ok, {workflow_id, workflow_id}} =
             repo.transaction(fn ->
               assert {:ok, workflow_id, :started} =
                        Durable.start(Workflow, %{order_id: "order-transaction"}, opts)

               assert {:ok, same_workflow_id, :existing} =
                        Durable.start(Workflow, %{order_id: "order-transaction"}, opts)

               {workflow_id, same_workflow_id}
             end)
  end

  test "same key with a different request fails closed" do
    assert {:ok, _workflow_id} =
             Durable.start(Workflow, %{order_id: "order-1"}, idempotency_key: "request-2")

    assert {:error, :idempotency_conflict} =
             Durable.start(Workflow, %{order_id: "order-2"}, idempotency_key: "request-2")
  end

  test "recomputing scheduled_at on retry returns the original run" do
    first_schedule = DateTime.add(DateTime.utc_now(), 60, :second)
    retry_schedule = DateTime.add(first_schedule, 1, :second)

    assert {:ok, workflow_id} =
             Durable.start(Workflow, %{order_id: "order-3"},
               idempotency_key: "request-3",
               scheduled_at: first_schedule
             )

    assert {:ok, ^workflow_id} =
             Durable.start(Workflow, %{order_id: "order-3"},
               idempotency_key: "request-3",
               scheduled_at: retry_schedule
             )

    execution = Config.get(Durable).repo.get!(WorkflowExecution, workflow_id)
    assert execution.scheduled_at == first_schedule
  end

  test "omitting a key preserves non-idempotent starts" do
    assert {:ok, first_id} = Durable.start(Workflow, %{order_id: "order-1"})
    assert {:ok, second_id} = Durable.start(Workflow, %{order_id: "order-1"})
    refute first_id == second_id
  end

  test "blank and oversized keys are rejected" do
    assert {:error, :invalid_idempotency_key} =
             Durable.start(Workflow, %{}, idempotency_key: "   ")

    assert {:error, :invalid_idempotency_key} =
             Durable.start(Workflow, %{}, idempotency_key: String.duplicate("x", 256))
  end
end
