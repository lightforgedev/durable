defmodule Durable.Orchestration do
  @moduledoc """
  Workflow composition: call child workflows from parent steps.

  Provides two primitives for composing workflows:

  - `call_workflow/3` — Start a child workflow and wait for its result (synchronous)
  - `start_workflow/3` — Start a child workflow without waiting (fire-and-forget)

  ## Usage

      defmodule MyApp.OrderWorkflow do
        use Durable
        use Durable.Context
        use Durable.Orchestration

        workflow "process_order" do
          step :charge_payment, fn data ->
            case call_workflow(MyApp.PaymentWorkflow, %{"amount" => data.total},
                   timeout: hours(1)) do
              {:ok, result} ->
                {:ok, assign(data, :payment_id, result["payment_id"])}
              {:error, reason} ->
                {:error, reason}
            end
          end

          step :send_email, fn data ->
            {:ok, email_wf_id} = start_workflow(MyApp.EmailWorkflow,
              %{"to" => data.email}, ref: :confirmation)
            {:ok, assign(data, :email_workflow_id, email_wf_id)}
          end
        end
      end

  """

  alias Durable.Config
  alias Durable.Context
  alias Durable.Executor
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  @children_key :__children
  @child_results_key :__child_results
  @max_child_refs 100
  @max_ref_bytes 200
  @ref_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]*\z/

  @doc """
  Injects orchestration functions into the calling module.
  """
  defmacro __using__(_opts) do
    quote do
      import Durable.Orchestration,
        only: [call_workflow: 2, call_workflow: 3, start_workflow: 2, start_workflow: 3]
    end
  end

  @doc """
  Starts a child workflow and waits for its result.

  The parent workflow will be suspended until the child completes or fails.
  On resume, returns `{:ok, result}` or `{:error, reason}`.

  ## Options

  - `:ref` - Reference name for idempotency (default: module name)
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value returned on timeout (default: `:child_timeout`)
  - `:queue` - Queue for the child workflow (default: "default")
  - `:durable` - Durable instance name (default: Durable)
  - `:after_start` - callback invoked with the persisted child execution before it
    is allowed to run. It must return `:ok` or `{:error, reason}`. A callback
    failure deletes the child and fails the parent call.

  ## Examples

      case call_workflow(MyApp.PaymentWorkflow, %{"amount" => 100}, timeout: hours(1)) do
        {:ok, result} -> {:ok, assign(data, :payment, result)}
        {:error, reason} -> {:error, reason}
      end

  """
  @spec call_workflow(module(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_workflow(module, input, opts \\ []) do
    parent_id = Context.workflow_id()
    ref = normalize_ref!(Keyword.get(opts, :ref, module_to_ref(module)))
    context = Process.get(:durable_context, %{})

    case {fetch_child_result(context, ref), fetch_child(context, ref)} do
      {{:ok, result}, _child} ->
        parse_child_result(result)

      {:error, {:ok, child_id}} ->
        handle_existing_child(child_id, opts)

      {:error, :error} ->
        create_and_wait(module, input, parent_id, ref, opts)
    end
  end

  @doc """
  Starts a child workflow without waiting for its result (fire-and-forget).

  Returns `{:ok, child_id}` immediately. The child runs independently.
  Idempotent: if resumed, returns the same child_id without creating a duplicate.

  ## Options

  - `:ref` - Reference name for idempotency (default: module name)
  - `:queue` - Queue for the child workflow (default: "default")
  - `:durable` - Durable instance name (default: Durable)

  ## Examples

      {:ok, child_id} = start_workflow(MyApp.EmailWorkflow,
        %{"to" => email}, ref: :welcome_email)

  """
  @spec start_workflow(module(), map(), keyword()) :: {:ok, String.t()}
  def start_workflow(module, input, opts \\ []) do
    parent_id = Context.workflow_id()
    ref = normalize_ref!(Keyword.get(opts, :ref, module_to_ref(module)))
    context = Process.get(:durable_context, %{})

    case fetch_child(context, ref) do
      {:ok, child_id} ->
        {:ok, child_id}

      :error ->
        ensure_registry_capacity!(context)

        with {:ok, child_id} <- create_child_execution(module, input, parent_id, opts) do
          put_child(context, ref, child_id)
          {:ok, child_id}
        end
    end
  end

  defp create_and_wait(module, input, parent_id, ref, opts) do
    context = Process.get(:durable_context, %{})
    ensure_registry_capacity!(context)

    with {:ok, child_id} <- create_child_execution(module, input, parent_id, opts) do
      put_child(context, ref, child_id)

      throw(
        {:call_workflow,
         child_id: child_id,
         timeout: Keyword.get(opts, :timeout),
         timeout_value: Keyword.get(opts, :timeout_value, :child_timeout)}
      )
    end
  end

  defp put_child(context, ref, child_id) do
    children =
      context
      |> child_registry()
      |> Map.put(ref, child_id)

    Context.put_context(@children_key, children)
  end

  defp fetch_child(context, ref) do
    case Map.fetch(child_registry(context), ref) do
      {:ok, child_id} ->
        {:ok, child_id}

      :error ->
        fetch_legacy_child(context, ref)
    end
  end

  defp fetch_child_result(context, ref) do
    case Map.fetch(child_result_registry(context), ref) do
      {:ok, result} -> {:ok, result}
      :error -> fetch_legacy_result(context, ref)
    end
  end

  defp child_registry(context),
    do: Map.get(context, @children_key) || Map.get(context, Atom.to_string(@children_key)) || %{}

  defp child_result_registry(context),
    do:
      Map.get(context, @child_results_key) ||
        Map.get(context, Atom.to_string(@child_results_key)) || %{}

  defp fetch_legacy_child(context, ref), do: fetch_legacy(context, "__child:" <> ref)
  defp fetch_legacy_result(context, ref), do: fetch_legacy(context, "__child_done:" <> ref)

  defp fetch_legacy(context, expected_key) do
    Enum.find_value(context, :error, fn
      {key, value} when is_atom(key) ->
        if Atom.to_string(key) == expected_key, do: {:ok, value}

      {^expected_key, value} ->
        {:ok, value}

      _ ->
        nil
    end)
  end

  defp ensure_registry_capacity!(context) do
    if map_size(child_registry(context)) >= @max_child_refs do
      raise ArgumentError, "child workflow ref limit exceeded (max #{@max_child_refs})"
    end
  end

  defp normalize_ref!(ref) when is_atom(ref), do: ref |> Atom.to_string() |> normalize_ref!()

  defp normalize_ref!(ref) when is_binary(ref) do
    if byte_size(ref) in 1..@max_ref_bytes and Regex.match?(@ref_pattern, ref) do
      ref
    else
      raise ArgumentError,
            "child workflow ref must be 1-#{@max_ref_bytes} bytes and contain only letters, digits, '.', '_', ':', '/', or '-'"
    end
  end

  defp normalize_ref!(ref),
    do: raise(ArgumentError, "child workflow ref must be an atom or string, got: #{inspect(ref)}")

  defp handle_existing_child(child_id, opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    case Repo.get(config, WorkflowExecution, child_id) do
      nil ->
        {:error, :child_not_found}

      %{status: :completed} = child ->
        parse_child_result(build_result_payload(:completed, child.context))

      %{status: status} = child when status in [:failed, :cancelled, :compensation_failed] ->
        parse_child_result(build_result_payload(:failed, child.error))

      _child ->
        # Still running/waiting — re-throw to wait again
        throw(
          {:call_workflow,
           child_id: child_id,
           timeout: Keyword.get(opts, :timeout),
           timeout_value: Keyword.get(opts, :timeout_value, :child_timeout)}
        )
    end
  end

  defp create_child_execution(module, input, parent_id, opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    {:ok, workflow_def} = get_child_workflow_def(module, opts)

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: Keyword.get(opts, :queue, "default") |> to_string(),
      priority: Keyword.get(opts, :priority, 0),
      input: input,
      context: %{},
      parent_workflow_id: parent_id
    }

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(attrs)
      |> Repo.insert(config)

    with :ok <- after_start(opts, execution.id) do
      # For inline execution (testing), execute the child immediately.
      if Keyword.get(opts, :inline, false) do
        Executor.execute_workflow(execution.id, config)
      end

      {:ok, execution.id}
    else
      {:error, reason} ->
        # A child without its required host-side registration (for example an
        # org ownership tag) must never become runnable. Delete it before
        # returning the error to the parent.
        _ = Repo.delete(execution, config)
        {:error, {:child_start_callback_failed, reason}}
    end
  end

  defp after_start(opts, child_id) do
    case Keyword.get(opts, :after_start) do
      nil ->
        :ok

      callback when is_function(callback, 1) ->
        case callback.(child_id) do
          :ok -> :ok
          {:error, _reason} = error -> error
          other -> {:error, {:invalid_after_start_result, other}}
        end

      _ ->
        {:error, :invalid_after_start_callback}
    end
  end

  defp get_child_workflow_def(module, opts) do
    case Keyword.get(opts, :workflow) do
      nil -> module.__default_workflow__()
      name -> module.__workflow_definition__(name)
    end
  end

  @doc false
  def child_context_key(ref), do: "__child:#{normalize_ref!(ref)}"

  @doc false
  def child_result_key(ref), do: "__child_done:#{normalize_ref!(ref)}"

  @doc false
  def child_event_name(child_id), do: "__child_done:#{child_id}"

  @doc false
  def fire_forget_key(ref), do: "__fire_forget:#{normalize_ref!(ref)}"

  @doc false
  def result_context(parent_context, child_id, payload) do
    ref =
      Enum.find_value(child_registry(parent_context), fn
        {ref, ^child_id} -> ref
        _ -> nil
      end) || legacy_ref_for_child(parent_context, child_id)

    if ref do
      results = Map.put(child_result_registry(parent_context), ref, payload)
      %{Atom.to_string(@child_results_key) => results}
    else
      %{}
    end
  end

  defp legacy_ref_for_child(context, child_id) do
    Enum.find_value(context, fn
      {key, ^child_id} when is_atom(key) ->
        case Atom.to_string(key) do
          "__child:" <> ref -> ref
          _ -> nil
        end

      {"__child:" <> ref, ^child_id} ->
        ref

      _ ->
        nil
    end)
  end

  @doc false
  def build_result_payload(status, data) do
    %{
      "status" => Atom.to_string(status),
      "result" => data
    }
  end

  @doc false
  def parse_child_result(%{"status" => "completed", "result" => result}) do
    {:ok, result}
  end

  def parse_child_result(%{"status" => status, "result" => result})
      when status in ["failed", "cancelled", "compensation_failed"] do
    {:error, result}
  end

  def parse_child_result(other) do
    {:error, {:unexpected_child_result, other}}
  end

  defp module_to_ref(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end
