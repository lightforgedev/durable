defmodule Durable.Migration.Migrations.V20260723000000HardenPendingEventUniqueness do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_723_000_000

  @impl true
  def up(prefix) do
    # Older host schemas did not enforce this invariant, so normalize existing
    # rows before making it database-enforced. The oldest pending row remains
    # the logical wait; later rows are duplicate attempts and must not receive
    # a second completion event.
    execute("""
    WITH ranked AS (
      SELECT id,
             row_number() OVER (
               PARTITION BY workflow_id, event_name
               ORDER BY inserted_at ASC, id ASC
             ) AS row_number
      FROM #{quote_identifier(prefix)}.pending_events
      WHERE status = 'pending'
    )
    UPDATE #{quote_identifier(prefix)}.pending_events AS pending_event
    SET status = 'cancelled',
        completed_at = COALESCE(pending_event.completed_at, NOW()),
        updated_at = NOW()
    FROM ranked
    WHERE pending_event.id = ranked.id
      AND ranked.row_number > 1
    """)

    execute(
      "DROP INDEX IF EXISTS #{quote_identifier(prefix)}.pending_events_workflow_event_pending_idx"
    )

    create(
      unique_index(:pending_events, [:workflow_id, :event_name],
        where: "status = 'pending'",
        name: :pending_events_workflow_event_pending_idx,
        prefix: prefix
      )
    )
  end

  @impl true
  def down(prefix) do
    execute(
      "DROP INDEX IF EXISTS #{quote_identifier(prefix)}.pending_events_workflow_event_pending_idx"
    )

    create(
      unique_index(:pending_events, [:workflow_id, :event_name],
        where: "status = 'pending' AND wait_type = 'single'",
        name: :pending_events_workflow_event_pending_idx,
        prefix: prefix
      )
    )
  end

  defp quote_identifier(identifier) do
    ~s("#{String.replace(identifier, ~s("), ~s(""))}")
  end
end
