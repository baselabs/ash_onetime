defmodule AshOnetime.ExternalRecovery do
  @moduledoc false

  alias AshOnetime.{Admission, Error, ExternalEffect, Telemetry}
  alias AshOnetime.Store
  alias AshOnetime.Store.Result

  # The pre-peer claim lock's default wait (ADR-0010): comfortably longer than a local
  # finalize, far shorter than a peer call, and well under the committed-claim worker's
  # 30s ceiling. Overridable per protection via `external_lock_timeout_ms`.
  @default_claim_lock_timeout 2_000

  @spec reserve(Ash.Changeset.t() | Ash.ActionInput.t(), struct(), map()) ::
          {:execute, Ash.Changeset.t() | Ash.ActionInput.t(), Admission.State.t()}
          | {:replay, term(), Admission.State.t()}
          | {:error, Error.t()}
  def reserve(subject, %{strategy: :idempotency, external_effect: module} = protection, context)
      when is_atom(module) and is_map(context) do
    started = System.monotonic_time()

    with {:ok, state} <- Admission.prepare(subject, protection, context),
         %Result{} = committed <-
           Store.claim_committed(state.target, state.request, claim_lock_options(protection)) do
      case committed do
        # The same-key retry's worker blocked on the original's pre-peer claim lock past the
        # configured wait (ADR-0010): the external path now reports the local path's
        # concurrent-retry semantic instead of racing into a second peer execute.
        %Result{status: :failure, reason: :lock_timeout} ->
          emit_claim_lock_conflict(state)

          {:error,
           Error.new(:request_in_progress, "a request for this key is already processing")}

        %Result{} ->
          decision =
            Admission.resolve(
              committed,
              state,
              protection,
              started,
              :committed_external_claim
            )

          continue(decision, subject, protection, context, started)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def reserve(_subject, _protection, _context), do: unavailable()

  defp continue({:execute, state}, subject, protection, context, started) do
    emit(state, started, :processing_committed)
    operation_key = state.claim.id

    with :ok <- validate_operation_key(operation_key) do
      case lock_for_peer(state, protection, started) do
        {:ok, locked} ->
          execute_then_settle(locked, subject, protection, context, operation_key, started)

        other ->
          other
      end
    end
  end

  defp continue({:recover, state}, subject, protection, context, started) do
    operation_key = state.claim.id

    with :ok <- validate_operation_key(operation_key) do
      case lock_for_peer(state, protection, started) do
        {:ok, locked} ->
          recover_processing(locked, subject, protection, context, operation_key, started)

        other ->
          other
      end
    end
  end

  defp continue({:replay, _replayed, state}, _subject, protection, _context, started) do
    lock_replay(state, protection, started)
  end

  defp continue({:error, %Error{} = error}, _subject, _protection, _context, _started),
    do: {:error, error}

  defp continue(_decision, _subject, _protection, _context, _started), do: unavailable()

  # ADR-0010 pre-peer claim lock: before ANY peer call, take the claim row FOR UPDATE in the
  # caller's open transaction with a bounded wait, then re-resolve. A same-key retry now
  # either waits out the original and replays its completed result, or fails with
  # :request_in_progress — it can no longer execute concurrently under one operation key.
  # A claim that completed while this caller was blocked resolves to a replay (the full-row
  # lock result routes through the same finalize-mode resolver); a reaped-and-reinserted row
  # is missing under the id bind and fails closed.
  defp lock_for_peer(state, protection, started) do
    case Store.lock_for_effect(state.target, state.claim, claim_lock_options(protection)) do
      %Result{status: :failure, reason: :lock_timeout} ->
        emit_claim_lock_conflict(state)
        {:error, Error.new(:request_in_progress, "a request for this key is already processing")}

      %Result{} = result ->
        case Admission.resolve(result, state, protection, started, :locked_external_claim) do
          {:execute, locked_state} ->
            {:ok, locked_state}

          {:replay, replayed, replay_state} ->
            emit(replay_state, started, :replayed)
            {:replay, replayed, replay_state}

          {:error, %Error{} = error} ->
            {:error, error}

          _other ->
            unavailable()
        end
    end
  end

  defp claim_lock_options(protection) do
    [lock_timeout_ms: protection.external_lock_timeout_ms || @default_claim_lock_timeout]
  end

  # Mirrors the local path's concurrent-retry observability (Admission's
  # emit_conflict(state, :processing) before :request_in_progress).
  defp emit_claim_lock_conflict(state) do
    _ = Telemetry.conflict(state.strategy, state.resource, state.action, :processing)
    :ok
  end

  defp recover_processing(state, subject, protection, context, operation_key, started) do
    # mutation sentinel: external-recover
    case safe_recover(
           protection.external_effect,
           operation_key,
           subject,
           callback_context(state, context)
         ) do
      {:ok, peer_result} ->
        emit(state, started, :recover_succeeded)
        finalize(state, subject, protection, peer_result, started)

      :absent ->
        emit(state, started, :absence_proven)
        execute_then_settle(state, subject, protection, context, operation_key, started)

      :unknown ->
        ambiguous_recovery(state, started)
    end
  end

  defp execute_then_settle(state, subject, protection, context, operation_key, started) do
    callback_context = callback_context(state, context)

    case safe_execute(protection.external_effect, operation_key, subject, callback_context) do
      {:ok, peer_result} ->
        emit(state, started, :execute_succeeded)
        finalize(state, subject, protection, peer_result, started)

      :unknown ->
        settle_unknown_execute(
          state,
          subject,
          protection,
          operation_key,
          callback_context,
          started
        )
    end
  end

  defp settle_unknown_execute(
         state,
         subject,
         protection,
         operation_key,
         callback_context,
         started
       ) do
    case safe_recover(
           protection.external_effect,
           operation_key,
           subject,
           callback_context
         ) do
      {:ok, peer_result} ->
        emit(state, started, :recover_succeeded)
        finalize(state, subject, protection, peer_result, started)

      :absent ->
        emit(state, started, :external_effect_unavailable)

        {:error,
         Error.new(:external_effect_unavailable, "external effect did not produce an outcome")}

      :unknown ->
        ambiguous_recovery(state, started)
    end
  end

  # mutation sentinel: ambiguous-retry
  defp ambiguous_recovery(state, started) do
    emit(state, started, :outcome_unknown)
    {:error, Error.new(:outcome_unknown, "external effect outcome is unknown")}
  end

  defp finalize(state, subject, protection, peer_result, started) do
    loaded = Store.load(state.target, state.claim)

    case Admission.resolve(
           loaded,
           state,
           protection,
           started,
           :locked_external_finalize
         ) do
      {:execute, locked_state} ->
        emit(locked_state, started, :finalize_locked)

        {:execute, ExternalEffect.put_result(subject, locked_state.claim.id, peer_result),
         locked_state}

      {:replay, replayed, replay_state} ->
        emit(replay_state, started, :replayed)
        {:replay, replayed, replay_state}

      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        unavailable()
    end
  end

  defp lock_replay(state, protection, started) do
    case Admission.resolve(
           Store.load(state.target, state.claim),
           state,
           protection,
           started,
           :locked_external_finalize
         ) do
      {:replay, replayed, replay_state} ->
        emit(replay_state, started, :replayed)
        {:replay, replayed, replay_state}

      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        unavailable()
    end
  end

  defp safe_execute(module, operation_key, subject, context) do
    case module.execute(operation_key, subject, context) do
      {:ok, peer_result} -> {:ok, peer_result}
      {:error, :outcome_unknown} -> :unknown
      _other -> :unknown
    end
  rescue
    _exception -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp safe_recover(module, operation_key, subject, context) do
    case module.recover(operation_key, subject, context) do
      {:ok, peer_result} -> {:ok, peer_result}
      :absent -> :absent
      :unknown -> :unknown
      _other -> :unknown
    end
  rescue
    _exception -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp callback_context(state, trusted_context) do
    trusted_context
    |> Map.take([:actor, :tenant])
    |> Map.merge(%{resource: state.resource, action: state.action})
  end

  defp validate_operation_key(operation_key) when is_binary(operation_key) do
    case Ecto.UUID.cast(operation_key) do
      {:ok, ^operation_key} -> :ok
      _other -> {:error, Error.new(:store_invariant, "store result violated an invariant")}
    end
  end

  defp validate_operation_key(_operation_key),
    do: {:error, Error.new(:store_invariant, "store result violated an invariant")}

  defp emit(state, started, result_class) do
    _result =
      Telemetry.external_recovery(
        System.monotonic_time() - started,
        state.strategy,
        state.resource,
        state.action,
        result_class
      )

    :ok
  end

  defp unavailable,
    do: {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
end
