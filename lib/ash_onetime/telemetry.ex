defmodule AshOnetime.Telemetry do
  @moduledoc """
  Emits the closed, value-free telemetry surface for keyed-effect admission.
  """

  alias AshOnetime.Error

  @strategies [:idempotency, :one_time_nonce]
  @classes %{
    admission: [:admitted, :rejected, :failed],
    conflict: [:complete, :processing, :nonce_used, :malformed],
    replay: [:returned, :rejected],
    fingerprint_mismatch: [:rejected],
    verification: [:verified, :rejected, :timeout],
    encoding: [:stored, :rejected, :rollback, :failed],
    cache: [
      :hit,
      :miss,
      :stale,
      :corrupt,
      :failure,
      :timeout,
      :stored,
      :expired,
      :oversized,
      :disabled
    ],
    cleanup: [:claims_deleted, :partitions_dropped],
    reap: [:claims_reaped],
    external_recovery: [
      :processing_committed,
      :execute_succeeded,
      :recover_succeeded,
      :absence_proven,
      :outcome_unknown,
      :external_effect_unavailable,
      :finalize_locked,
      :replayed
    ],
    store_uncertainty: [:sent, :unknown, :disconnected, :lock_timeout],
    untracked_execution: [:checkout_unavailable]
  }

  @spec admission(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def admission(duration, strategy, resource, action, result_class),
    do: emit(:admission, %{duration: duration}, strategy, resource, action, result_class)

  @spec conflict(atom(), module(), atom(), atom()) :: :ok | {:error, Error.t()}
  def conflict(strategy, resource, action, result_class),
    do: emit(:conflict, %{count: 1}, strategy, resource, action, result_class)

  @spec replay(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def replay(duration, strategy, resource, action, result_class),
    do: emit(:replay, %{duration: duration}, strategy, resource, action, result_class)

  @spec fingerprint_mismatch(atom(), module(), atom()) :: :ok | {:error, Error.t()}
  def fingerprint_mismatch(strategy, resource, action),
    do:
      emit(
        :fingerprint_mismatch,
        %{count: 1},
        strategy,
        resource,
        action,
        :rejected
      )

  @spec verification(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def verification(duration, strategy, resource, action, result_class),
    do: emit(:verification, %{duration: duration}, strategy, resource, action, result_class)

  @spec encoding(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def encoding(duration, strategy, resource, action, result_class),
    do: emit(:encoding, %{duration: duration}, strategy, resource, action, result_class)

  @spec cache(atom(), module(), atom(), atom()) :: :ok | {:error, Error.t()}
  def cache(strategy, resource, action, result_class),
    do: emit(:cache, %{count: 1}, strategy, resource, action, result_class)

  @spec cleanup(atom(), module(), atom(), non_neg_integer(), atom()) ::
          :ok | {:error, Error.t()}
  def cleanup(strategy, resource, action, count, result_class),
    do: emit(:cleanup, %{count: count}, strategy, resource, action, result_class)

  @spec reap(atom(), module(), atom(), non_neg_integer(), atom()) ::
          :ok | {:error, Error.t()}
  def reap(strategy, resource, action, count, result_class),
    do: emit(:reap, %{count: count}, strategy, resource, action, result_class)

  @spec external_recovery(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def external_recovery(duration, strategy, resource, action, result_class),
    do: emit(:external_recovery, %{duration: duration}, strategy, resource, action, result_class)

  @spec store_uncertainty(atom(), module(), atom(), atom()) :: :ok | {:error, Error.t()}
  def store_uncertainty(strategy, resource, action, result_class),
    do: emit(:store_uncertainty, %{count: 1}, strategy, resource, action, result_class)

  @spec untracked_execution(atom(), module(), atom()) :: :ok | {:error, Error.t()}
  def untracked_execution(strategy, resource, action),
    do:
      emit(
        :untracked_execution,
        %{count: 1},
        strategy,
        resource,
        action,
        :checkout_unavailable
      )

  defp emit(event, measurements, strategy, resource, action, result_class) do
    with :ok <- validate_context(strategy, resource, action),
         true <- result_class in Map.fetch!(@classes, event),
         :ok <- validate_measurements(event, measurements) do
      metadata = %{
        strategy: strategy,
        resource: resource,
        action: action,
        result_class: result_class
      }

      :telemetry.execute([:ash_onetime, event], measurements, metadata)
      :ok
    else
      _invalid -> {:error, Error.new(:telemetry_invalid, "telemetry emission is invalid")}
    end
  rescue
    _exception -> {:error, Error.new(:telemetry_invalid, "telemetry emission is invalid")}
  catch
    _kind, _reason -> {:error, Error.new(:telemetry_invalid, "telemetry emission is invalid")}
  end

  defp validate_context(strategy, resource, action) do
    if strategy in @strategies and is_atom(resource) and is_atom(action) do
      :ok
    else
      :error
    end
  end

  defp validate_measurements(event, %{duration: duration})
       when event in [:admission, :replay, :verification, :encoding, :external_recovery] and
              is_integer(duration) and duration >= 0,
       do: :ok

  defp validate_measurements(event, %{count: count})
       when event in [:cleanup, :reap] and is_integer(count) and count >= 0,
       do: :ok

  defp validate_measurements(event, %{count: 1})
       when event in [
              :conflict,
              :fingerprint_mismatch,
              :cache,
              :store_uncertainty,
              :untracked_execution
            ],
       do: :ok

  defp validate_measurements(_event, _measurements), do: :error
end
