defmodule Durable.TestRepo.Migrations.HardenPendingEventUniqueness do
  use Ecto.Migration

  def up, do: Durable.Migration.up()

  def down, do: Durable.Migration.down(to: 20_260_719_000_000)
end
