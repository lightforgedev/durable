defmodule Durable.Queue.ManagerTest do
  @moduledoc """
  Regression for 85a3f66: with more than one queue configured, Queue.Manager
  built children with duplicate ids (module ids for every queue's
  DynamicSupervisor and Poller), and Durable failed to start.
  """

  use Durable.DataCase, async: false

  @moduletag :supervised

  alias Durable.Queue.Manager
  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.TestWorkflows.SimpleWorkflow

  test "Durable starts with two queues and runs work on each" do
    Durable.DataCase.start_supervised_durable!(
      queues: %{
        default: [concurrency: 1, poll_interval: 50],
        second: [concurrency: 1, poll_interval: 50]
      }
    )

    assert %{} = Manager.status(Durable, "default")
    assert %{} = Manager.status(Durable, "second")

    {:ok, a} = Durable.start(SimpleWorkflow, %{}, queue: "default")
    {:ok, b} = Durable.start(SimpleWorkflow, %{}, queue: "second")

    assert_eventually(fn ->
      repo = Durable.TestRepo

      match?(%{status: :completed, queue: "default"}, repo.get!(WorkflowExecution, a)) and
        match?(%{status: :completed, queue: "second"}, repo.get!(WorkflowExecution, b))
    end)
  end
end
