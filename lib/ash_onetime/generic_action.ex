defmodule AshOnetime.GenericAction do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @behaviour Ash.Resource.Preparation

  alias Ash.Resource.Actions.Implementation

  @impl Ash.Resource.Preparation
  def init(opts) do
    if match?(%AshOnetime.Resource.Protection{}, opts[:protection]) do
      {:ok, opts}
    else
      {:error, "missing normalized protection"}
    end
  end

  @impl Ash.Resource.Preparation
  def supports(_opts), do: [Ash.ActionInput]

  @impl Ash.Resource.Preparation
  def prepare(%Ash.ActionInput{} = input, opts, context) do
    protection = Keyword.fetch!(opts, :protection)

    case protection.executing_only do
      [] -> install(input, protection, context)
      names -> install_delivery(input, protection, names, context)
    end
  end

  defp install(input, protection, context) do
    input
    |> Ash.ActionInput.before_action(
      fn pending -> reserve(pending, protection, context, nil) end,
      prepend?: true
    )
    |> Ash.ActionInput.after_action(fn final_input, result -> complete(final_input, result) end)
  end

  # Executing-only delivery (§2.7.3, §2.7.6). Every build makes a fresh cell, captured by
  # the prepended before-action, whose first act is the entry check. Admission and the
  # producer run there, in the caller's process; `run/3` never receives the values.
  # Completion runs in the after-action, which reads `inv` from the entry.
  defp install_delivery(input, protection, names, context) do
    {input, cell} = AshOnetime.Delivery.put_cell(input)

    input
    |> Ash.ActionInput.before_action(
      fn pending ->
        with {:ok, handle} <- AshOnetime.Delivery.claim(pending, cell, names),
             %Ash.ActionInput{} = admitted <- reserve(pending, protection, context, handle),
             :ok <- produce(admitted, handle, protection, context) do
          admitted
        end
      end,
      prepend?: true
    )
    |> Ash.ActionInput.after_action(fn final_input, result ->
      final_input
      |> complete(result)
      |> complete_delivery(final_input)
    end)
  end

  defp produce(input, handle, protection, context) do
    case AshOnetime.Admission.state(input) do
      {:ok, %{class: :execute}} ->
        AshOnetime.Delivery.produce(
          handle,
          protection.produce,
          input,
          AshOnetime.Admission.trusted_context(context)
        )

      {:ok, _state} ->
        :ok

      :error ->
        {:error, AshOnetime.Admission.unavailable_error()}
    end
  end

  defp complete_delivery({:error, _error} = error, _input), do: error

  defp complete_delivery(completed, input) do
    with {:ok, %{delivery_source: source} = state} when not is_nil(source) <-
           AshOnetime.Admission.state(input),
         :ok <- AshOnetime.Delivery.complete_current(input, state) do
      completed
    else
      _other -> {:error, AshOnetime.Delivery.lost()}
    end
  end

  @impl Ash.Resource.Actions.Implementation
  def run(input, opts, context) do
    case AshOnetime.Admission.state(input) do
      {:ok, %{class: class}} when class in [:execute, :external_execute, :nonce, :untracked] ->
        run_original(input, Keyword.get(opts, :original), context)

      {:ok, %{class: :replay, replayed: replayed}} ->
        if is_nil(input.action.returns), do: :ok, else: {:ok, replayed}

      _other ->
        {:error, AshOnetime.Admission.unavailable_error()}
    end
  end

  defp reserve(input, protection, context, delivery) do
    trusted = AshOnetime.Admission.trusted_context(context)

    reservation = AshOnetime.Admission.dispatch_reservation(input, protection, trusted, delivery)

    case reservation do
      {:execute, state} -> AshOnetime.Admission.put_state(input, state)
      {:execute, prepared, state} -> AshOnetime.Admission.put_state(prepared, state)
      {:execute_untracked, state} -> AshOnetime.Admission.put_state(input, state)
      {:replay, _decoded, state} -> AshOnetime.Admission.put_replay(input, state)
      {:error, error} -> {:error, error}
    end
  end

  # The dispatch_reservation / trusted_context / unavailable_error helpers live on
  # AshOnetime.Admission now (shared with Change); the mutation sentinel that was here
  # (replay-fence-generic-dispatch) was never registered in scripts/check_mutations.exs,
  # and the consolidated Admission.dispatch_reservation/4 carries the same dispatch logic.
  defp complete(input, result) do
    case AshOnetime.Admission.state(input) do
      {:ok, %{class: :replay} = state} ->
        # ActionInput has no relationship field, but caller code can add map keys.
        if Map.get(input, :relationships, %{}) == %{} do
          after_result(input, AshOnetime.Admission.stamp_replay(state, result))
        else
          error =
            AshOnetime.Error.new(
              :replay_relationship_change,
              "relationship changes cannot run on a replay"
            )

          Ash.DataLayer.rollback(input.resource, error)
        end

      {:ok, state} ->
        persisted_result = if is_nil(input.action.returns), do: :ok, else: result

        case AshOnetime.Admission.complete(state, persisted_result) do
          {:ok, normalized} ->
            after_result(input, AshOnetime.Admission.stamp_replay(state, normalized))

          {:error, error} ->
            {:error, error}
        end

      :error ->
        {:error, AshOnetime.Admission.unavailable_error()}
    end
  end

  defp after_result(%{action: %{returns: nil}}, _result), do: :ok
  defp after_result(_input, result), do: {:ok, result}

  defp run_original(input, {module, original_opts}, context)
       when is_atom(module) and is_list(original_opts) and module != __MODULE__ do
    Implementation.run(module, input, original_opts, context)
  end

  defp run_original(_input, _original, _context),
    do: {:error, AshOnetime.Admission.unavailable_error()}
end
