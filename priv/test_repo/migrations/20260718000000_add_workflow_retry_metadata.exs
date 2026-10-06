defmodule Durable.TestRepo.Migrations.AddWorkflowRetryMetadata do
  use Ecto.Migration

  def up do
    Durable.Migration.up()
  end

  def down do
    Durable.Migration.down(to: 20_260_609_000_000)
  end
end
