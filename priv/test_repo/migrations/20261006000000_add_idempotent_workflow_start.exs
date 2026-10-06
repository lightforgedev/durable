defmodule Durable.TestRepo.Migrations.AddIdempotentWorkflowStart do
  use Ecto.Migration

  def up, do: Durable.Migration.up()

  def down, do: Durable.Migration.down(to: 20_260_723_000_000)
end
