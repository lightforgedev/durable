defmodule Durable.Migration.Migrations.V20260719000000AddPendingEventTimeoutMode do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_719_000_000

  @impl true
  def up(prefix) do
    alter table(:pending_events, prefix: prefix) do
      add_if_not_exists(:on_timeout, :string, null: false, default: "resume")
    end

    :ok
  end

  @impl true
  def down(prefix) do
    alter table(:pending_events, prefix: prefix) do
      remove_if_exists(:on_timeout, :string)
    end

    :ok
  end
end
