defmodule Durable.Migration.Migrations.V20260719000000AddPendingEventTimeoutMode do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_719_000_000

  @impl true
  def up(prefix) do
    add_column_if_not_exists(
      :pending_events,
      :on_timeout,
      :string,
      [null: false, default: "resume"],
      prefix
    )

    :ok
  end

  @impl true
  def down(prefix) do
    remove_column_if_exists(:pending_events, :on_timeout, :string, prefix)

    :ok
  end
end
