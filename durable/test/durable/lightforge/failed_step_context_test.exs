defmodule Durable.Lightforge.FailedStepContextTest do
  @moduledoc """
  Lightforge carry: what a step put in the context before it failed is kept on
  the failed run, so a retry resumes the engine's inner progress.
  """
  use Durable.DataCase, async: false

  import Durable.DataCase, only: [create_and_execute_workflow: 2, execute_while_pending: 1]

  defmodule Evidence do
    use Durable

    workflow "lf_failed_step_context" do
      step :review, fn _data ->
        Durable.Context.put_context(:failure_evidence, %{reason: "review_not_passed"})
        {:error, :review_not_passed}
      end
    end
  end

  defmodule InnerProgress do
    use Durable

    # One step that runs inner items and records how far it got, like the
    # engine's declarative runner.
    workflow "lf_failed_step_inner_progress" do
      step :execute, [retry: [max_attempts: 1]], fn _data ->
        from = Durable.Context.get_context(:__pointer, 0)

        Enum.reduce_while(from..2//1, :ok, fn i, :ok ->
          if i == 1 and Process.get(:lf_inner_broken, true) do
            {:halt, {:error, :inner_down}}
          else
            Process.put(:lf_inner_ran, Process.get(:lf_inner_ran, []) ++ [i])
            Durable.Context.put_context(:__pointer, i + 1)
            {:cont, :ok}
          end
        end)
        |> case do
          :ok -> {:ok, %{}}
          error -> error
        end
      end
    end
  end

  test "context written before a step error is on the failed run" do
    {:ok, run} = create_and_execute_workflow(Evidence, %{})

    assert run.status == :failed
    assert run.context["failure_evidence"] == %{"reason" => "review_not_passed"}
  end

  test "a retry resumes inner progress instead of redoing finished inner items" do
    {:ok, run} = create_and_execute_workflow(InnerProgress, %{})
    assert run.status == :failed
    assert run.context["__pointer"] == 1

    Process.put(:lf_inner_broken, false)
    {:ok, _} = Durable.retry(run.id)
    assert execute_while_pending(run.id).status == :completed

    # Item 0 ran once, before the failure; the retry started at item 1.
    assert Process.get(:lf_inner_ran) == [0, 1, 2]
  end
end
