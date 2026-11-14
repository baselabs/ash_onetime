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

    case protection.executing_only do
      [] -> install(changeset, protection, context)
      names -> install_delivery(changeset, protection, names, context)
    end
  end

  defp install(changeset, protection, context) do
    Ash.Changeset.around_action(
      changeset,
      fn pending, callback ->
        # Retain admission state here: a failed callback has no final changeset.
        # Around hooks run inside the transaction, before before-action hooks.
        case reserve(pending, protection, context, nil) do
          {:error, error} -> {:error, error}
          admitted -> complete(admitted, callback)
        end
      end,
      prepend?: true
    )
  end

  # Executing-only delivery (§2.7.3). Every build makes a fresh cell, written to the
  # subject's private context and captured by this entry's closure. The entry check is
  # the entry's first act: nothing reserves or produces before it claims.
  defp install_delivery(changeset, protection, names, context) do
    {changeset, cell} = AshOnetime.Delivery.put_cell(changeset)

    Ash.Changeset.around_action(
      changeset,
      fn pending, callback ->
        with {:ok, handle} <- AshOnetime.Delivery.claim(pending, cell, names),
             %Ash.Changeset{} = admitted <- reserve(pending, protection, context, handle),
             :ok <- produce(admitted, handle, protection, context) do
          admitted
          |> complete(callback)
          |> complete_delivery(handle)
        end
      end,
      prepend?: true
    )
  end

  defp produce(changeset, handle, protection, context) do
    case AshOnetime.Admission.state(changeset) do
      {:ok, %{class: :execute}} ->
        AshOnetime.Delivery.produce(
          handle,
          protection.produce,
          changeset,
          AshOnetime.Admission.trusted_context(context)
        )

      {:ok, _state} ->
        :ok

      :error ->
        {:error, AshOnetime.Admission.unavailable_error()}
    end
  end

  defp complete_delivery({:ok, _result, final_changeset, _instructions} = completed, handle) do
    with {:ok, %{delivery_source: source}} when not is_nil(source) <-
           AshOnetime.Admission.state(final_changeset),
         :ok <- AshOnetime.Delivery.complete(handle, source) do
      completed
    else
      _other -> Ash.DataLayer.rollback(final_changeset.resource, AshOnetime.Delivery.lost())
    end
  end

  defp complete_delivery(error, _handle), do: error

  @impl true
  def batch_change(changesets, opts, context) do
    Enum.map(changesets, &change(&1, opts, context))
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "keyed effects require transactional stream execution"}

  defp reserve(changeset, protection, context, delivery) do
    trusted = AshOnetime.Admission.trusted_context(context)

    reservation =
      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, delivery)

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
