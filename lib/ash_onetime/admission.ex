defmodule AshOnetime.Admission do
  @moduledoc false

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshOnetime.{Cache, Error, Fingerprint, Response, Telemetry, Verified}
  alias AshOnetime.Store.{Claim, Postgres, Result}

  @private_state :ash_onetime_admission
  @private_replay :ash_onetime_replay

  defmodule State do
    @moduledoc false
    @enforce_keys [:class, :strategy, :resource, :action]

    defstruct [
      :class,
      :strategy,
      :resource,
      :action,
      :request,
      :target,
      :claim,
      :contract,
      :cache,
      :replayed
    ]

    @type t :: %__MODULE__{
            class: :pending | :execute | :external_execute | :nonce | :untracked | :replay,
            strategy: :idempotency | :one_time_nonce,
            resource: module(),
            action: atom(),
            request: AshOnetime.Store.Claim.Request.t() | nil,
            target: AshOnetime.Store.Postgres.Target.t() | nil,
            claim: AshOnetime.Store.Claim.t() | nil,
            contract: AshOnetime.Response.Contract.t() | nil,
            cache: AshOnetime.Cache.Config.t() | nil,
            replayed: term()
          }
  end

  @spec reserve(Ash.Changeset.t() | Ash.ActionInput.t(), struct(), map()) ::
          {:execute, State.t()}
          | {:execute_untracked, State.t()}
          | {:replay, term(), State.t()}
          | {:error, Error.t()}
  def reserve(subject, protection, trusted_context)
      when is_map(subject) and is_map(protection) and is_map(trusted_context) do
    started = System.monotonic_time()

    with :ok <- reject_reserved(subject),
         :ok <- reject_external_effect(protection),
         {:ok, state} <- prepare_resolved(subject, protection, trusted_context),
         %Result{} = result <- store().claim(state.target, state.request) do
      resolve(
        result,
        %{state | request: sanitize_request(state.request)},
        protection,
        started,
        :local_claim
      )
    else
      {:error, %Error{} = error} ->
        emit_admission(subject, protection, started, :rejected)
        {:error, error}

      %Result{} = result ->
        emit_admission(subject, protection, started, :failed)
        {:error, store_error(result)}

      _other ->
        emit_admission(subject, protection, started, :failed)
        {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
    end
  rescue
    _exception ->
      emit_admission(subject, protection, System.monotonic_time(), :failed)
      {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
  catch
    _kind, _reason ->
      emit_admission(subject, protection, System.monotonic_time(), :failed)
      {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
  end

  def reserve(_subject, _protection, _trusted_context),
    do: {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}

  @doc """
  Reserves a keyed-effect admission with the claim committed INDEPENDENTLY of the action
  transaction (the DPoP §11.1 replay-fence path, ADR-0003).

  Structurally identical to `reserve/3` except the claim commits in its own transaction via
  `Store.claim_committed/2` (a worker process on its own connection, nesting-guarded at
  `Store.Postgres.run_committed_claim_transaction/2`), so an action-body failure cannot roll
  the spend back. The result resolves under `:committed_external_claim` — the existing,
  ADR-0001-blessed mode for an independently-committed claim. A reused proof within the
  acceptance window collides on retry and rejects with `:nonce_already_used` via the existing
  `:collision` decide arm, exactly like the commit-with-action nonce path. See ADR-0003.
  """
  @spec reserve_committed(Ash.Changeset.t() | Ash.ActionInput.t(), struct(), map()) ::
          {:execute, State.t()}
          | {:execute_untracked, State.t()}
          | {:replay, term(), State.t()}
          | {:error, Error.t()}
  def reserve_committed(subject, protection, trusted_context)
      when is_map(subject) and is_map(protection) and is_map(trusted_context) do
    started = System.monotonic_time()

    with :ok <- reject_reserved(subject),
         :ok <- reject_external_effect(protection),
         {:ok, state} <- prepare_resolved(subject, protection, trusted_context),
         %Result{} = result <- store().claim_committed(state.target, state.request) do
      resolve(
        result,
        %{state | request: sanitize_request(state.request)},
        protection,
        started,
        :committed_external_claim
      )
    else
      {:error, %Error{} = error} ->
        emit_admission(subject, protection, started, :rejected)
        {:error, error}

      %Result{} = result ->
        emit_admission(subject, protection, started, :failed)
        {:error, store_error(result)}

      _other ->
        emit_admission(subject, protection, started, :failed)
        {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
    end
  rescue
    _exception ->
      emit_admission(subject, protection, System.monotonic_time(), :failed)
      {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
  catch
    _kind, _reason ->
      emit_admission(subject, protection, System.monotonic_time(), :failed)
      {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
  end

  def reserve_committed(_subject, _protection, _trusted_context),
    do: {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}

  @doc false
  @spec prepare(Ash.Changeset.t() | Ash.ActionInput.t(), struct(), map()) ::
          {:ok, State.t()} | {:error, Error.t()}
  def prepare(subject, protection, trusted_context)
      when is_map(subject) and is_map(protection) and is_map(trusted_context) do
    with :ok <- reject_reserved(subject) do
      prepare_resolved(subject, protection, trusted_context)
    end
  rescue
    _exception ->
      {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
  catch
    _kind, _reason ->
      {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
  end

  def prepare(_subject, _protection, _trusted_context),
    do: {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}

  # Shared reservation dispatch + helpers for the two runtime entry points (Change for
  # create/update/destroy, GenericAction for generic actions). Previously duplicated
  # near-verbatim in both modules (each carried the same mutation-sentinel-acknowledged
  # copies); hoisted here so the two cannot drift. `trusted_context/1` bounds caller
  # context to the keys the reservation paths actually consume (ExternalRecovery reads
  # actor/tenant); it is NOT the bounded_callback_context (that is the verifier/mint/scope
  # callback surface, which is resource/action only — see bounded_callback_context/1).

  @doc false
  def dispatch_reservation(subject, protection, trusted) do
    cond do
      protection.external_effect ->
        AshOnetime.ExternalRecovery.reserve(subject, protection, trusted)

      protection.strategy == :one_time_nonce and protection.commit == :independent ->
        reserve_committed(subject, protection, trusted)

      true ->
        reserve(subject, protection, trusted)
    end
  end

  @doc false
  def trusted_context(context) do
    context
    |> Map.from_struct()
    |> Map.take([:actor, :tenant])
  rescue
    _exception -> %{}
  end

  @doc false
  def unavailable_error,
    do: Error.new(:admission_unavailable, "keyed-effect admission is unavailable")

  @doc false
  def resolve(%Result{} = result, %State{} = state, protection, started, mode)
      when mode in [:local_claim, :committed_external_claim, :locked_external_finalize] do
    decide(result, state, protection, started, mode)
  end

  @spec complete(State.t(), term()) :: {:ok, term()} | {:error, Error.t()}
  def complete(%State{class: class}, result) when class in [:nonce, :untracked, :replay],
    do: {:ok, result}

  def complete(%State{class: class, contract: contract} = state, result)
      when class in [:execute, :external_execute] do
    started = System.monotonic_time()

    case Response.encode(result, contract, []) do
      {:ok, encoded} ->
        persist_completion(state, encoded, started)

      {:reject, _value} ->
        emit_encoding(state, duration(started), :rejected)
        {:error, Error.new(:response_rejected, "response was rejected")}

      {:rollback, _reason} ->
        emit_encoding(state, duration(started), :rollback)
        {:error, Error.new(:response_rollback, "response requires rollback")}

      {:error, %Error{} = error} ->
        emit_encoding(state, duration(started), :failed)
        {:error, error}
    end
  rescue
    _exception -> {:error, Error.new(:response_completion_failed, "response completion failed")}
  catch
    _kind, _reason ->
      {:error, Error.new(:response_completion_failed, "response completion failed")}
  end

  def complete(_state, _result),
    do: {:error, Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}

  defp persist_completion(state, encoded, started) do
    completion = persist_encoded(state, encoded)

    with :ok <- validate_complete(completion, state, encoded),
         :ok <- emit_encoding(state, duration(started), :stored) do
      emit_cache(state, Cache.store(state.cache, completion.claim, encoded.payload))
      {:ok, encoded.result}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp persist_encoded(%State{class: :external_execute} = state, encoded) do
    store().complete_external(
      state.target,
      state.claim,
      encoded.codec,
      encoded.digest,
      encoded.payload
    )
  end

  defp persist_encoded(state, encoded) do
    store().complete(
      state.target,
      state.claim,
      encoded.codec,
      encoded.digest,
      encoded.payload
    )
  end

  @doc false
  @spec replay?(Ash.Changeset.t() | Ash.ActionInput.t()) :: boolean()
  def replay?(%{context: %{private: %{@private_replay => true}}}), do: true
  def replay?(_subject), do: false

  @doc false
  def state(%{context: %{private: %{@private_state => %State{} = state}}}), do: {:ok, state}
  def state(_subject), do: :error

  @doc false
  def put_state(subject, %State{} = state) do
    put_private(subject, @private_state, state)
  end

  @doc false
  def put_replay(subject, %State{} = state) do
    subject
    |> put_state(state)
    |> put_private(@private_replay, true)
  end

  @doc """
  Stamps the caller-visible replayed-vs-fresh signal onto a result record.

  For tracked admission classes (`:execute`, `:external_execute`, `:replay`, `:nonce`),
  the result is stamped with `__metadata__[:ash_onetime][:replayed]` — `true` for a stored
  replay, `false` for a fresh execution — so the outer caller can observe the distinction
  after `Ash.create/2` / `Ash.run_action/2` returns. Non-struct results (primitive
  generic-action returns, destroy `:ok`) carry no `__metadata__` and are returned unchanged,
  so `AshOnetime.replayed?/1` reports `nil` for them.

  The `:untracked` class is deliberately NOT stamped: an untracked execution must remain
  observationally indistinguishable from an unprotected action (ADR 0001 "Failure and safe
  cleanup"), so it returns no `:ash_onetime` metadata and `replayed?/1` reports `nil`.
  """
  @spec stamp_replay(State.t(), term()) :: term()
  def stamp_replay(%State{class: :untracked}, result), do: result

  def stamp_replay(%State{class: class}, result)
      when class in [:execute, :external_execute, :replay, :nonce] do
    case result do
      %{__metadata__: _} = record ->
        Ash.Resource.put_metadata(record, :ash_onetime, %{replayed: class == :replay})

      _other ->
        result
    end
  end

  if Mix.env() == :test do
    @doc false
    def put_test_store(module) when is_atom(module),
      do: Process.put({__MODULE__, :test_store}, module)

    @doc false
    def reset_test_store, do: Process.delete({__MODULE__, :test_store})

    @doc false
    def put_test_state(subject, class, replayed \\ nil) do
      state = %State{
        class: class,
        strategy: :idempotency,
        resource: subject.resource,
        action: subject.action.name,
        replayed: replayed
      }

      if class == :replay, do: put_replay(subject, state), else: put_state(subject, state)
    end
  end

  defp prepare_resolved(subject, protection, trusted_context) do
    with {:ok, operation_hash} <- operation_hash(subject),
         {:ok, scope_hash} <- scope_hash(subject, protection.scope, trusted_context),
         {:ok, key_hash, verified} <-
           key_hash(
             subject,
             protection.key,
             protection.limits,
             trusted_context,
             protection.strategy
           ),
         {:ok, fingerprint} <- request_fingerprint(subject, protection),
         {:ok, contract} <- response_contract(subject, protection),
         {:ok, request} <-
           claim_request(protection, operation_hash, scope_hash, key_hash, fingerprint, verified),
         {:ok, target} <- target(subject) do
      {:ok,
       %State{
         class: :pending,
         strategy: protection.strategy,
         resource: subject.resource,
         action: subject.action.name,
         request: request,
         target: target,
         contract: contract,
         cache: Cache.config(protection.limits)
       }}
    end
  end

  defp reject_reserved(subject) do
    surfaces = [Map.get(subject, :params, %{}), Map.get(subject, :arguments, %{})]

    surfaces =
      case subject do
        %Ash.Changeset{} -> [subject.attributes | surfaces]
        _other -> surfaces
      end

    if Enum.any?(surfaces, &reserved_surface?/1) do
      {:error,
       Error.new(:reserved_verification_input, "reserved verification input is forbidden")}
    else
      :ok
    end
  end

  defp reserved_surface?(surface) when is_map(surface) do
    Enum.any?(AshOnetime.reserved_verification_inputs(), fn key ->
      Map.has_key?(surface, key) or Map.has_key?(surface, to_string(key))
    end)
  end

  defp reserved_surface?(_surface), do: false

  defp reject_external_effect(%{external_effect: nil}), do: :ok

  defp reject_external_effect(_protection),
    do:
      {:error,
       Error.new(:external_recovery_unavailable, "external effect recovery is unavailable")}

  defp operation_hash(subject) do
    Fingerprint.compute(%{
      domain: :operation,
      resource: inspect(subject.resource),
      action: subject.action.name
    })
  end

  defp scope_hash(subject, scope, trusted_context) when is_list(scope) do
    with {:ok, descriptors} <-
           map_ordered(scope, fn component ->
             scope_component(subject, component, trusted_context)
           end) do
      Fingerprint.compute(%{domain: :scope, ordered: descriptors})
    end
  end

  defp scope_hash(_subject, _scope, _trusted_context),
    do: {:error, Error.new(:scope_unavailable, "scope is unavailable")}

  defp scope_component(_subject, {:static, value}, _context),
    do: bounded_descriptor(:static, :static, value)

  defp scope_component(subject, {:argument, name}, _context) do
    with {:ok, value} <- fetch_argument(subject, name) do
      bounded_descriptor(:argument, name, value)
    end
  end

  defp scope_component(%Ash.Changeset{} = subject, {:attribute, name}, _context) do
    bounded_descriptor(:attribute, name, Ash.Changeset.get_attribute(subject, name))
  end

  defp scope_component(subject, {:tenant, module}, _trusted_context) when is_atom(module) do
    context = bounded_callback_context(subject)

    case safe_callback(module, :resolve, [subject, context]) do
      {:ok, value} -> bounded_descriptor(:tenant, inspect(module), value)
      _other -> {:error, Error.new(:scope_unavailable, "scope is unavailable")}
    end
  end

  defp scope_component(_subject, _component, _context),
    do: {:error, Error.new(:scope_unavailable, "scope is unavailable")}

  defp key_hash(subject, key, limits, trusted_context, strategy) when is_list(key) do
    max_key_bytes = Keyword.get(limits || [], :max_key_bytes, 4_096)
    max_token_bytes = Keyword.get(limits || [], :max_token_bytes, 65_536)
    timeout = Keyword.get(limits || [], :verifier_timeout_ms, 30_000)

    with {:ok, resolved} <-
           map_ordered(key, fn source ->
             key_component(
               subject,
               source,
               trusted_context,
               max_key_bytes,
               max_token_bytes,
               timeout,
               strategy
             )
           end),
         descriptors = Enum.map(resolved, &elem(&1, 0)),
         verified = resolved |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1),
         {:ok, hash} <- Fingerprint.compute(%{domain: :key, ordered: descriptors}) do
      {:ok, hash, verified}
    end
  end

  defp key_hash(_subject, _key, _limits, _context, _strategy),
    do: {:error, Error.new(:key_unavailable, "key is unavailable")}

  defp key_component(subject, {kind, name}, _context, max_key, _max_token, _timeout, _strategy)
       when kind in [:client, :argument, :external] do
    with {:ok, value} <- fetch_argument(subject, name),
         :ok <- bounded_binary(value, max_key) do
      {:ok, {%{source: kind, name: name, value: value}, nil}}
    else
      _other -> {:error, Error.new(:key_unavailable, "key is unavailable")}
    end
  end

  defp key_component(
         %Ash.Changeset{} = subject,
         {:attribute, name},
         _context,
         max_key,
         _max_token,
         _timeout,
         _strategy
       ) do
    value = Ash.Changeset.get_attribute(subject, name)

    case bounded_binary(value, max_key) do
      :ok -> {:ok, {%{source: :attribute, name: name, value: value}, nil}}
      _other -> {:error, Error.new(:key_unavailable, "key is unavailable")}
    end
  end

  defp key_component(
         subject,
         {:verified, name, module},
         _context,
         max_key,
         max_token,
         timeout,
         strategy
       ) do
    started = System.monotonic_time()

    with {:ok, token} when is_binary(token) <- fetch_argument(subject, name),
         :ok <- bounded_binary(token, max_token),
         {:ok, %Verified{} = verified} <-
           timed_callback(
             module,
             :verify,
             [token, bounded_callback_context(subject)],
             timeout
           ),
         :ok <- valid_verified(verified, max_key) do
      emit_verification(subject, strategy, started, :verified)

      {:ok,
       {%{source: :verified, name: name, module: inspect(module), value: verified.key}, verified}}
    else
      {:error, :timeout} ->
        emit_verification(subject, strategy, started, :timeout)
        {:error, Error.new(:verification_timeout, "verification timed out")}

      _other ->
        emit_verification(subject, strategy, started, :rejected)
        {:error, Error.new(:verification_failed, "verification failed")}
    end
  end

  defp key_component(
         subject,
         {:minted, module},
         _context,
         max_key,
         _max_token,
         timeout,
         strategy
       ) do
    started = System.monotonic_time()

    with {:ok, %Verified{} = verified} <-
           timed_callback(module, :mint, [bounded_callback_context(subject)], timeout),
         :ok <- valid_verified(verified, max_key) do
      emit_verification(subject, strategy, started, :verified)
      {:ok, {%{source: :minted, module: inspect(module), value: verified.key}, verified}}
    else
      {:error, :timeout} ->
        emit_verification(subject, strategy, started, :timeout)
        {:error, Error.new(:verification_timeout, "verification timed out")}

      _other ->
        emit_verification(subject, strategy, started, :rejected)
        {:error, Error.new(:verification_failed, "verification failed")}
    end
  end

  defp key_component(
         _subject,
         _source,
         _context,
         _max_key,
         _max_token,
         _timeout,
         _strategy
       ),
       do: {:error, Error.new(:key_unavailable, "key is unavailable")}

  defp request_fingerprint(_subject, %{strategy: :one_time_nonce}), do: {:ok, nil}

  defp request_fingerprint(
         subject,
         %{strategy: :idempotency, fingerprint: fingerprint} = protection
       ) do
    with {:ok, arguments} <-
           dump_references(subject, Keyword.get(fingerprint, :arguments, []), :argument),
         {:ok, attributes} <-
           dump_references(subject, Keyword.get(fingerprint, :attributes, []), :attribute) do
      Fingerprint.compute(
        %{
          domain: :request_fingerprint,
          arguments: arguments,
          attributes: attributes
        },
        Keyword.get(protection.limits, :max_fingerprint_bytes, :infinity)
      )
    end
  end

  defp request_fingerprint(_subject, _protection),
    do: {:error, Error.new(:fingerprint_unavailable, "request fingerprint is unavailable")}

  defp dump_references(subject, names, kind) do
    map_ordered(names, fn name ->
      with {:ok, value, type, constraints} <- typed_value(subject, name, kind),
           {:ok, dumped} <- Ash.Type.dump_to_embedded(type, value, constraints) do
        {:ok, %{source: kind, name: name, value: dumped}}
      else
        _other ->
          {:error, Error.new(:fingerprint_unavailable, "request fingerprint is unavailable")}
      end
    end)
  end

  defp typed_value(subject, name, :argument) do
    with {:ok, value} <- fetch_argument(subject, name),
         %{type: type, constraints: constraints} <-
           Enum.find(subject.action.arguments, &(&1.name == name)) do
      {:ok, value, type, constraints}
    else
      _other -> {:error, :missing}
    end
  end

  defp typed_value(%Ash.Changeset{} = subject, name, :attribute) do
    case ResourceInfo.attribute(subject.resource, name) do
      %{type: type, constraints: constraints} ->
        {:ok, Ash.Changeset.get_attribute(subject, name), type, constraints}

      _other ->
        {:error, :missing}
    end
  end

  defp typed_value(_subject, _name, :attribute), do: {:error, :missing}

  defp response_contract(_subject, %{strategy: :one_time_nonce}), do: {:ok, nil}

  defp response_contract(subject, %{strategy: :idempotency, response: response} = protection) do
    trusted =
      if(subject.action.type == :destroy, do: %{return_destroyed?: true}, else: %{})
      |> put_result_tenant(subject)
      |> Map.put(:limits, protection.limits)

    Response.contract(subject.resource, subject.action.name, response, trusted)
  end

  defp put_result_tenant(trusted, subject) do
    case Map.get(subject, :to_tenant) do
      nil -> trusted
      tenant -> Map.put(trusted, :tenant, tenant)
    end
  end

  defp claim_request(protection, operation_hash, scope_hash, key_hash, fingerprint, verified) do
    attributes = [operation_hash: operation_hash, scope_hash: scope_hash, key_hash: key_hash]

    case protection.strategy do
      :idempotency ->
        Claim.idempotency(
          attributes ++ [fingerprint: fingerprint, retention_seconds: protection.retention]
        )

      :one_time_nonce ->
        Claim.nonce(
          attributes ++
            [
              verified: verified,
              max_age: Keyword.fetch!(protection.window, :max_age),
              clock_skew: Keyword.fetch!(protection.window, :clock_skew)
            ]
        )
    end
    |> case do
      {:ok, request} -> {:ok, request}
      _other -> {:error, Error.new(:admission_request_invalid, "admission request is invalid")}
    end
  end

  defp target(subject) do
    options = [
      data_layer_context: get_in(subject.context, [:data_layer]),
      tenant: Map.get(subject, :to_tenant)
    ]

    case Postgres.target(subject.resource, options) do
      {:ok, target} -> {:ok, target}
      %Result{} = result -> result
    end
  end

  defp decide(%Result{status: :admitted} = result, state, _protection, started, mode) do
    transaction = expected_transaction(mode)

    with :ok <- validate_admitted(result, state.request, transaction) do
      class = execution_class(state.strategy, mode)
      state = %{state | class: class, claim: sanitize_claim(result.claim)}
      emit_admission(state, started, :admitted)
      {:execute, state}
    end
  end

  defp decide(
         %Result{status: :complete} = result,
         %{strategy: :idempotency} = state,
         _protection,
         started,
         mode
       ) do
    with {:ok, disposition} <-
           validate_collision(result, state.request, expected_transaction(mode)),
         :match <- disposition,
         {:ok, replayed} <- replay(result, state, started) do
      emit_conflict(state, :complete)
      emit_admission(state, started, :admitted)
      replay_state = %{state | class: :replay, claim: result.claim, replayed: replayed}
      {:replay, replayed, replay_state}
    else
      :fingerprint_mismatch ->
        emit_fingerprint_mismatch(state)

        {:error,
         Error.new(:key_reused_with_different_request, "key was reused with a different request")}

      {:error, %Error{} = error} ->
        emit_conflict(state, :malformed)
        {:error, error}
    end
  end

  defp decide(
         %Result{status: :processing} = result,
         %{strategy: :idempotency} = state,
         _protection,
         _started,
         mode
       ) do
    with {:ok, disposition} <-
           validate_collision(result, state.request, expected_transaction(mode)),
         :match <- disposition do
      emit_conflict(state, :processing)

      case mode do
        :local_claim ->
          {:error, Error.new(:request_in_progress, "request is already processing")}

        :committed_external_claim ->
          {:recover, %{state | claim: sanitize_claim(result.claim)}}

        :locked_external_finalize ->
          {:execute, %{state | class: :external_execute, claim: sanitize_claim(result.claim)}}
      end
    else
      :fingerprint_mismatch ->
        emit_fingerprint_mismatch(state)

        {:error,
         Error.new(:key_reused_with_different_request, "key was reused with a different request")}

      _other ->
        {:error, Error.new(:store_invariant, "store result violated an invariant")}
    end
  end

  defp decide(
         %Result{status: :collision} = result,
         %{strategy: :one_time_nonce} = state,
         _protection,
         _started,
         mode
       ) do
    case validate_collision(result, state.request, expected_transaction(mode)) do
      {:ok, :match} ->
        emit_conflict(state, :nonce_used)
        {:error, Error.new(:nonce_already_used, "nonce was already used")}

      _other ->
        emit_conflict(state, :malformed)
        {:error, Error.new(:store_invariant, "store result violated an invariant")}
    end
  end

  defp decide(
         %Result{
           status: :failure,
           reason: :checkout_unavailable,
           admission_dispatch: :not_started,
           transaction: :not_applicable,
           claim: nil,
           payload: nil
         },
         %{strategy: :idempotency} = state,
         %{on_definite_store_failure: :execute_untracked},
         started,
         :local_claim
       ) do
    state = %{state | class: :untracked}
    emit_untracked_execution(state)
    emit_admission(state, started, :admitted)
    {:execute_untracked, state}
  end

  defp decide(%Result{} = result, state, _protection, _started, _mode) do
    emit_uncertainty(result, state)
    {:error, store_error(result)}
  end

  defp expected_transaction(:committed_external_claim), do: :committed

  defp expected_transaction(mode) when mode in [:local_claim, :locked_external_finalize],
    do: :open

  defp execution_class(:one_time_nonce, :local_claim), do: :nonce

  # The committed-nonce burn-marker (ADR-0003 DPoP replay fence). Maps to :nonce, NOT
  # :external_execute — a burn-marker has no stored response to persist, and :nonce routes
  # through complete/2's nonce short-circuit (returns {:ok, result} with no persistence).
  defp execution_class(:one_time_nonce, :committed_external_claim), do: :nonce

  defp execution_class(:idempotency, :committed_external_claim), do: :external_execute
  defp execution_class(:idempotency, :locked_external_finalize), do: :external_execute
  defp execution_class(:idempotency, :local_claim), do: :execute

  defp replay(result, state, started) do
    {result, cache_status} = Cache.authoritative_payload(result, state.cache)
    emit_cache(state, cache_status)

    case Response.replay(result, state.contract, []) do
      {:ok, replayed} ->
        if cache_status != :hit do
          emit_cache(state, Cache.store(state.cache, result.claim, result.payload))
        end

        emit_replay(state, duration(started), :returned)
        {:ok, replayed}

      {:error, %Error{} = error} ->
        emit_replay(state, duration(started), :rejected)
        {:error, error}
    end
  end

  defp validate_admitted(
         %Result{
           status: :admitted,
           reason: nil,
           admission_dispatch: :sent,
           transaction: transaction,
           payload: nil,
           claim: %Claim{} = claim
         },
         request,
         expected_transaction
       ) do
    with true <- transaction == expected_transaction,
         :ok <- validate_locator(claim, request),
         true <- claim.id == request.id,
         :match <- fingerprint_disposition(claim, request),
         :ok <- validate_claim_state(claim, :admitted) do
      :ok
    else
      _other -> {:error, Error.new(:store_invariant, "store result violated an invariant")}
    end
  end

  defp validate_admitted(_result, _request, _expected_transaction),
    do: {:error, Error.new(:store_invariant, "store result violated an invariant")}

  defp validate_collision(
         %Result{
           status: status,
           reason: nil,
           admission_dispatch: :sent,
           transaction: transaction,
           payload: payload,
           claim: %Claim{} = claim
         } = result,
         request,
         expected_transaction
       ) do
    with true <- transaction == expected_transaction,
         true <- valid_uuid?(claim.id),
         :ok <- validate_collision_payload(status, payload),
         :ok <- validate_locator(claim, request),
         :ok <- validate_claim_state(claim, result.status) do
      {:ok, fingerprint_disposition(claim, request)}
    else
      _other -> {:error, Error.new(:store_invariant, "store result violated an invariant")}
    end
  end

  defp validate_collision(_result, _request, _expected_transaction),
    do: {:error, Error.new(:store_invariant, "store result violated an invariant")}

  defp validate_collision_payload(:complete, payload) when is_binary(payload), do: :ok
  defp validate_collision_payload(status, nil) when status in [:processing, :collision], do: :ok
  defp validate_collision_payload(_status, _payload), do: :error

  defp validate_complete(
         %Result{
           status: :complete,
           reason: nil,
           admission_dispatch: :sent,
           transaction: :open,
           payload: payload,
           claim: %Claim{} = claim
         },
         state,
         encoded
       )
       when is_binary(payload) do
    with :ok <- validate_locator(claim, state.request),
         true <- claim.id == state.claim.id,
         :match <- fingerprint_disposition(claim, state.request),
         :ok <- validate_claim_state(claim, :complete),
         true <- claim.response_codec == encoded.codec,
         true <- payload == encoded.payload,
         true <- fixed_digest_equal?(claim.response_digest, encoded.digest),
         true <- fixed_digest_equal?(:crypto.hash(:sha256, payload), encoded.digest) do
      :ok
    else
      _other -> {:error, Error.new(:store_invariant, "store result violated an invariant")}
    end
  end

  defp validate_complete(_result, _state, _encoded),
    do: {:error, Error.new(:store_invariant, "store result violated an invariant")}

  defp fixed_digest_equal?(left, right)
       when is_binary(left) and byte_size(left) == 32 and is_binary(right) and
              byte_size(right) == 32,
       do: :crypto.hash_equals(left, right)

  defp fixed_digest_equal?(_left, _right), do: false

  defp validate_locator(claim, request) do
    if claim.strategy == request.strategy and valid_locator_hashes?(claim, request) and
         equal_locator_hashes?(claim, request) do
      :ok
    else
      :error
    end
  end

  defp valid_locator_hashes?(claim, request) do
    Enum.all?(
      [
        claim.operation_hash,
        claim.scope_hash,
        claim.key_hash,
        request.operation_hash,
        request.scope_hash,
        request.key_hash
      ],
      &valid_hash?/1
    )
  end

  defp equal_locator_hashes?(claim, request) do
    :crypto.hash_equals(claim.operation_hash, request.operation_hash) and
      :crypto.hash_equals(claim.scope_hash, request.scope_hash) and
      :crypto.hash_equals(claim.key_hash, request.key_hash)
  end

  defp fingerprint_disposition(%Claim{strategy: :one_time_nonce, fingerprint: nil}, %{
         fingerprint: nil
       }),
       do: :match

  defp fingerprint_disposition(%Claim{fingerprint: left}, %{fingerprint: right})
       when is_binary(left) and byte_size(left) == 32 and is_binary(right) and
              byte_size(right) == 32 do
    if :crypto.hash_equals(left, right), do: :match, else: :fingerprint_mismatch
  end

  defp fingerprint_disposition(_claim, _request), do: :invalid

  defp validate_claim_state(
         %Claim{
           strategy: :idempotency,
           state: :processing,
           response_partition: nil,
           response_codec: nil,
           response_digest: nil,
           issued_at: nil,
           expires_at: nil,
           verifier_id: nil
         },
         status
       )
       when status in [:admitted, :processing],
       do: :ok

  defp validate_claim_state(
         %Claim{
           strategy: :idempotency,
           state: :complete,
           response_partition: %Date{},
           response_codec: codec,
           response_digest: digest,
           issued_at: nil,
           expires_at: nil,
           verifier_id: nil
         },
         :complete
       )
       when is_binary(codec) and is_binary(digest) and byte_size(digest) == 32,
       do: :ok

  defp validate_claim_state(
         %Claim{
           strategy: :one_time_nonce,
           state: nil,
           fingerprint: nil,
           response_partition: nil,
           response_codec: nil,
           response_digest: nil,
           issued_at: %DateTime{},
           expires_at: expires_at,
           verifier_id: verifier_id
         },
         status
       )
       when (is_nil(expires_at) or is_struct(expires_at, DateTime)) and is_binary(verifier_id) and
              byte_size(verifier_id) > 0 and byte_size(verifier_id) <= 128 and
              status in [:admitted, :collision],
       do: :ok

  defp validate_claim_state(%Claim{strategy: :one_time_nonce, state: nil}, status)
       when status in [:admitted, :collision],
       do: :error

  defp validate_claim_state(_claim, _status), do: :error

  defp valid_hash?(value), do: is_binary(value) and byte_size(value) == 32
  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp store_error(%Result{reason: reason}) do
    Error.new(reason || :store_failure, "authoritative admission store failed")
  end

  defp emit_uncertainty(%Result{reason: reason}, state) do
    result_class =
      case reason do
        :lock_timeout -> :lock_timeout
        :disconnected -> :disconnected
        :worker_timeout -> :worker_timeout
        :dispatched_unknown -> :unknown
        _other -> nil
      end

    if result_class, do: emit_store_uncertainty(state, result_class)
  end

  defp emit_admission(%{resource: resource, action: %{name: action}}, protection, started, class) do
    if protection.strategy in [:idempotency, :one_time_nonce] do
      emit(Telemetry.admission(duration(started), protection.strategy, resource, action, class))
    end
  end

  defp emit_admission(_subject, _protection, _started, _class), do: :ok

  defp emit_admission(%State{} = state, started, class),
    do:
      emit(
        Telemetry.admission(
          duration(started),
          state.strategy,
          state.resource,
          state.action,
          class
        )
      )

  defp emit_conflict(state, class),
    do: emit(Telemetry.conflict(state.strategy, state.resource, state.action, class))

  defp emit_verification(subject, strategy, started, class) do
    emit(
      Telemetry.verification(
        duration(started),
        strategy,
        subject.resource,
        subject.action.name,
        class
      )
    )
  end

  defp emit_encoding(state, elapsed, class),
    do: emit(Telemetry.encoding(elapsed, state.strategy, state.resource, state.action, class))

  defp emit_fingerprint_mismatch(state),
    do: emit(Telemetry.fingerprint_mismatch(state.strategy, state.resource, state.action))

  defp emit_replay(state, elapsed, class),
    do: emit(Telemetry.replay(elapsed, state.strategy, state.resource, state.action, class))

  defp emit_store_uncertainty(state, class),
    do: emit(Telemetry.store_uncertainty(state.strategy, state.resource, state.action, class))

  defp emit_untracked_execution(state),
    do: emit(Telemetry.untracked_execution(state.strategy, state.resource, state.action))

  defp emit_cache(state, class),
    do: emit(Telemetry.cache(state.strategy, state.resource, state.action, class))

  defp emit(:ok), do: :ok
  defp emit({:error, %Error{} = error}), do: {:error, error}

  defp duration(started), do: System.monotonic_time() - started

  defp target_context(subject),
    do: %{resource: subject.resource, action: subject.action.name}

  # The bounded callback context exposed as a @doc false public function for deterministic
  # contract testing (the verifier/mint/scope callbacks receive this map). Testing it through
  # the full reserve path flakes under full-suite async DB contention; this direct entry lets
  # the contract pin run with zero DB/Ash-action dependency.
  @doc false
  def bounded_callback_context(subject), do: target_context(subject)

  defp bounded_descriptor(source, name, value) do
    case AshOnetime.Canonical.encode(value) do
      {:ok, _encoded} -> {:ok, %{source: source, name: name, value: value}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp bounded_binary(value, maximum)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum,
       do: :ok

  defp bounded_binary(_value, _maximum), do: :error

  defp sanitize_request(%Claim.Request{strategy: :one_time_nonce} = request),
    do: %{request | verified: nil, clock: nil}

  defp sanitize_request(%Claim.Request{} = request), do: request

  defp sanitize_claim(%Claim{strategy: :one_time_nonce} = claim),
    do: %{claim | verifier_id: nil}

  defp sanitize_claim(%Claim{} = claim), do: claim

  defp valid_verified(%Verified{} = verified, max_key) do
    with :ok <- bounded_binary(verified.key, max_key),
         %DateTime{} <- verified.issued_at,
         true <- is_nil(verified.expires_at) or match?(%DateTime{}, verified.expires_at),
         :ok <- bounded_binary(verified.verifier_id, 128) do
      :ok
    else
      _other -> :error
    end
  end

  defp fetch_argument(%Ash.ActionInput{} = subject, name),
    do: Ash.ActionInput.fetch_argument(subject, name)

  defp fetch_argument(%Ash.Changeset{} = subject, name),
    do: Ash.Changeset.fetch_argument(subject, name)

  defp map_ordered(values, callback) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case callback.(value) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp timed_callback(module, function, arguments, timeout) do
    task = Task.async(fn -> safe_callback(module, function, arguments) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp safe_callback(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _exception -> {:error, :callback_failed}
  catch
    _kind, _reason -> {:error, :callback_failed}
  end

  defp put_private(%Ash.ActionInput{} = subject, key, value),
    do: Ash.ActionInput.set_context(subject, %{private: %{key => value}})

  defp put_private(%Ash.Changeset{} = subject, key, value),
    do: Ash.Changeset.set_context(subject, %{private: %{key => value}})

  if Mix.env() == :test do
    defp store, do: Process.get({__MODULE__, :test_store}) || AshOnetime.Store
  else
    defp store, do: AshOnetime.Store
  end
end
