defmodule Durable.Migration.Migrations.V20260413000000AddSchedulerResilience do
  @moduledoc false
  # Bug L-1: scheduler resilience.
  # Adds tracking fields so the scheduler can detect persistently-failing
  # ScheduledWorkflow rows (e.g., the workflow_module no longer exists after
  # a code reload) and auto-disable them after a configurable failure count
  # instead of looping noisily forever.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_413_000_000

  @impl true
  def up(prefix) do
    add_column_if_not_exists(:scheduled_workflows, :last_error, :text, [], prefix)
    add_column_if_not_exists(:scheduled_workflows, :last_error_at, :utc_datetime_usec, [], prefix)

    add_column_if_not_exists(
      :scheduled_workflows,
      :consecutive_failures,
      :integer,
      [default: 0],
      prefix
    )

    add_column_if_not_exists(
      :scheduled_workflows,
      :auto_disabled_at,
      :utc_datetime_usec,
      [],
      prefix
    )

    :ok
  end

  @impl true
  def down(prefix) do
    remove_column_if_exists(:scheduled_workflows, :last_error, :text, prefix)
    remove_column_if_exists(:scheduled_workflows, :last_error_at, :utc_datetime_usec, prefix)
    remove_column_if_exists(:scheduled_workflows, :consecutive_failures, :integer, prefix)
    remove_column_if_exists(:scheduled_workflows, :auto_disabled_at, :utc_datetime_usec, prefix)

    :ok
  end
end
