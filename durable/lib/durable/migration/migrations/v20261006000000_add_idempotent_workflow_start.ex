defmodule Durable.Migration.Migrations.V20261006000000AddIdempotentWorkflowStart do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_006_000_000

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add(:idempotency_key, :string)
      add(:idempotency_fingerprint, :string)
    end

    create(
      unique_index(:workflow_executions, [:idempotency_key],
        where: "idempotency_key IS NOT NULL",
        name: :workflow_executions_idempotency_key_index,
        prefix: prefix
      )
    )
  end

  @impl true
  def down(prefix) do
    drop(
      index(:workflow_executions, [:idempotency_key],
        name: :workflow_executions_idempotency_key_index,
        prefix: prefix
      )
    )

    alter table(:workflow_executions, prefix: prefix) do
      remove(:idempotency_key)
      remove(:idempotency_fingerprint)
    end
  end
end
