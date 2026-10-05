defmodule Durable.Queue.Adapters.SQLite do
  @moduledoc """
  SQLite queue adapter, for single-node hosts such as a desktop app.

  SQLite has one writer at a time and no row locks, so the two claims that
  PostgreSQL makes with `FOR UPDATE SKIP LOCKED` run here as a read and an
  update inside one `IMMEDIATE` transaction. `BEGIN IMMEDIATE` takes the
  database write lock before the read, so two pollers can never select the
  same row: the second waits (up to the connection's `busy_timeout`) and then
  sees the first one's claim.

  Every other callback is plain Ecto and shared with
  `Durable.Queue.Adapters.Postgres`.

  Each claimed job gets its own fresh `lock_token` (the fencing token the
  PostgreSQL adapter mints with `gen_random_uuid()`).
  """

  @behaviour Durable.Queue.Adapter

  alias Durable.Config
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  @impl true
  def fetch_jobs(%Config{} = config, queue, limit, node_id)
      when is_binary(queue) and limit > 0 do
    now = DateTime.utc_now()
    stale_before = DateTime.add(now, -config.stale_lock_timeout, :second)

    claimable =
      from(w in WorkflowExecution,
        where: w.status == :pending and w.queue == ^queue,
        where: is_nil(w.scheduled_at) or w.scheduled_at <= ^now,
        where: is_nil(w.locked_by) or w.locked_at < ^stale_before,
        # SQLite sorts NULLs first in ascending order, as `NULLS FIRST` does.
        order_by: [desc: w.priority, asc: w.scheduled_at, asc: w.inserted_at],
        limit: ^limit
      )

    result =
      Repo.transaction(config, fn ->
        config
        |> Repo.all(claimable)
        |> Enum.flat_map(&claim(config, &1, node_id, now))
      end)

    case result do
      {:ok, jobs} -> jobs
      {:error, _reason} -> []
    end
  rescue
    # Busy past `busy_timeout`, or the database is closing: claim nothing
    # this tick, like the PostgreSQL adapter does on a query error.
    _error in [Exqlite.Error, DBConnection.ConnectionError] -> []
  end

  defp claim(config, %WorkflowExecution{} = execution, node_id, now) do
    token = Ecto.UUID.generate()

    query =
      from(w in WorkflowExecution, where: w.id == ^execution.id and w.status == :pending)

    case Repo.update_all(config, query,
           set: [
             status: :running,
             locked_by: node_id,
             locked_at: now,
             lock_token: token,
             updated_at: now
           ]
         ) do
      {1, _} ->
        [
          %{
            id: execution.id,
            workflow_module: execution.workflow_module,
            workflow_name: execution.workflow_name,
            queue: execution.queue,
            priority: execution.priority,
            input: execution.input || %{},
            context: execution.context || %{},
            scheduled_at: execution.scheduled_at,
            current_step: execution.current_step,
            lock_token: token
          }
        ]

      {0, _} ->
        []
    end
  end

  @impl true
  def wake_sleeping_workflows(%Config{} = config, batch_size)
      when is_integer(batch_size) and batch_size > 0 do
    # Same contract as the PostgreSQL adapter: elapsed sleeps go back to
    # :pending with no lock and no scheduled_at, and the context gets the
    # `__sleep_satisfied__ => current_step` marker so the step's next
    # sleep/schedule_at call returns instead of throwing again.
    now = DateTime.utc_now()

    wakeable =
      from(w in WorkflowExecution,
        where: w.status == :waiting,
        where: not is_nil(w.scheduled_at) and w.scheduled_at <= ^now,
        where: not is_nil(w.current_step),
        order_by: [asc: w.scheduled_at],
        limit: ^batch_size
      )

    Repo.transaction(config, fn ->
      config
      |> Repo.all(wakeable)
      |> Enum.count(&wake(config, &1, now))
    end)
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  defp wake(config, %WorkflowExecution{} = execution, now) do
    context = Map.put(execution.context || %{}, "__sleep_satisfied__", execution.current_step)

    query =
      from(w in WorkflowExecution, where: w.id == ^execution.id and w.status == :waiting)

    {count, _} =
      Repo.update_all(config, query,
        set: [
          status: :pending,
          scheduled_at: nil,
          locked_by: nil,
          locked_at: nil,
          context: context,
          updated_at: now
        ]
      )

    count == 1
  end

  # Plain Ecto: identical on both databases.
  @impl true
  defdelegate ack(config, job_id), to: Postgres
  defdelegate ack(config, job_id, lock_token), to: Postgres

  @impl true
  defdelegate nack(config, job_id, reason), to: Postgres
  defdelegate nack(config, job_id, reason, lock_token), to: Postgres

  @impl true
  defdelegate reschedule(config, job_id, run_at), to: Postgres
  defdelegate reschedule(config, job_id, run_at, lock_token), to: Postgres

  @impl true
  defdelegate recover_stale_locks(config, timeout_seconds), to: Postgres

  @impl true
  defdelegate recover_zombie_workflows(config, timeout_seconds), to: Postgres

  @impl true
  defdelegate heartbeat(config, job_id), to: Postgres
  defdelegate heartbeat(config, job_id, lock_token), to: Postgres

  @impl true
  defdelegate get_stats(config, queue), to: Postgres
end
