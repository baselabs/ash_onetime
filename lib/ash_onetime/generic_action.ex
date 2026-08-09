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

    input
    |> Ash.ActionInput.before_action(
      fn pending -> reserve(pending, protection, context) end,
      prepend?: true
    )
    |> Ash.ActionInput.after_action(fn final_input, result -> complete(final_input, result) end)
  end

  @impl Ash.Resource.Actions.Implementation
  def run(input, opts, context) do
    case AshOnetime.Admission.state(input) do
      {:ok, %{class: class}} when class in [:execute, :external_execute, :nonce, :untracked] ->
        run_original(input, Keyword.get(opts, :original), context)

      {:ok, %{class: :replay, replayed: replayed}} ->
        if is_nil(input.action.returns), do: :ok, else: {:ok, replayed}

      _other ->
        {:error, unavailable_error()}
    end
  end

  defp reserve(input, protection, context) do
    trusted = trusted_context(context)

    reservation = dispatch_reservation(input, protection, trusted)

    case reservation do
      {:execute, state} -> AshOnetime.Admission.put_state(input, state)
      {:execute, prepared, state} -> AshOnetime.Admission.put_state(prepared, state)
      {:execute_untracked, state} -> AshOnetime.Admission.put_state(input, state)
      {:replay, _decoded, state} -> AshOnetime.Admission.put_replay(input, state)
      {:error, error} -> {:error, error}
    end
  end

  # mutation sentinel: replay-fence-generic-dispatch
  defp dispatch_reservation(subject, protection, trusted) do
    cond do
      protection.external_effect ->
        AshOnetime.ExternalRecovery.reserve(subject, protection, trusted)

      protection.strategy == :one_time_nonce and protection.commit == :independent ->
        AshOnetime.Admission.reserve_committed(subject, protection, trusted)

      true ->
        AshOnetime.Admission.reserve(subject, protection, trusted)
    end
  end

  defp complete(input, result) do
    case AshOnetime.Admission.state(input) do
      {:ok, %{class: :replay} = state} ->
        after_result(input, AshOnetime.Admission.stamp_replay(state, result))

      {:ok, state} ->
        persisted_result = if is_nil(input.action.returns), do: :ok, else: result

        case AshOnetime.Admission.complete(state, persisted_result) do
          {:ok, normalized} ->
            after_result(input, AshOnetime.Admission.stamp_replay(state, normalized))

          {:error, error} ->
            {:error, error}
        end

      :error ->
        {:error, unavailable_error()}
    end
  end

  defp after_result(%{action: %{returns: nil}}, _result), do: :ok
  defp after_result(_input, result), do: {:ok, result}

  defp run_original(input, {module, original_opts}, context)
       when is_atom(module) and is_list(original_opts) and module != __MODULE__ do
    Implementation.run(module, input, original_opts, context)
  end

  defp run_original(_input, _original, _context), do: {:error, unavailable_error()}

  defp trusted_context(context) do
    context
    |> Map.from_struct()
    |> Map.take([:actor, :tenant])
  rescue
    _exception -> %{}
  end

  defp unavailable_error do
    AshOnetime.Error.new(:admission_unavailable, "keyed-effect admission is unavailable")
  end
end
