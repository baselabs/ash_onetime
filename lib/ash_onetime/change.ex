defmodule AshOnetime.Change do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    if match?(%AshOnetime.Resource.Protection{}, opts[:protection]) do
      {:ok, opts}
    else
      {:error, "missing normalized protection"}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    protection = Keyword.fetch!(opts, :protection)

    changeset
    |> Ash.Changeset.before_action(
      fn pending -> reserve(pending, protection, context) end,
      prepend?: true
    )
    |> Ash.Changeset.around_action(
      fn pending, callback -> complete(pending, callback) end,
      prepend?: true
    )
  end

  @impl true
  def batch_change(changesets, opts, context) do
    Enum.map(changesets, &change(&1, opts, context))
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "keyed effects require transactional stream execution"}

  defp reserve(changeset, protection, context) do
    trusted = trusted_context(context)

    reservation =
      if protection.external_effect do
        AshOnetime.ExternalRecovery.reserve(changeset, protection, trusted)
      else
        AshOnetime.Admission.reserve(changeset, protection, trusted)
      end

    case reservation do
      {:execute, state} ->
        AshOnetime.Admission.put_state(changeset, state)

      {:execute, prepared, state} ->
        AshOnetime.Admission.put_state(prepared, state)

      {:execute_untracked, state} ->
        AshOnetime.Admission.put_state(changeset, state)

      {:replay, decoded, state} ->
        changeset
        |> AshOnetime.Admission.put_replay(state)
        |> Ash.Changeset.set_result({:ok, decoded})

      {:error, error} ->
        {:error, error}
    end
  end

  defp complete(changeset, callback) do
    case callback.(changeset) do
      {:ok, result, final_changeset, instructions} ->
        complete_state(final_changeset, result, instructions)

      {:error, _error} = error ->
        error
    end
  end

  defp complete_state(final_changeset, result, instructions) do
    case AshOnetime.Admission.state(final_changeset) do
      {:ok, %{class: :replay} = state} ->
        {:ok, AshOnetime.Admission.stamp_replay(state, result), final_changeset,
         suppress_notifications(instructions)}

      {:ok, state} ->
        normalize_completion(state, result, final_changeset, instructions)

      :error ->
        {:error, unavailable_error()}
    end
  end

  defp normalize_completion(state, result, final_changeset, instructions) do
    case AshOnetime.Admission.complete(state, result) do
      {:ok, normalized} ->
        {:ok, AshOnetime.Admission.stamp_replay(state, normalized), final_changeset,
         instructions}

      {:error, error} ->
        {:error, error}
    end
  end

  defp suppress_notifications(instructions) when is_map(instructions),
    do: Map.put(instructions, :notifications, [])

  defp suppress_notifications(instructions), do: instructions

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
