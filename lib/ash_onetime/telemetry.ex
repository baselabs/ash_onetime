defmodule AshOnetime.Telemetry do
  @moduledoc """
  Emits the closed, value-free telemetry surface for keyed-effect admission.

  ## Out-of-the-box metrics attachment

  The library emits events but does NOT attach a handler — a fresh application sees nothing
  until it attaches one. Call `attach/0` (or `attach/1` with options) from your application
  startup (e.g. your `start/2` callback's supervised children, after the repo is started) to
  attach the default handler, which routes the closed event surface into standard
  `Telemetry.Metrics` counter and summary definitions. This mirrors `Oban.Telemetry.attach_default_logger/1`
  and `Ash.Telemetry` — an opt-in helper so a consumer does not hand-roll a handler.

      # in your application startup, once per VM
      AshOnetime.Telemetry.attach()

  If you already maintain a `Telemetry.Metrics` reporter (StatsD, Prometheus), you may prefer
  to declare the metric definitions in your own `MyApp.Telemetry` rather than using this
  helper — see `metrics/0` for the canonical definition list the helper attaches.
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
    cleanup: [:claims_deleted, :partitions_dropped, :partitions_created],
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
    store_uncertainty: [:sent, :unknown, :disconnected, :lock_timeout, :worker_timeout],
    untracked_execution: [:checkout_unavailable]
  }

  # Events that carry :duration — summarized as a distribution/summary. The rest carry :count
  # (always 1) and are counted.
  @duration_events [:admission, :replay, :verification, :encoding, :external_recovery]

  defp events, do: Map.keys(@classes)

  @doc """
  Emits `[:ash_onetime, :admission]` with `:duration` and `result_class` in
  `[:admitted, :rejected, :failed]`. The classified outcome of an admission attempt.
  """
  @spec admission(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def admission(duration, strategy, resource, action, result_class),
    do: emit(:admission, %{duration: duration}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :conflict]` with `result_class` in
  `[:complete, :processing, :nonce_used, :malformed]`. A collision on an in-flight or
  completed claim under the same logical key.
  """
  @spec conflict(atom(), module(), atom(), atom()) :: :ok | {:error, Error.t()}
  def conflict(strategy, resource, action, result_class),
    do: emit(:conflict, %{count: 1}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :replay]` with `:duration` and `result_class` in
  `[:returned, :rejected]`. The replayed-vs-rejected decision on a stored response.
  """
  @spec replay(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def replay(duration, strategy, resource, action, result_class),
    do: emit(:replay, %{duration: duration}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :fingerprint_mismatch]` with `result_class: :rejected`. A stored
  response whose fingerprint does not match the incoming request is rejected (no replay).
  """
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

  @doc """
  Emits `[:ash_onetime, :verification]` with `:duration` and `result_class` in
  `[:verified, :rejected, :timeout]`. The outcome of a token/proof verification.
  """
  @spec verification(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def verification(duration, strategy, resource, action, result_class),
    do: emit(:verification, %{duration: duration}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :encoding]` with `:duration` and `result_class` in
  `[:stored, :rejected, :rollback, :failed]`. The outcome of encoding a response payload
  for storage/replay.
  """
  @spec encoding(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def encoding(duration, strategy, resource, action, result_class),
    do: emit(:encoding, %{duration: duration}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :cache]` with `result_class` in
  `[:hit, :miss, :stale, :corrupt, :failure, :timeout, :stored, :expired, :oversized, :disabled]`.
  The optional completed-response cache outcome for an idempotency admission.
  """
  @spec cache(atom(), module(), atom(), atom()) :: :ok | {:error, Error.t()}
  def cache(strategy, resource, action, result_class),
    do: emit(:cache, %{count: 1}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :cleanup]` with `:count` and `result_class` in
  `[:claims_deleted, :partitions_dropped, :partitions_created]`. A bounded cleanup run.
  """
  @spec cleanup(atom(), module(), atom(), non_neg_integer(), atom()) ::
          :ok | {:error, Error.t()}
  def cleanup(strategy, resource, action, count, result_class),
    do: emit(:cleanup, %{count: count}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :reap]` with `:count` and `result_class: :claims_reaped`. The count
  of abandoned `processing` recovery points reaped by a bounded reaper run.
  """
  @spec reap(atom(), module(), atom(), non_neg_integer(), atom()) ::
          :ok | {:error, Error.t()}
  def reap(strategy, resource, action, count, result_class),
    do: emit(:reap, %{count: count}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :external_recovery]` with `:duration` and `result_class` in
  `[:processing_committed, :execute_succeeded, :recover_succeeded, :absence_proven,
  :outcome_unknown, :external_effect_unavailable, :finalize_locked, :replayed]`. The stage
  outcomes of the committed external-effect recovery protocol.
  """
  @spec external_recovery(non_neg_integer(), atom(), module(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def external_recovery(duration, strategy, resource, action, result_class),
    do: emit(:external_recovery, %{duration: duration}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :store_uncertainty]` with `result_class` in
  `[:sent, :unknown, :disconnected, :lock_timeout, :worker_timeout]`. The authoritative-state-
  unavailable conditions on the committed-claim path; all fail closed (see operations.md).
  """
  @spec store_uncertainty(atom(), module(), atom(), atom()) :: :ok | {:error, Error.t()}
  def store_uncertainty(strategy, resource, action, result_class),
    do: emit(:store_uncertainty, %{count: 1}, strategy, resource, action, result_class)

  @doc """
  Emits `[:ash_onetime, :untracked_execution]` with `result_class: :checkout_unavailable`.
  An idempotent action executed without a stored admission after a checkout failure — correct
  by design but worth visibility (the optional `:execute_untracked` path).
  """
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

  # ---------------------------------------------------------------------------
  # Out-of-the-box metrics attachment (ROADMAP H21)
  # ---------------------------------------------------------------------------

  @default_handler_id "ash-onetime-default-metrics"

  @doc """
  The unique id used to attach the default metrics handler.

  Without an argument the id is the constant `"ash-onetime-default-metrics"`. When a name
  is provided the id is suffixed with the inspected name, which allows multiple scoped
  handlers (e.g. one per OTP node in a multi-node setup) to coexist.
  """
  @spec handler_id(term()) :: binary()
  def handler_id(name \\ nil)
  def handler_id(nil), do: @default_handler_id
  def handler_id(name), do: "#{@default_handler_id}-#{inspect(name)}"

  @doc """
  Attaches the default metrics handler to the closed `[:ash_onetime, *]` event surface.

  The handler re-emits each event as a downstream `[:ash_onetime, event, :metric]` event
  carrying the same atoms-only metadata and a normalized `:count` or `:duration` measurement.
  This gives a consumer a single attach point to consume via their own `Telemetry.Metrics`
  reporter or custom aggregation, without hand-rolling the event list and the count/duration
  split.

  The handler is a pure router — it adds no state and emits nothing the upstream validator did
  not already permit, so the value-free guarantee is preserved. It does NOT depend on
  `telemetry_metrics`; a consumer running a `Telemetry.Metrics` reporter declares the metric
  definitions in their own `MyApp.Telemetry` (see the `documentation/telemetry.md` runnable
  example for the canonical counter/summary definitions).

  Idempotent per `name` — safe to call once at boot; a second attach with the same name
  returns `{:error, :already_exists}` without detaching the first.

  ## Options

    * `:name` — scope the handler to a unique id (default `nil`, one handler per VM). Use a
      distinct name to attach alongside another consumer's handler.

  ## Examples

      # once at boot, in your app's start/2 after the repo starts
      AshOnetime.Telemetry.attach()

      # attach a second, separately-scoped handler
      AshOnetime.Telemetry.attach(name: :edge)

  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    name = Keyword.get(opts, :name)
    event_names = for event <- events(), do: [:ash_onetime, event]

    :telemetry.attach_many(
      handler_id(name),
      event_names,
      &__MODULE__.handle_event/4,
      opts
    )
  end

  @doc """
  Undoes `attach/1` by detaching the handler.

  Pass the same `:name` used when attaching to detach a scoped handler.

  ## Examples

      :ok = AshOnetime.Telemetry.attach()
      :ok = AshOnetime.Telemetry.detach()

      :ok = AshOnetime.Telemetry.attach(name: :edge)
      :ok = AshOnetime.Telemetry.detach(name: :edge)

  """
  @spec detach(keyword()) :: :ok | {:error, :not_found}
  def detach(opts \\ []) do
    name = Keyword.get(opts, :name)
    :telemetry.detach(handler_id(name))
  end

  @doc false
  @spec handle_event([atom()], map(), map(), keyword()) :: :ok
  def handle_event([:ash_onetime, event], measurements, metadata, _opts) do
    # The default handler is a thin router: it re-emits each event as a downstream
    # [:ash_onetime, event, :metric] event carrying the same atoms-only metadata and a
    # normalized :count or :duration measurement. A consumer attaches their own aggregator
    # (Telemetry.Metrics reporter, a custom handler, an ETS counter) to the :metric events.
    # The metadata passes through unchanged — the value-free guarantee is preserved because
    # this handler emits nothing the upstream validator did not already permit.
    measurement =
      cond do
        event in @duration_events -> %{duration: Map.get(measurements, :duration, 0)}
        true -> %{count: Map.get(measurements, :count, 1)}
      end

    :telemetry.execute([:ash_onetime, event, :metric], measurement, metadata)
    :ok
  end
end
