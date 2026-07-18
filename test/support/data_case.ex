defmodule Durable.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring access to the
  application's data layer.

  You may define functions here to be used as helpers in your tests.
  """

  use ExUnit.CaseTemplate

  import Ecto.Query

  alias Durable.Config
  alias Durable.Executor

  alias Durable.Storage.Schemas.{
    PendingEvent,
    PendingInput,
    StepExecution,
    WaitGroup,
    WorkflowExecution
  }

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Durable.TestRepo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      import Durable.DataCase,
        only: [
          assert_eventually: 1,
          assert_eventually: 2,
          assert_eventually: 3,
          with_backoff: 1,
          with_backoff: 2,
          setup_sandbox: 1,
          start_supervised_durable!: 0,
          start_supervised_durable!: 1,
          pid_to_bin: 0,
          pid_to_bin: 1,
          bin_to_pid: 1
        ]
    end
  end

  setup tags do
    Durable.DataCase.setup_sandbox(tags)

    unless tags[:supervised] do
      start_supervised!({Durable, repo: Durable.TestRepo, queue_enabled: false, pubsub: :start})
    end

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Durable.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that polls until a condition is met or timeout.

  ## Examples

      assert_eventually(fn ->
        {:ok, exec} = Durable.get_execution(id)
        exec.status == :completed
      end)
  """
  def assert_eventually(fun, timeout \\ 5000, interval \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline, interval)
  end

  defp do_assert_eventually(fun, deadline, interval) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval)
        do_assert_eventually(fun, deadline, interval)
      else
        ExUnit.Assertions.flunk("Condition not met within timeout")
      end
    end
  end

  def with_backoff(opts \\ [], fun) do
    total = Keyword.get(opts, :total, 100)
    sleep = Keyword.get(opts, :sleep, 10)
    do_with_backoff(fun, 0, total, sleep)
  end

  defp do_with_backoff(fun, count, total, sleep) do
    fun.()
  rescue
    exception in [ExUnit.AssertionError] ->
      if count < total do
        Process.sleep(sleep)
        do_with_backoff(fun, count + 1, total, sleep)
      else
        reraise(exception, __STACKTRACE__)
      end
  end

  def start_supervised_durable!(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:name, Durable)
      |> Keyword.put_new(:repo, Durable.TestRepo)
      |> Keyword.put_new(:queue_enabled, true)
      |> Keyword.put_new(:pubsub, :start)
      |> Keyword.put_new(:queues, %{default: [concurrency: 1, poll_interval: 50]})
      |> Keyword.put_new(:stale_lock_timeout, 300)
      |> Keyword.put_new(:heartbeat_interval, 100)

    name = Keyword.fetch!(opts, :name)
    prior = Application.get_env(:durable, :disable_queue_processing)
    Application.put_env(:durable, :disable_queue_processing, false)
    ExUnit.Callbacks.on_exit(fn -> restore_disable_flag(prior) end)
    Durable.Supervisor.stop(name)
    start_supervised!({Durable, opts})
    name
  end

  defp restore_disable_flag(nil), do: Application.delete_env(:durable, :disable_queue_processing)

  defp restore_disable_flag(value),
    do: Application.put_env(:durable, :disable_queue_processing, value)

  def pid_to_bin(pid \\ self()), do: pid |> :erlang.term_to_binary() |> Base.encode64()
  def bin_to_pid(bin), do: bin |> Base.decode64!() |> :erlang.binary_to_term()

  def create_and_execute_workflow(module, input, opts \\ []) do
    config = Config.get(Durable)
    {:ok, workflow_def} = module.__default_workflow__()

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: Keyword.get(opts, :queue, "default"),
      priority: Keyword.get(opts, :priority, 0),
      input: input,
      context: %{}
    }

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(attrs)
      |> config.repo.insert()

    Executor.execute_workflow(execution.id, config)
    {:ok, config.repo.get!(WorkflowExecution, execution.id)}
  end

  def get_step_executions(workflow_id) do
    Config.get(Durable).repo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  def get_pending_input(repo, workflow_id, input_name) do
    repo.one(
      from(p in PendingInput,
        where: p.workflow_id == ^workflow_id and p.input_name == ^input_name
      )
    )
  end

  def get_pending_event(repo, workflow_id, event_name) do
    repo.one(
      from(p in PendingEvent,
        where: p.workflow_id == ^workflow_id and p.event_name == ^event_name
      )
    )
  end

  def get_wait_group(repo, workflow_id),
    do: repo.one(from(w in WaitGroup, where: w.workflow_id == ^workflow_id))

  def get_child_executions(repo, parent_id),
    do: repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent_id))

  def execute_children(repo, parent_id, config) do
    repo
    |> get_child_executions(parent_id)
    |> Enum.each(fn child ->
      if child.status == :pending, do: Executor.execute_workflow(child.id, config)
    end)
  end
end
