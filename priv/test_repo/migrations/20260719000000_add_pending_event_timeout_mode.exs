defmodule Durable.TestRepo.Migrations.AddPendingEventTimeoutMode do
  use Ecto.Migration

  def up, do: Durable.Migration.up()

  def down, do: Durable.Migration.down(to: 20_260_718_000_000)
end
