defmodule AshOnetime.ExternalRecovery do
  @moduledoc false

  alias AshOnetime.{Admission, Delivery, Error, ExternalEffect, Telemetry}
  alias AshOnetime.Store
  alias AshOnetime.Store.Result

  # The pre-peer claim lock's default wait (ADR-0010): comfortably longer than a local
  # finalize, far shorter than a peer call, and well under the committed-claim worker's
  # 30s ceiling. Overridable per protection via `external_lock_timeout_ms`.
  @default_claim_lock_timeout 2_000

  @spec reserve(Ash.Changeset.t() | Ash.ActionInput.t(), struct(), map(), map() | nil) ::
          {:execute, Ash.Changeset.t() | Ash.ActionInput.t(), Admission.State.t()}
          | {:replay, term(), Admission.State.t()}
          | {:error, Error.t()}
  def reserve(
        subject,
        %{strategy: :idempotency, external_effect: module} = protection,
        context,
        delivery
      )
      when is_atom(module) and is_map(context) do
    started = System.monotonic_time()

    with {:ok, state} <- Admission.prepare(subject, protection, context),
         %Result{} = committed <-
           Store.claim_committed(state.target, state.request, claim_lock_options(protection)) do
      case committed do
        # The same-key retry's worker blocked on the original's pre-peer claim lock past the
        # configured wait (ADR-0010): the external path now reports the local path's
        # concurrent-retry semantic instead of racing into a second peer execute.
        %Result{status: :failure, reason: reason}
        when reason in [:lock_timeout, :request_in_progress] ->
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

          continue(decision, subject, protection, context, started, delivery)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def reserve(_subject, _protection, _context, _delivery), do: unavailable()

  defp continue({:execute, state}, subject, protection, context, started, delivery) do
    emit(state, started, :processing_committed)
    operation_key = state.claim.id

    with :ok <- validate_operation_key(operation_key) do
      # rule:pre-peer-lock-removed
      case lock_for_peer(state, protection, started) do
        {:ok, locked} ->
          execute_then_settle(
            locked,
            subject,
            protection,
            context,
            operation_key,
            started,
            delivery
          )

        other ->
          other
      end
    end
  end

  # rule:external-operation-key
  defp continue({:recover, state}, subject, protection, context, started, delivery) do
    operation_key = state.claim.id

    with :ok <- validate_operation_key(operation_key) do
      case lock_for_peer(state, protection, started) do
        {:ok, locked} ->
          recover_processing(
            locked,
            subject,
            protection,
            context,
            operation_key,
            started,
            delivery
          )

        other ->
          other
      end
    end
  end

  defp continue({:replay, _replayed, state}, _subject, protection, _context, started, _delivery) do
    lock_replay(state, protection, started)
  end

  defp continue({:error, %Error{} = error}, _subject, _protection, _context, _started, _delivery),
    do: {:error, error}

  defp continue(_decision, _subject, _protection, _context, _started, _delivery),
    do: unavailable()

  # Before any peer call, lock the claim in the caller transaction with a bounded wait.
  # Re-resolve the full locator: processing proceeds, complete replays, and missing fails closed.
  # A contended same-key retry returns :request_in_progress.
  # The claim-id binding rejects a reaped-and-reinserted row (ADR 0010).
  defp lock_for_peer(state, protection, started) do
    case Store.lock_for_effect(state.target, state.claim, claim_lock_options(protection)) do
      %Result{status: :failure, reason: reason}
      when reason in [:lock_timeout, :request_in_progress] ->
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

  defp recover_processing(state, subject, protection, context, operation_key, started, delivery) do
    # mutation sentinel: external-recover
    case safe_recover(
           protection.external_effect,
           operation_key,
           subject,
           callback_context(state, context)
         ) do
      {:ok, peer_result} ->
        emit(state, started, :recover_succeeded)
        finalize(state, subject, protection, peer_result, started, :recovered)

      :absent ->
        emit(state, started, :absence_proven)

        execute_then_settle(
          state,
          subject,
          protection,
          context,
          operation_key,
          started,
          delivery
        )

      # rule:ambiguous-retry
      :unknown ->
        ambiguous_recovery(state, protection, started)
    end
  end

  defp execute_then_settle(state, subject, protection, context, operation_key, started, delivery) do
    callback_context = callback_context(state, context)

    case safe_execute(
           protection.external_effect,
           operation_key,
           subject,
           callback_context,
           delivery
         ) do
      {:ok, peer_result} ->
        # rule:r11
        emit(state, started, :execute_succeeded)
        finalize(state, subject, protection, peer_result, started, :executed)

      # -- end-rule:r11

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
        finalize(state, subject, protection, peer_result, started, :recovered)

      :absent ->
        emit(state, started, :external_effect_unavailable)

        publish_outcome(
          state,
          protection,
          :absent_proven,
          Error.new(:external_effect_unavailable, "external effect did not produce an outcome"),
          started
        )

      # rule:ambiguous-retry-settle
      :unknown ->
        ambiguous_recovery(state, protection, started)
    end
  end

  # mutation sentinel: ambiguous-retry
  defp ambiguous_recovery(state, protection, started) do
    emit(state, started, :outcome_unknown)

    publish_outcome(
      state,
      protection,
      :held,
      Error.new(:outcome_unknown, "external effect outcome is unknown"),
      started
    )
  end

  defp publish_outcome(state, protection, outcome, error, started) do
    case Store.record_outcome_committed(
           state.target,
           state.claim,
           outcome,
           Keyword.put(
             claim_lock_options(protection),
             :telemetry_context,
             {state.resource, state.action}
           )
         ) do
      %Result{status: :processing, transaction: :committed} ->
        {:error, error}

      %Result{status: :failure, reason: :store_invariant} ->
        {:error, Error.new(:store_invariant, "duplicate outcome for a granted attempt")}

      _ ->
        emit(state, started, :outcome_unrecorded)
        {:error, error}
    end
  end

  defp finalize(state, subject, protection, peer_result, started, source) do
    case resolve_finalization_claim(state, protection, started) do
      {:execute, locked_state} ->
        emit(locked_state, started, :finalize_locked)

        {:execute, ExternalEffect.put_result(subject, locked_state.claim.id, peer_result),
         %{locked_state | delivery_source: source}}

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
    case resolve_finalization_claim(state, protection, started) do
      {:replay, replayed, replay_state} ->
        emit(replay_state, started, :replayed)
        {:replay, replayed, replay_state}

      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        unavailable()
    end
  end

  defp resolve_finalization_claim(state, protection, started) do
    case Store.load(state.target, state.claim, claim_lock_options(protection)) do
      %Result{status: :failure, reason: reason}
      when reason in [:lock_timeout, :request_in_progress] ->
        emit_claim_lock_conflict(state)
        {:error, Error.new(:request_in_progress, "a request for this key is already processing")}

      %Result{} = loaded ->
        Admission.resolve(loaded, state, protection, started, :locked_external_finalize)
    end
  end

  defp safe_execute(module, operation_key, subject, context, nil) do
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

  defp safe_execute(module, operation_key, subject, context, delivery) do
    case module.execute(operation_key, subject, context) do
      {:ok, peer_result, values} ->
        if Delivery.seal(delivery, values) == :ok, do: {:ok, peer_result}, else: :unknown

      _other ->
        :unknown
    end
  rescue
    _exception -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp safe_recover(module, operation_key, subject, context) do
    # rule:external-recover
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
    # rule:r_iso_o3
    _result =
      Telemetry.external_recovery(
        System.monotonic_time() - started,
        state.strategy,
        # -- end-rule:r_iso_o3
        state.resource,
        state.action,
        result_class
      )

    :ok
  end

  defp unavailable,
    do: {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
end
