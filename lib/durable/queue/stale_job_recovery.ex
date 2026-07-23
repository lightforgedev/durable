defmodule Durable.Queue.StaleJobRecovery do
  @moduledoc """
  Periodically recovers jobs with stale locks.

  Jobs can become "stuck" if a worker process crashes without releasing
  the lock. This GenServer periodically checks for such jobs and releases
  them back to pending status so they can be picked up again.
  """

  use GenServer

  require Logger

  alias Durable.Config
  alias Durable.Queue.Adapter

  defstruct [:config, :interval]

  @default_interval 60_000

  @doc """
  Starts the stale job recovery process.

  ## Options

  - `:config` - The Durable configuration (required)
  - `:interval` - Milliseconds between recovery checks (default: 60000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    name = recovery_name(config.name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually triggers stale lock recovery.
  """
  @spec recover_now(atom()) :: {:ok, non_neg_integer()} | {:error, term()}
  def recover_now(durable_name \\ Durable) do
    GenServer.call(recovery_name(durable_name), :recover_now)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    interval = Keyword.get(opts, :interval, @default_interval)

    state = %__MODULE__{
      config: config,
      interval: interval
    }

    # Schedule first recovery
    schedule_recovery(interval)

    Logger.info(
      "Stale job recovery started for #{inspect(config.name)}, interval=#{interval}ms, timeout=#{config.stale_lock_timeout}s"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:recover_now, _from, state) do
    result = do_recovery(state.config)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:recover, state) do
    do_recovery(state.config)
    schedule_recovery(state.interval)
    {:noreply, state}
  end

  # Private functions

  defp do_recovery(%Config{} = config) do
    adapter = Adapter.default_adapter()

    with {:ok, stale_count} <-
           adapter.recover_stale_locks(config, config.stale_lock_timeout),
         {:ok, zombie_count} <- recover_zombie_workflows(adapter, config) do
      if stale_count > 0 do
        Logger.info("Recovered #{stale_count} stale job(s) for #{inspect(config.name)}")
        emit_telemetry(:stale_recovered, stale_count, config.name)
      end

      if zombie_count > 0 do
        Logger.warning(
          "Marked #{zombie_count} zombie workflow(s) as failed for #{inspect(config.name)}"
        )

        emit_telemetry(:zombie_recovered, zombie_count, config.name)
      end

      {:ok, stale_count + zombie_count}
    else
      {:error, reason} = error ->
        Logger.error("Recovery failed for #{inspect(config.name)}: #{inspect(reason)}")
        error
    end
  end

  defp recover_zombie_workflows(adapter, config) do
    if function_exported?(adapter, :recover_zombie_workflows, 2) do
      adapter.recover_zombie_workflows(config, config.stale_lock_timeout)
    else
      {:ok, 0}
    end
  end

  defp schedule_recovery(interval) do
    Process.send_after(self(), :recover, interval)
  end

  defp recovery_name(durable_name) do
    Module.concat([durable_name, Queue, StaleJobRecovery])
  end

  defp emit_telemetry(event, count, durable_name) do
    :telemetry.execute(
      [:durable, :queue, event],
      %{count: count},
      %{durable: durable_name}
    )
  end
end
