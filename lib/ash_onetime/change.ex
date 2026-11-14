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

    Ash.Changeset.around_action(
      changeset,
      fn pending, callback ->
        # Retain admission state here: a failed callback has no final changeset.
        # Around hooks run inside the transaction, before before-action hooks.
        case reserve(pending, protection, context) do
          {:error, error} -> {:error, error}
          admitted -> complete(admitted, callback)
        end
      end,
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
    trusted = AshOnetime.Admission.trusted_context(context)

    reservation = AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted)

    case reservation do
      {:execute, state} ->
        AshOnetime.Admission.put_state(changeset, state)

      {:execute, prepared, state} ->
        AshOnetime.Admission.put_state(prepared, state)

      {:execute_untracked, state} ->
        AshOnetime.Admission.put_state(changeset, state)

      {:replay, decoded, state} ->
        changeset =
          Enum.reduce(
            Map.keys(changeset.relationships),
            changeset,
            &Ash.Changeset.clear_change(&2, &1)
          )

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

      {:error, callback_error} = error ->
        if AshOnetime.Admission.replay?(changeset) do
          Ash.DataLayer.rollback(changeset.resource, callback_error)
        else
          error
        end
    end
  end

  defp complete_state(final_changeset, result, instructions) do
    case AshOnetime.Admission.state(final_changeset) do
      {:ok, %{class: :replay} = state} ->
        if final_changeset.relationships == %{} do
          {:ok, AshOnetime.Admission.stamp_replay(state, result), final_changeset,
           suppress_notifications(instructions)}
        else
          error =
            AshOnetime.Error.new(
              :replay_relationship_change,
              "relationship changes cannot run on a replay"
            )

          Ash.DataLayer.rollback(final_changeset.resource, error)
        end

      {:ok, state} ->
        normalize_completion(state, result, final_changeset, instructions)

      :error ->
        {:error, AshOnetime.Admission.unavailable_error()}
    end
  end

  defp normalize_completion(state, result, final_changeset, instructions) do
    case AshOnetime.Admission.complete(state, result) do
      {:ok, normalized} ->
        {:ok, AshOnetime.Admission.stamp_replay(state, normalized), final_changeset, instructions}

      {:error, error} ->
        {:error, error}
    end
  end

  defp suppress_notifications(instructions) when is_map(instructions),
    do: Map.put(instructions, :notifications, [])

  defp suppress_notifications(instructions), do: instructions
end
