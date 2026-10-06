defmodule Durable.TestRepo.Migrations.AddStepExecutionSessionId do
  use Ecto.Migration

  def up do
    Durable.Migration.up()
  end

  def down do
    Durable.Migration.down(to: 20_260_104_000_000)
  end
end
