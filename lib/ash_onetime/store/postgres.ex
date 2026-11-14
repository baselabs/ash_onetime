defmodule AshOnetime.Store.Postgres do
  @moduledoc false

  @behaviour AshOnetime.Store

  alias AshOnetime.Store.{Claim, Result}
  alias AshOnetime.Store.Claim.Request
  alias Ecto.Adapters.SQL

  @payload_ceiling 16_777_216
  @max_retention_seconds 2_147_483_647
  @max_codec_bytes 128
  @committed_claim_timeout 30_000
  # Headroom under the worker kill so a contended claim lock fails with :lock_timeout
  # (mapped to :request_in_progress) rather than the parent's :worker_timeout (ADR-0010).
  @max_claim_lock_timeout 25_000
  @default_logical_partition "global"
  @max_logical_partition_bytes 255
  @phase_key {__MODULE__, :admission_phase}
  @logical_key_predicate "logical_partition = $1 AND operation_hash = $2 AND scope_hash = $3 AND key_hash = $4"
  @completion_key_predicate "logical_partition = $4 AND operation_hash = $5 AND scope_hash = $6 AND key_hash = $7"

  defmodule Target do
    @moduledoc false

    @enforce_keys [:repo_module, :dynamic_repo, :logical_partition]
    defstruct [
      :repo_module,
      :dynamic_repo,
      :prefix,
      :logical_partition,
      context_multitenant?: false
    ]

    @type t :: %__MODULE__{
            repo_module: Ecto.Repo.t(),
            dynamic_repo: atom() | pid(),
            prefix: binary() | nil,
            logical_partition: binary(),
            context_multitenant?: boolean()
          }
  end

  @spec for_repo(Ecto.Repo.t(), binary() | nil, keyword()) :: Target.t()
  def for_repo(repo, prefix \\ nil, options \\ [])

  def for_repo(repo, prefix, options) when is_atom(repo) and is_list(options) do
    # mutation sentinel: for-repo-prefix-bound
    # target/2 already fails closed on an over-long context-tenant prefix. This is the parallel
    # construction path — the shared entry every ops surface uses (reap/prune/cleanup tasks and
    # the Oban workers) — so it enforces the same NAMEDATALEN bound here. Without it, a caller
    # passing a >63-byte prefix would be silently truncated by PostgreSQL and routed to the wrong
    # tenant's physical schema (a cross-tenant isolation failure), so fail closed instead.
    unless is_nil(prefix) or valid_prefix?(prefix) do
      raise ArgumentError,
            "ash_onetime schema prefix must be nil or a 1..63-byte binary; " <>
              "PostgreSQL silently truncates identifiers at NAMEDATALEN (63 bytes)"
    end

    logical_partition = Keyword.get(options, :logical_partition, @default_logical_partition)

    unless valid_logical_partition?(logical_partition) do
      raise ArgumentError,
            "ash_onetime logical partition must be a valid 1..#{@max_logical_partition_bytes}-byte UTF-8 binary"
    end

    %Target{
      repo_module: repo,
      dynamic_repo: repo.get_dynamic_repo(),
      prefix: prefix,
      logical_partition: logical_partition
    }
  end

  @spec target(Ash.Resource.t(), keyword()) :: {:ok, Target.t()} | Result.t()
  def target(resource, options \\ []) when is_atom(resource) and is_list(options) do
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)
    dynamic_repo = data_layer_repo(options) || repo.get_dynamic_repo()
    context_multitenant? = Ash.Resource.Info.multitenancy_strategy(resource) == :context
    logical_partition = Keyword.get(options, :logical_partition, @default_logical_partition)

    prefix =
      if context_multitenant? do
        Keyword.get(options, :tenant)
      else
        AshPostgres.DataLayer.Info.schema(resource)
      end

    if (context_multitenant? and not valid_prefix?(prefix)) or
         not valid_logical_partition?(logical_partition) do
      Result.failure(:missing_prefix, :not_started, :not_applicable)
    else
      {:ok,
       %Target{
         repo_module: repo,
         dynamic_repo: dynamic_repo,
         prefix: prefix,
         logical_partition: logical_partition,
         context_multitenant?: context_multitenant?
       }}
    end
  rescue
    _exception -> Result.failure(:invalid_request, :not_started, :not_applicable)
  end

  @impl AshOnetime.Store
  def claim(%Target{} = target, %Request{} = request) do
    with_checkout(target, fn ->
      with :ok <- transaction_preconditions(target),
           :ok <- validate_request(request) do
        claim_attempt(target, request, 0)
      else
        {:error, %Result{} = result} -> result
        {:error, reason} -> Result.failure(reason, :not_started, :open)
      end
    end)
  end

  def claim(_target, _request),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @impl AshOnetime.Store
  def claim_committed(
        %Target{} = target,
        %Request{strategy: strategy} = request,
        options
      )
      when strategy in [:idempotency, :one_time_nonce] and is_list(options) do
    lock_timeout_ms = Keyword.get(options, :lock_timeout_ms)
    :ok = validate_claim_lock_timeout(lock_timeout_ms)
    parent = self()
    message_ref = make_ref()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        result = committed_claim_transaction(target, request, lock_timeout_ms)
        send(parent, {message_ref, result})
      end)

    receive_committed_claim(worker, monitor_ref, message_ref)
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    _kind, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def claim_committed(_target, _request, _options),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @impl AshOnetime.Store
  def lock_for_effect(%Target{} = target, %Claim{strategy: :idempotency} = claim, options)
      when is_list(options) do
    with_checkout(target, fn ->
      with :ok <- transaction_preconditions(target),
           :ok <- validate_claim_lock_timeout(Keyword.get(options, :lock_timeout_ms)) do
        lock_claim_under_timeout(target, claim, Keyword.get(options, :lock_timeout_ms))
      else
        {:error, %Result{} = result} -> result
      end
    end)
  end

  def lock_for_effect(_target, _claim, _options),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  # The lock_timeout GUC must bound ONLY the claim lock: SET LOCAL lasts to the end of the
  # caller's transaction, and everything after the lock runs on the same connection — the
  # adapter's own callbacks, the action body, and the finalize writes. Leaving it armed
  # would cap the adapter's contended writes (and finalize's payload insert) at the lock
  # wait — exactly the class of library-imposed bound ADR-0011 rejects. So: capture the
  # session's value, arm, lock, restore. On :lock_timeout the statement failure has
  # aborted the transaction — there is nothing to restore into.
  defp lock_claim_under_timeout(target, claim, nil), do: lock_claim_row(target, claim)

  defp lock_claim_under_timeout(target, claim, lock_timeout_ms) do
    with {:ok, previous} <- current_lock_timeout(target),
         :ok <- arm_claim_lock_timeout(target, lock_timeout_ms) do
      case lock_claim_row(target, claim) do
        %Result{reason: :lock_timeout} = result ->
          result

        %Result{} = result ->
          restore_lock_timeout(target, previous)
          result
      end
    else
      {:error, %Result{} = result} -> result
    end
  end

  defp current_lock_timeout(target) do
    case dispatched_query(target, "SHOW lock_timeout", []) do
      {:ok, %{rows: [[value]]}} when is_binary(value) -> {:ok, value}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp restore_lock_timeout(target, previous) do
    _ = dispatched_query(target, "SET LOCAL lock_timeout = '#{previous}'", [])
    :ok
  end

  # The id binds alongside the logical key so a row reaped and re-inserted between the
  # worker's commit and this lock is detected (:missing, fail closed) rather than silently
  # adopting a different generation's claim (ADR-0010).
  defp lock_claim_row(target, claim) do
    case select_claim(target, claim.strategy, logical_key(claim), claim.id) do
      {:ok, locked} -> resolve_locked_claim(target, locked)
      {:error, :missing} -> Result.failure(:store_invariant, :sent, :open)
      {:error, %Result{} = result} -> result
    end
  end

  defp resolve_locked_claim(target, locked) do
    case loaded_result(target, locked) do
      {:ok, %Result{} = result} -> result
      {:error, %Result{} = result} -> result
    end
  end

  @impl AshOnetime.Store
  def complete(target, claim, codec, digest, encoded_response),
    do: complete(target, claim, codec, digest, encoded_response, nil)

  @impl AshOnetime.Store
  def complete(
        %Target{} = target,
        %Claim{strategy: :idempotency} = claim,
        codec,
        digest,
        encoded_response,
        hold_reference
      ) do
    complete_mode(target, claim, codec, digest, encoded_response, :database, hold_reference)
  end

  def complete(_target, _claim, _codec, _digest, _encoded_response, _hold_reference),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @impl AshOnetime.Store
  def complete_external(target, claim, codec, digest, encoded_response),
    do: complete_external(target, claim, codec, digest, encoded_response, nil)

  @impl AshOnetime.Store
  def complete_external(
        %Target{} = target,
        %Claim{strategy: :idempotency} = claim,
        codec,
        digest,
        encoded_response,
        hold_reference
      ) do
    complete_mode(target, claim, codec, digest, encoded_response, :external, hold_reference)
  end

  def complete_external(_target, _claim, _codec, _digest, _encoded_response, _hold_reference),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  defp complete_mode(target, claim, codec, digest, payload, mode, hold_reference) do
    with_checkout(target, fn ->
      with :ok <- transaction_preconditions(target),
           :ok <- validate_hold(hold_reference) do
        complete_transaction(target, claim, codec, digest, payload, mode, hold_reference)
      else
        {:error, %Result{} = result} -> result
        {:error, _error} -> Result.failure(:invalid_request, :not_started, :open)
      end
    end)
  end

  @doc false
  @spec release(Target.t(), binary()) :: {:ok, non_neg_integer()} | Result.t()
  def release(%Target{} = target, reference) do
    with_checkout(target, fn ->
      with :ok <- AshOnetime.Hold.validate_reference(reference),
           :ok <- transaction_preconditions(target) do
        release_query(target, reference)
      else
        {:error, %Result{} = result} -> result
        {:error, _error} -> Result.failure(:invalid_request, :not_started, :open)
      end
    end)
  end

  def release(_target, _reference),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  defp release_query(target, reference) do
    sql = """
    UPDATE #{relation(target, "ash_onetime_idempotency_claims")}
    SET hold_reference = NULL,
        retain_until = GREATEST(retain_until, statement_timestamp() + (retain_until - admitted_at))
    WHERE logical_partition = $1 AND hold_reference = $2
    """

    case dispatched_query(target, sql, [target.logical_partition, reference]) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, %Result{} = result} -> result
    end
  end

  defp validate_hold(nil), do: :ok
  defp validate_hold(reference), do: AshOnetime.Hold.validate_reference(reference)

  @impl AshOnetime.Store
  def load(%Target{} = target, %Claim{} = claim) do
    with_checkout(target, fn ->
      with :ok <- transaction_preconditions(target),
           {:ok, loaded} <- select_claim(target, claim.strategy, logical_key(claim)),
           {:ok, result} <- loaded_result(target, loaded) do
        result
      else
        {:error, %Result{} = result} -> result
        {:error, :missing} -> Result.failure(:store_invariant, :sent, :open)
      end
    end)
  end

  def load(_target, _claim),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @max_partition_drops 128

  @spec cleanup(Target.t(), pos_integer(), non_neg_integer()) ::
          {:ok,
           %{
             idempotency: non_neg_integer(),
             nonce: non_neg_integer(),
             payload_partitions: non_neg_integer(),
             payload_partitions_kept: non_neg_integer(),
             payload_partitions_refused: %{optional(atom()) => non_neg_integer()}
           }}
          | Result.t()
  def cleanup(%Target{} = target, batch_size, partition_limit)
      when is_integer(batch_size) and batch_size > 0 and batch_size <= 10_000 and
             is_integer(partition_limit) and partition_limit >= 0 and
             partition_limit <= @max_partition_drops do
    lock_budget = Application.get_env(:ash_onetime, :partition_prune_lock_timeout_ms, 2_000)

    with_dynamic_repo(target, fn ->
      transaction = if target.repo_module.in_transaction?(), do: :open, else: :committed

      cleanup_transaction(target, batch_size, partition_limit, lock_budget)
      |> cleanup_result(transaction)
    end)
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    :exit, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def cleanup(_target, _batch_size, _partition_limit),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  defp cleanup_result({:ok, counts}, transaction) do
    if Map.keys(counts.payload_partitions_refused) -- [:lock_unavailable] == [] do
      {:ok, counts}
    else
      Result.failure(:prune_blocked, :sent, transaction)
    end
  end

  defp cleanup_result({:error, %Result{} = result}, _transaction), do: result

  defp cleanup_result(_other, _transaction),
    do: Result.failure(:dispatched_unknown, :unknown, :unknown)

  # Hard safety floor (seconds) for the abandoned-processing reaper, mirroring the migration's
  # @abandonment_floor_seconds (install.exs) and the worker/task floors. A sub-floor caller hits
  # :invalid_request here (without a DB round-trip) rather than the migration's 22023 raise
  # misclassified as :store_invariant by classify_query_error.
  @abandonment_floor_seconds 86_400

  @spec reap(Target.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | Result.t()
  def reap(%Target{} = target, batch_size, abandonment_seconds)
      when is_integer(batch_size) and batch_size > 0 and batch_size <= 10_000 and
             is_integer(abandonment_seconds) and abandonment_seconds >= @abandonment_floor_seconds do
    with_dynamic_repo(target, fn -> reap_transaction(target, batch_size, abandonment_seconds) end)
    |> case do
      {:ok, count} when is_integer(count) -> {:ok, count}
      {:error, %Result{} = result} -> result
      _other -> Result.failure(:dispatched_unknown, :unknown, :unknown)
    end
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    :exit, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def reap(_target, _batch_size, _abandonment_seconds),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @max_months_ahead 24
  @doc """
  Calls the installation's owner-owned roll function. It recovers historical months from
  `_default` before ensuring the requested forward window, creating at most 24 months per call.
  Recovery preserves payload columns and claim locators, copies policies and row-security flags,
  and resets each new child's table and column ACLs to owner-only access.

  A transaction-scoped advisory lock on the payload parent's OID serializes rolls. SQL enforces
  READ COMMITTED and the 1..24 month bound. Returns `{:ok, %{partitions_created: n}}` or an
  `AshOnetime.Store.Result` failure. The unreleased definer implementation remains blocked by
  the builtin SQL-dispatch trust regression described in the changelog.
  """
  @spec roll_partitions(Target.t(), pos_integer()) ::
          {:ok, %{partitions_created: non_neg_integer()}} | Result.t()
  def roll_partitions(%Target{} = target, months_ahead)
      when is_integer(months_ahead) and months_ahead >= 1 and months_ahead <= @max_months_ahead do
    with_dynamic_repo(target, fn -> roll_partitions_transaction(target, months_ahead) end)
    |> case do
      {:ok, count} when is_integer(count) -> {:ok, %{partitions_created: count}}
      {:error, %Result{} = result} -> result
      _other -> Result.failure(:dispatched_unknown, :unknown, :unknown)
    end
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    :exit, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def roll_partitions(_target, _months_ahead),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @doc false
  @spec held_backlog(Target.t()) :: {:ok, AshOnetime.Store.held_backlog()} | Result.t()
  def held_backlog(%Target{} = target) do
    with_dynamic_repo(target, fn ->
      sql = """
      SELECT pg_catalog.count(*),
             EXTRACT(EPOCH FROM (statement_timestamp() - pg_catalog.min(admitted_at)))::bigint
      FROM #{relation(target, "ash_onetime_idempotency_claims")}
      WHERE hold_reference IS NOT NULL
      """

      case dispatched_query(target, sql, []) do
        {:ok, %{rows: [[count, age]]}} when is_integer(count) and count >= 0 ->
          {:ok, %{held_count: count, oldest_age_seconds: oldest_age(count, age)}}

        {:ok, _result} ->
          Result.failure(:store_invariant, :sent, :not_applicable)

        {:error, %Result{} = result} ->
          result
      end
    end)
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    :exit, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def held_backlog(_target), do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @spec processing_backlog(Target.t()) ::
          {:ok,
           %{processing_count: non_neg_integer(), oldest_age_seconds: non_neg_integer() | nil}}
          | Result.t()
  def processing_backlog(%Target{} = target) do
    with_dynamic_repo(target, fn -> processing_backlog_query(target) end)
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    :exit, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def processing_backlog(_target),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @spec nonce_retention_deadline(Target.t(), binary(), binary(), binary()) ::
          {:ok, DateTime.t()} | :not_found | Result.t()
  def nonce_retention_deadline(%Target{} = target, operation_hash, scope_hash, key_hash)
      when is_binary(operation_hash) and byte_size(operation_hash) == 32 and
             is_binary(scope_hash) and byte_size(scope_hash) == 32 and
             is_binary(key_hash) and byte_size(key_hash) == 32 do
    parameters = [target.logical_partition, operation_hash, scope_hash, key_hash]
    with_dynamic_repo(target, fn -> nonce_retention_deadline_query(target, parameters) end)
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    :exit, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def nonce_retention_deadline(_target, _operation_hash, _scope_hash, _key_hash),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  defp nonce_retention_deadline_query(target, parameters) do
    sql = """
    SELECT retain_until FROM #{relation(target, "ash_onetime_nonce_claims")}
    WHERE #{@logical_key_predicate}
    """

    case nonce_deadline_query(target, sql, parameters) do
      {:ok, %{rows: [[%DateTime{} = deadline]]}} -> {:ok, deadline}
      {:ok, %{rows: []}} -> :not_found
      {:ok, _result} -> Result.failure(:store_invariant, :not_started, :not_applicable)
      {:error, %Result{} = result} -> result
    end
  end

  defp nonce_deadline_query(target, sql, parameters) do
    # A failed observation must not abort the host's earlier writes. Postgrex
    # savepoint mode requires an existing transaction; outside one use a normal read.
    mode = if target.repo_module.in_transaction?(), do: :savepoint, else: :transaction

    case SQL.query(target.dynamic_repo, sql, parameters, mode: mode) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        result = classify_query_error(error)
        {:error, %{result | admission_dispatch: :not_started, transaction: :not_applicable}}
    end
  end

  defp processing_backlog_query(target) do
    sql = """
    SELECT pg_catalog.count(*),
           EXTRACT(EPOCH FROM (transaction_timestamp() - pg_catalog.min(inserted_at)))::bigint
    FROM #{relation(target, "ash_onetime_idempotency_claims")}
    WHERE state = 'processing'
    """

    case dispatched_query(target, sql, []) do
      {:ok, %{rows: [[count, age]]}} when is_integer(count) and count >= 0 ->
        {:ok, %{processing_count: count, oldest_age_seconds: oldest_age(count, age)}}

      {:ok, _result} ->
        Result.failure(:store_invariant, :sent, :not_applicable)

      {:error, %Result{} = result} ->
        result
    end
  end

  defp oldest_age(0, _age), do: nil
  defp oldest_age(_count, age) when is_integer(age), do: max(age, 0)
  defp oldest_age(_count, _age), do: 0

  defp reap_transaction(target, batch_size, abandonment_seconds) do
    target.repo_module.transaction(fn -> reap_count(target, batch_size, abandonment_seconds) end)
  end

  defp reap_count(target, batch_size, abandonment_seconds) do
    case maintenance_query(
           target,
           "SELECT #{relation(target, "ash_onetime_reap_idempotency")}($1, $2)",
           [batch_size, abandonment_seconds]
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 ->
        count

      {:ok, _result} ->
        target.repo_module.rollback(Result.failure(:store_invariant, :sent, :rolled_back))

      {:error, %Result{} = result} ->
        target.repo_module.rollback(result)
    end
  end

  defp cleanup_transaction(target, batch_size, partition_limit, lock_budget)
       when is_integer(lock_budget) and lock_budget > 0 and lock_budget <= 5_000 do
    target.repo_module.transaction(fn ->
      cleanup_counts(target, batch_size, partition_limit, lock_budget)
    end)
  end

  defp cleanup_transaction(_target, _batch_size, _partition_limit, _lock_budget),
    do: {:error, Result.failure(:invalid_request, :not_started, :not_applicable)}

  defp cleanup_counts(target, batch_size, partition_limit, lock_budget) do
    with :ok <- transaction_preconditions(target),
         {:ok, idempotency} <- cleanup_strategy(target, :idempotency, batch_size),
         {:ok, nonce} <- cleanup_strategy(target, :nonce, batch_size),
         {:ok, payload_partitions, payload_partitions_kept, refused} <-
           prune_payload_partitions(target, partition_limit, lock_budget) do
      %{
        idempotency: idempotency,
        nonce: nonce,
        payload_partitions: payload_partitions,
        payload_partitions_kept: payload_partitions_kept,
        payload_partitions_refused: refused
      }
    else
      {:error, %Result{} = result} -> target.repo_module.rollback(result)
    end
  end

  defp claim_attempt(target, %Request{strategy: :one_time_nonce} = request, attempt) do
    with {:ok, aggregate} <- validate_nonce(request),
         result <- insert_claim(target, request, aggregate) do
      resolve_insert(target, request, result, attempt)
    else
      {:error, :invalid_nonce_window} ->
        expired_nonce_result(target, request)
    end
  end

  defp claim_attempt(target, %Request{strategy: :idempotency} = request, attempt) do
    resolve_insert(target, request, insert_claim(target, request, nil), attempt)
  end

  # No admission pre-read: valid proofs still use INSERT/ON CONFLICT. An invalid
  # window can only reject. Preserve legacy errors when retain_for was omitted.
  defp expired_nonce_result(target, %Request{retain_for: retain_for} = request)
       when is_integer(retain_for) do
    case select_nonce_for_replay(target, request) do
      {:ok, claim} ->
        if DateTime.compare(request.clock.now(), claim.retain_until) in [:lt, :eq] do
          collision_result(target, claim)
        else
          Result.failure(:invalid_nonce_window, :sent, :open)
        end

      {:error, :missing} ->
        Result.failure(:invalid_nonce_window, :sent, :open)

      {:error, %Result{} = result} ->
        result
    end
  end

  defp expired_nonce_result(_target, _request),
    do: Result.failure(:invalid_nonce_window, :not_started, :open)

  defp select_nonce_for_replay(target, request) do
    {table, columns} = claim_projection(:one_time_nonce)

    # This lookup only chooses a refusal; it can never admit or mutate a claim.
    # A plain SELECT observes the committed deadline without blocking on row locks.
    # Cleanup racing this observation is safe: both possible results refuse admission.
    sql = """
    SELECT #{columns}
    FROM #{relation(target, table)}
    WHERE #{@logical_key_predicate}
    """

    case dispatched_query(target, sql, Tuple.to_list(logical_key(target, request))) do
      {:ok, %{num_rows: 1, rows: [row]}} -> {:ok, decode_claim(:one_time_nonce, row)}
      {:ok, %{num_rows: 0}} -> {:error, :missing}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp complete_transaction(target, claim, codec, digest, encoded_response, mode, hold_reference) do
    with :ok <- validate_completion(codec, digest, encoded_response),
         {:ok, partition_date} <- database_date(target, mode),
         :ok <- insert_payload(target, partition_date, claim.id, encoded_response),
         {:ok, completed} <-
           update_complete(target, claim, partition_date, codec, digest, mode, hold_reference) do
      Result.success(:complete, claim: completed, payload: encoded_response)
    else
      {:error, %Result{} = result} ->
        rollback_completion(target, result)

      {:error, reason} ->
        rollback_completion(target, Result.failure(reason, :not_started, :rolled_back))
    end
  end

  defp resolve_insert(_target, _request, {:ok, %Claim{} = claim}, _attempt),
    do: Result.success(:admitted, claim: claim)

  defp resolve_insert(target, request, :conflict, attempt) do
    case select_claim(target, request.strategy, logical_key(target, request)) do
      {:ok, claim} ->
        collision_result(target, claim)

      {:error, :missing} when attempt == 0 ->
        claim_attempt(target, request, 1)

      {:error, :missing} ->
        Result.failure(:store_invariant, :sent, :open)

      {:error, %Result{} = result} ->
        result
    end
  end

  defp resolve_insert(_target, _request, {:error, %Result{} = result}, _attempt), do: result

  defp collision_result(_target, %Claim{strategy: :one_time_nonce} = claim),
    do: Result.success(:collision, claim: claim)

  defp collision_result(target, %Claim{} = claim) do
    case loaded_result(target, claim) do
      {:ok, %Result{} = result} -> result
      {:error, %Result{} = result} -> result
    end
  end

  defp loaded_result(_target, %Claim{strategy: :idempotency, state: :processing} = claim) do
    {:ok, Result.success(:processing, claim: claim)}
  end

  defp loaded_result(target, %Claim{strategy: :idempotency, state: :complete} = claim) do
    case load_payload(target, claim) do
      {:ok, payload} -> {:ok, Result.success(:complete, claim: claim, payload: payload)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp loaded_result(_target, %Claim{strategy: :one_time_nonce} = claim) do
    {:ok, Result.success(:collision, claim: claim)}
  end

  defp loaded_result(_target, _claim) do
    {:error, Result.failure(:store_invariant, :sent, :open)}
  end

  defp insert_claim(target, %Request{strategy: :idempotency} = request, _cleanup_after) do
    sql = """
    INSERT INTO #{relation(target, "ash_onetime_idempotency_claims")}
      (id, logical_partition, operation_hash, scope_hash, key_hash, fingerprint, state,
       admitted_at, retain_until, inserted_at)
    VALUES ($1::uuid, $2, $3, $4, $5, $6, 'processing',
            transaction_timestamp(),
            transaction_timestamp() + ($7::bigint * interval '1 second'),
            transaction_timestamp())
    ON CONFLICT DO NOTHING
    RETURNING id, logical_partition, operation_hash, scope_hash, key_hash, fingerprint, state,
              response_partition, response_codec, response_digest, hold_reference,
              admitted_at, retain_until, inserted_at
    """

    query_claim(
      target,
      sql,
      [
        dump_uuid(request.id),
        target.logical_partition,
        request.operation_hash,
        request.scope_hash,
        request.key_hash,
        request.fingerprint,
        request.retention_seconds
      ],
      :idempotency
    )
  end

  defp insert_claim(
         target,
         %Request{strategy: :one_time_nonce} = request,
         aggregate
       ) do
    sql = """
    INSERT INTO #{relation(target, "ash_onetime_nonce_claims")}
      (id, logical_partition, operation_hash, scope_hash, key_hash, issued_at, expires_at, verifier_id,
       admitted_at, retain_until, inserted_at)
    VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8,
            transaction_timestamp(),
            GREATEST(
              $9::timestamptz,
              transaction_timestamp() + (#{AshOnetime.Window.cleanup_skew_margin_seconds()} * interval '1 second')
            ),
            transaction_timestamp())
    ON CONFLICT DO NOTHING
    RETURNING id, logical_partition, operation_hash, scope_hash, key_hash, issued_at, expires_at, verifier_id,
              admitted_at, retain_until, inserted_at
    """

    query_claim(
      target,
      sql,
      [
        dump_uuid(request.id),
        target.logical_partition,
        request.operation_hash,
        request.scope_hash,
        request.key_hash,
        aggregate.issued_at,
        aggregate.expires_at,
        aggregate.verifier_id,
        aggregate.cleanup_after
      ],
      :one_time_nonce
    )
  end

  defp query_claim(target, sql, parameters, strategy) do
    case dispatched_query(target, sql, parameters) do
      {:ok, %{num_rows: 1, rows: [row]}} -> {:ok, decode_claim(strategy, row)}
      {:ok, %{num_rows: 0, rows: []}} -> :conflict
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp select_claim(target, strategy, logical_key_element, claim_id \\ nil)

  defp select_claim(
         target,
         strategy,
         {logical_partition, operation_hash, scope_hash, key_hash},
         nil
       ) do
    {table, columns} = claim_projection(strategy)

    sql = """
    SELECT #{columns}
    FROM #{relation(target, table)}
    WHERE #{@logical_key_predicate}
    FOR UPDATE
    """

    case dispatched_query(target, sql, [logical_partition, operation_hash, scope_hash, key_hash]) do
      {:ok, %{num_rows: 1, rows: [row]}} -> {:ok, decode_claim(strategy, row)}
      {:ok, %{num_rows: 0}} -> {:error, :missing}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  # The pre-peer claim lock (ADR-0010): the id binds alongside the logical key so the lock
  # refuses a row that was reaped and re-inserted between the committed claim and this
  # moment — a different generation's claim is :missing (fail closed), never adopted.
  defp select_claim(
         target,
         strategy,
         {logical_partition, operation_hash, scope_hash, key_hash},
         claim_id
       ) do
    {table, columns} = claim_projection(strategy)

    sql = """
    SELECT #{columns}
    FROM #{relation(target, table)}
    WHERE #{@logical_key_predicate} AND id = $5::uuid
    FOR UPDATE
    """

    case dispatched_query(
           target,
           sql,
           [logical_partition, operation_hash, scope_hash, key_hash, dump_uuid(claim_id)]
         ) do
      {:ok, %{num_rows: 1, rows: [row]}} -> {:ok, decode_claim(strategy, row)}
      {:ok, %{num_rows: 0}} -> {:error, :missing}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp claim_projection(:idempotency) do
    {"ash_onetime_idempotency_claims",
     "id, logical_partition, operation_hash, scope_hash, key_hash, fingerprint, state, " <>
       "response_partition, response_codec, response_digest, hold_reference, " <>
       "admitted_at, retain_until, inserted_at"}
  end

  defp claim_projection(:one_time_nonce) do
    {"ash_onetime_nonce_claims",
     "id, logical_partition, operation_hash, scope_hash, key_hash, issued_at, expires_at, verifier_id, " <>
       "admitted_at, retain_until, inserted_at"}
  end

  defp insert_payload(target, partition_date, id, encoded_response) do
    sql = """
    INSERT INTO #{relation(target, "ash_onetime_response_payloads")}
      (logical_partition, partition_date, claim_id, encoded_response)
    VALUES ($1, $2, $3::uuid, $4)
    ON CONFLICT DO NOTHING
    RETURNING claim_id
    """

    case dispatched_query(target, sql, [
           target.logical_partition,
           partition_date,
           dump_uuid(id),
           encoded_response
         ]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp update_complete(target, claim, partition_date, codec, digest, mode, hold_reference) do
    retention_update =
      case mode do
        :database -> ""
        :external -> ", retain_until = statement_timestamp() + (retain_until - admitted_at)"
      end

    sql = """
    UPDATE #{relation(target, "ash_onetime_idempotency_claims")}
    SET state = 'complete', response_partition = $1, response_codec = $2,
        response_digest = $3, hold_reference = $9#{retention_update}
    WHERE #{@completion_key_predicate}
      AND id = $8::uuid AND state = 'processing'
      AND (
        SELECT pg_catalog.count(*)
        FROM #{relation(target, "ash_onetime_response_payloads")}
        WHERE logical_partition = $4 AND claim_id = $8::uuid
      ) = 1
      AND EXISTS (
        SELECT 1
        FROM #{relation(target, "ash_onetime_response_payloads")}
        WHERE logical_partition = $4 AND claim_id = $8::uuid AND partition_date = $1
      )
    RETURNING id, logical_partition, operation_hash, scope_hash, key_hash, fingerprint, state,
              response_partition, response_codec, response_digest, hold_reference,
              admitted_at, retain_until, inserted_at
    """

    parameters =
      [partition_date, codec, digest] ++
        Tuple.to_list(logical_key(claim)) ++ [dump_uuid(claim.id), hold_reference]

    case dispatched_query(target, sql, parameters) do
      {:ok, %{num_rows: 1, rows: [row]}} -> {:ok, decode_claim(:idempotency, row)}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp load_payload(target, claim) do
    # The `partition_date` predicate prunes the range-partitioned payload table to the
    # single monthly child holding this claim's response (the PK is
    # `(partition_date, claim_id)`), turning the replay read into a point lookup instead
    # of a scan of every monthly partition. `claim.response_partition` is non-nil for a
    # `:complete` idempotency claim by the write-path invariant (`update_complete/5` sets
    # it atomically with `state = 'complete'`).
    #
    # The `partition_date == claim.response_partition` guard below is now logically dead on
    # the authoritative path (the WHERE binds `partition_date` to `claim.response_partition`,
    # so any returned row satisfies it by construction) and is retained as defense-in-depth.
    # Note: a stale/corrupted claim struct whose `response_partition` disagrees with the
    # stored row is NOT caught by this guard — it is caught by the no-row fallthrough below
    # (a mismatched `response_partition` makes the WHERE match nothing → `num_rows: 0` →
    # `:corrupt_payload`). Do not remove the guard expecting it to perform that detection.
    sql = """
    SELECT partition_date, encoded_response
    FROM #{relation(target, "ash_onetime_response_payloads")}
    WHERE logical_partition = $1 AND claim_id = $2::uuid AND partition_date = $3
    """

    case dispatched_query(target, sql, [
           claim.logical_partition,
           dump_uuid(claim.id),
           claim.response_partition
         ]) do
      {:ok, %{num_rows: 1, rows: [[partition_date, payload]]}}
      when partition_date == claim.response_partition and is_binary(payload) and
             byte_size(payload) <= @payload_ceiling ->
        if fixed_digest_equal?(:crypto.hash(:sha256, payload), claim.response_digest) do
          {:ok, payload}
        else
          {:error, Result.failure(:corrupt_payload, :sent, :open)}
        end

      {:ok, _result} ->
        {:error, Result.failure(:corrupt_payload, :sent, :open)}

      {:error, %Result{} = result} ->
        {:error, result}
    end
  end

  defp database_date(target, mode) do
    timestamp = if mode == :external, do: "statement_timestamp()", else: "transaction_timestamp()"

    case dispatched_query(target, "SELECT #{timestamp}::date", []) do
      {:ok, %{rows: [[%Date{} = date]]}} -> {:ok, date}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp committed_claim_transaction(target, request, lock_timeout_ms) do
    with_dynamic_repo(target, fn ->
      run_committed_claim_transaction(target, request, lock_timeout_ms)
    end)
  rescue
    exception ->
      # Surface the original exception class via telemetry before collapsing to
      # :dispatched_unknown. The lib's posture is telemetry-only (a fresh application sees
      # nothing unless it attaches a handler); a Logger call would break that for consumers
      # with a default backend. The event carries the exception CLASS only (not the struct)
      # to avoid leaking request material that may be embedded in an exception message.
      AshOnetime.Telemetry.uncertain_exception(request.strategy,
        phase: :committed_claim,
        exception: exception.__struct__
      )

      Result.failure(:dispatched_unknown, :unknown, :unknown)
  catch
    :exit, _reason -> Result.failure(:disconnected, :unknown, :unknown)
    _kind, _reason -> Result.failure(:dispatched_unknown, :unknown, :unknown)
  end

  defp run_committed_claim_transaction(target, request, lock_timeout_ms) do
    if target.repo_module.in_transaction?() do
      Result.failure(:store_invariant, :not_started, :not_applicable)
    else
      target.repo_module.transaction(fn -> claim_for_commit(target, request, lock_timeout_ms) end)
      |> committed_transaction_result()
    end
  end

  defp claim_for_commit(target, request, lock_timeout_ms) do
    # Judge correction 1 (ADR-0010): the same-key retry blocks in THIS worker's
    # select_claim FOR UPDATE when the original caller holds the pre-peer claim lock —
    # a second connection this process owns, so only a transaction-scoped lock_timeout
    # armed here bounds the wait. Armed only when the external path passes it.
    case arm_claim_lock_timeout(target, lock_timeout_ms) do
      :ok -> resolve_claim_for_commit(target, request)
      {:error, %Result{} = result} -> target.repo_module.rollback(result)
    end
  end

  defp resolve_claim_for_commit(target, request) do
    # `:collision` is nonce-only by construction (collision_result/2 returns it only for
    # :one_time_nonce; idempotency collisions resolve to :processing/:complete via loaded_result/2),
    # so admitting it here introduces no idempotency-path change. It lets a committed nonce
    # retry (a reused proof whose marker already committed independently) reach decide/5's
    # :collision arm instead of being rolled back to :store_invariant. See ADR-0003.
    case claim(target, request) do
      %Result{status: status, transaction: :open} = result
      when status in [:admitted, :processing, :complete, :collision] ->
        result

      %Result{} = result ->
        target.repo_module.rollback(result)
    end
  end

  # Bounds a claim-lock wait: a positive integer at or below @max_claim_lock_timeout, or
  # nil (no arming — the nonce fence path). The ceiling sits 5s below the committed-claim
  # worker kill so the LOCK timeout — not the worker kill — decides a contended wait
  # (ADR-0010). Returns a typed failure rather than raising: the raise would be swallowed
  # by the surrounding rescue/catch layers and surface as an ambiguous store failure.
  # Unreachable from the DSL, which bounds the same range at compile time.
  defp validate_claim_lock_timeout(nil), do: :ok

  defp validate_claim_lock_timeout(lock_timeout_ms)
       when is_integer(lock_timeout_ms) and lock_timeout_ms > 0 and
              lock_timeout_ms <= @max_claim_lock_timeout,
       do: :ok

  defp validate_claim_lock_timeout(_lock_timeout_ms),
    do: {:error, Result.failure(:invalid_request, :not_started, :not_applicable)}

  # Transaction-scoped lock_timeout for the pre-peer claim lock (ADR-0010): bounds how long
  # a same-key waiter blocks on the FOR UPDATE row lock before failing with :lock_timeout
  # (mapped to :request_in_progress by the caller). Mirrors arm_partition_roll_lock/2.
  defp arm_claim_lock_timeout(_target, nil), do: :ok

  defp arm_claim_lock_timeout(target, lock_timeout_ms) do
    case dispatched_query(target, "SET LOCAL lock_timeout = #{lock_timeout_ms}", []) do
      {:ok, _result} -> :ok
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp committed_transaction_result({:ok, %Result{} = result}), do: Result.committed(result)

  defp committed_transaction_result({:error, %Result{} = result}) do
    transaction = if result.transaction == :unknown, do: :unknown, else: :rolled_back
    %{result | transaction: transaction}
  end

  defp committed_transaction_result(_other),
    do: Result.failure(:dispatched_unknown, :unknown, :unknown)

  defp receive_committed_claim(worker, monitor_ref, message_ref) do
    receive do
      {^message_ref, %Result{} = result} ->
        receive do
          {:DOWN, ^monitor_ref, :process, ^worker, :normal} ->
            result

          {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
            Result.failure(:dispatched_unknown, :unknown, :unknown)
        after
          @committed_claim_timeout ->
            Process.demonitor(monitor_ref, [:flush])
            Result.failure(:worker_timeout, :unknown, :unknown)
        end

      {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
        Result.failure(:dispatched_unknown, :unknown, :unknown)
    after
      @committed_claim_timeout ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^worker, _reason} -> :ok
        after
          1_000 -> Process.demonitor(monitor_ref, [:flush])
        end

        Result.failure(:worker_timeout, :unknown, :unknown)
    end
  end

  defp cleanup_strategy(target, strategy, batch_size) do
    function =
      case strategy do
        :idempotency -> "ash_onetime_cleanup_idempotency"
        :nonce -> "ash_onetime_cleanup_nonce"
      end

    case maintenance_query(target, "SELECT #{relation(target, function)}($1)", [batch_size]) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 -> {:ok, count}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :rolled_back)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp prune_payload_partitions(_target, 0, _lock_budget), do: {:ok, 0, 0, %{}}

  defp prune_payload_partitions(target, limit, lock_budget) do
    case maintenance_query(
           target,
           "SELECT #{relation(target, "ash_onetime_prune_payload_partitions")}($1, $2)",
           [limit, lock_budget]
         ) do
      {:ok, %{rows: [[report]]}} ->
        decode_prune_report(report)

      {:error, %Result{} = result} ->
        {:error, result}

      _other ->
        {:error, Result.failure(:store_invariant, :sent, :rolled_back)}
    end
  end

  @prune_refusal_reasons %{
    "missing" => :missing,
    "not_plain_child" => :not_plain_child,
    "not_owner" => :not_owner,
    "force_reapplied" => :force_reapplied,
    "lock_unavailable" => :lock_unavailable,
    "ddl_blocked" => :ddl_blocked
  }

  defp decode_prune_report(%{"dropped" => dropped, "kept" => kept, "refusals" => refusals})
       when is_integer(dropped) and dropped >= 0 and is_integer(kept) and kept >= 0 and
              is_map(refusals) do
    if Enum.all?(refusals, fn {key, count} ->
         Map.has_key?(@prune_refusal_reasons, key) and is_integer(count) and count > 0
       end) do
      {:ok, dropped, kept,
       Map.new(refusals, fn {key, count} -> {Map.fetch!(@prune_refusal_reasons, key), count} end)}
    else
      {:error, Result.failure(:store_invariant, :sent, :rolled_back)}
    end
  end

  defp decode_prune_report(_report),
    do: {:error, Result.failure(:store_invariant, :sent, :rolled_back)}

  defp roll_partitions_transaction(target, months_ahead) do
    target.repo_module.transaction(fn ->
      case maintenance_query(
             target,
             "SELECT #{relation(target, "ash_onetime_roll_payload_partitions")}($1)",
             [months_ahead]
           ) do
        {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 ->
          count

        {:error, %Result{} = result} ->
          target.repo_module.rollback(result)

        _other ->
          target.repo_module.rollback(Result.failure(:store_invariant, :sent, :rolled_back))
      end
    end)
  end

  defp maintenance_query(target, sql, arguments) do
    Process.put(@phase_key, :sent)

    case SQL.query(target.dynamic_repo, sql, arguments) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        {:error, classify_maintenance_error(error)}
    end
  rescue
    _exception -> {:error, Result.failure(:dispatched_unknown, :unknown, :unknown)}
  catch
    :exit, _reason -> {:error, Result.failure(:disconnected, :unknown, :unknown)}
  end

  defp classify_maintenance_error(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}),
    do: Result.failure(:maintenance_not_permitted, :sent, :rolled_back)

  defp classify_maintenance_error(%Postgrex.Error{postgres: %{code: :active_sql_transaction}}),
    do: Result.failure(:unsupported_isolation, :sent, :rolled_back)

  defp classify_maintenance_error(%Postgrex.Error{
         postgres: %{code: :raise_exception, message: message}
       }) do
    reason =
      cond do
        String.starts_with?(message, "maintenance_blinded:") -> :maintenance_blinded
        String.starts_with?(message, "untrusted_dependency:") -> :untrusted_dependency
        String.starts_with?(message, "prune_blocked:") -> :prune_blocked
        true -> :store_invariant
      end

    Result.failure(reason, :sent, :rolled_back)
  end

  defp classify_maintenance_error(error), do: classify_query_error(error)

  defp validate_request(%Request{strategy: :idempotency, retention_seconds: retention_seconds})
       when is_integer(retention_seconds) and retention_seconds > 0 and
              retention_seconds <= @max_retention_seconds,
       do: :ok

  defp validate_request(%Request{
         strategy: :one_time_nonce,
         verified: verified,
         max_age: max_age,
         retain_for: retain_for,
         clock_skew: skew,
         clock: clock
       })
       when is_list(verified) and verified != [] and is_integer(max_age) and max_age >= 0 and
              is_integer(skew) and skew >= 0 and is_atom(clock) do
    if is_nil(retain_for) or AshOnetime.Window.valid_retention?(max_age, retain_for, skew),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp validate_request(_request), do: {:error, :invalid_request}

  defp validate_nonce(%Request{
         verified: verified_facts,
         max_age: max_age,
         retain_for: retain_for,
         clock_skew: skew,
         clock: clock
       }) do
    evaluated_at = clock.now()

    with :ok <- validate_verified_facts(verified_facts, evaluated_at, max_age, skew),
         {:ok, aggregate} <- aggregate_verified_facts(verified_facts, retain_for || max_age, skew) do
      {:ok, aggregate}
    else
      _other -> {:error, :invalid_nonce_window}
    end
  rescue
    _exception -> {:error, :invalid_nonce_window}
  catch
    :throw, {DBConnection, connection_reference, _reason} = rollback
    when is_reference(connection_reference) ->
      throw(rollback)

    _kind, _reason ->
      {:error, :invalid_nonce_window}
  end

  defp validate_verified_facts(verified_facts, evaluated_at, max_age, skew) do
    if Enum.all?(verified_facts, &valid_verified_fact?(&1, evaluated_at, max_age, skew)) do
      :ok
    else
      {:error, :invalid_nonce_window}
    end
  end

  defp valid_verified_fact?(
         %AshOnetime.Verified{issued_at: %DateTime{} = issued_at, expires_at: expires_at},
         evaluated_at,
         max_age,
         skew
       ),
       do: AshOnetime.Window.validate(issued_at, expires_at, evaluated_at, max_age, skew) == :ok

  defp valid_verified_fact?(_verified, _evaluated_at, _max_age, _skew), do: false

  defp aggregate_verified_facts([verified], retain_for, skew) do
    {:ok,
     %{
       issued_at: verified.issued_at,
       expires_at: verified.expires_at,
       verifier_id: verified.verifier_id,
       cleanup_after: AshOnetime.Window.cleanup_after(verified.issued_at, retain_for, skew)
     }}
  end

  defp aggregate_verified_facts(verified_facts, retain_for, skew) do
    latest = Enum.max_by(verified_facts, & &1.issued_at, DateTime)

    cleanup_after =
      verified_facts
      |> Enum.map(&AshOnetime.Window.cleanup_after(&1.issued_at, retain_for, skew))
      |> Enum.max(DateTime)

    verifier_ids = Enum.map(verified_facts, & &1.verifier_id)

    case AshOnetime.Fingerprint.compute(%{domain: :nonce_verifiers, ordered: verifier_ids}) do
      {:ok, digest} ->
        {:ok,
         %{
           issued_at: latest.issued_at,
           expires_at: nil,
           verifier_id: Base.url_encode64(digest, padding: false),
           cleanup_after: cleanup_after
         }}

      _other ->
        {:error, :invalid_nonce_window}
    end
  end

  defp validate_completion(codec, digest, encoded_response) do
    if is_binary(codec) and byte_size(codec) > 0 and byte_size(codec) <= @max_codec_bytes and
         is_binary(digest) and byte_size(digest) == 32 and is_binary(encoded_response) and
         byte_size(encoded_response) <= @payload_ceiling and
         fixed_digest_equal?(:crypto.hash(:sha256, encoded_response), digest) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  # Constant-time digest equality, size-guarded, mirroring Admission.fixed_digest_equal?/2
  # and Cache.fixed_equal?/2 — the store's digest comparisons follow the same convention as
  # every other comparison site in the library. Neither call site compares attacker-secret
  # material today (a digest of the payload returned to the key holder; a caller-supplied
  # digest validated against its own payload); the unification removes the plain-==
  # precedent so a future secret-adjacent comparison cannot copy it.
  defp fixed_digest_equal?(left, right)
       when is_binary(left) and byte_size(left) == 32 and is_binary(right) and
              byte_size(right) == 32,
       do: :crypto.hash_equals(left, right)

  defp fixed_digest_equal?(_left, _right), do: false

  defp transaction_preconditions(target) do
    if target.repo_module.in_transaction?() do
      case dispatched_query(target, "SHOW transaction_isolation", []) do
        {:ok, %{rows: [["read committed"]]}} -> :ok
        {:ok, _result} -> {:error, Result.failure(:unsupported_isolation, :sent, :open)}
        {:error, %Result{} = result} -> {:error, result}
      end
    else
      {:error, Result.failure(:not_in_transaction, :not_started, :open)}
    end
  end

  defp with_checkout(target, callback) do
    previous_phase = Process.get(@phase_key)
    Process.put(@phase_key, :not_started)

    try do
      with_dynamic_repo(target, fn ->
        try do
          target.repo_module.checkout(fn ->
            Process.put(@phase_key, :checked_out)
            callback.()
          end)
        rescue
          _exception -> classify_raised_failure()
        catch
          :throw, {DBConnection, _connection, _reason} = rollback -> throw(rollback)
          :exit, _reason -> classify_raised_failure()
          _kind, _reason -> classify_raised_failure()
        end
      end)
    after
      restore_process_value(@phase_key, previous_phase)
    end
  end

  defp with_dynamic_repo(target, callback) do
    previous_repo = target.repo_module.get_dynamic_repo()
    target.repo_module.put_dynamic_repo(target.dynamic_repo)

    try do
      callback.()
    after
      target.repo_module.put_dynamic_repo(previous_repo)
    end
  end

  defp dispatched_query(target, sql, parameters) do
    Process.put(@phase_key, :sent)

    case SQL.query(target.dynamic_repo, sql, parameters) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, classify_query_error(error)}
    end
  rescue
    _exception -> {:error, Result.failure(:dispatched_unknown, :unknown, :unknown)}
  catch
    :exit, _reason -> {:error, Result.failure(:disconnected, :unknown, :unknown)}
    _kind, _reason -> {:error, Result.failure(:dispatched_unknown, :unknown, :unknown)}
  end

  defp classify_query_error(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}) do
    # The owner-savepoint prune maps its own privilege failures (a non-owner
    # driver's lock, a DDL block) to kept partitions before classification;
    # what reaches here is an ordinary privilege failure on a store query.
    Result.failure(:store_invariant, :sent, :rolled_back)
  end

  defp classify_query_error(%Postgrex.Error{postgres: %{code: code}})
       when code in [:lock_not_available, :lock_timeout] do
    Result.failure(:lock_timeout, :sent, :rolled_back)
  end

  defp classify_query_error(%Postgrex.Error{postgres: %{code: :admin_shutdown}}) do
    Result.failure(:disconnected, :unknown, :unknown)
  end

  defp classify_query_error(%Postgrex.Error{}) do
    Result.failure(:store_invariant, :sent, :rolled_back)
  end

  defp classify_query_error(%DBConnection.ConnectionError{}) do
    Result.failure(:disconnected, :unknown, :unknown)
  end

  defp classify_query_error(_error) do
    Result.failure(:dispatched_unknown, :unknown, :unknown)
  end

  defp classify_raised_failure do
    case Process.get(@phase_key) do
      :not_started -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
      :sent -> Result.failure(:dispatched_unknown, :unknown, :unknown)
      _phase -> Result.failure(:disconnected, :unknown, :unknown)
    end
  end

  defp rollback_invariant(target, %Result{} = result) do
    target.repo_module.rollback(result)
  end

  defp rollback_completion(target, %Result{} = result) do
    transaction = if result.transaction == :unknown, do: :unknown, else: :rolled_back
    rollback_invariant(target, %{result | transaction: transaction})
  end

  defp decode_claim(:idempotency, [
         id,
         logical_partition,
         operation_hash,
         scope_hash,
         key_hash,
         fingerprint,
         state,
         response_partition,
         response_codec,
         response_digest,
         hold_reference,
         admitted_at,
         retain_until,
         inserted_at
       ]) do
    %Claim{
      strategy: :idempotency,
      id: decode_uuid(id),
      logical_partition: logical_partition,
      operation_hash: operation_hash,
      scope_hash: scope_hash,
      key_hash: key_hash,
      fingerprint: fingerprint,
      state: String.to_existing_atom(state),
      response_partition: response_partition,
      response_codec: response_codec,
      response_digest: response_digest,
      hold_reference: hold_reference,
      admitted_at: admitted_at,
      retain_until: retain_until,
      inserted_at: inserted_at
    }
  end

  defp decode_claim(:one_time_nonce, [
         id,
         logical_partition,
         operation_hash,
         scope_hash,
         key_hash,
         issued_at,
         expires_at,
         verifier_id,
         admitted_at,
         retain_until,
         inserted_at
       ]) do
    %Claim{
      strategy: :one_time_nonce,
      id: decode_uuid(id),
      logical_partition: logical_partition,
      operation_hash: operation_hash,
      scope_hash: scope_hash,
      key_hash: key_hash,
      issued_at: issued_at,
      expires_at: expires_at,
      verifier_id: verifier_id,
      admitted_at: admitted_at,
      retain_until: retain_until,
      inserted_at: inserted_at
    }
  end

  defp decode_uuid(<<_::128>> = binary), do: Ecto.UUID.load!(binary)
  defp decode_uuid(uuid) when is_binary(uuid), do: uuid

  defp dump_uuid(<<_::128>> = binary), do: binary
  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)

  defp logical_key(%{
         logical_partition: logical_partition,
         operation_hash: operation_hash,
         scope_hash: scope_hash,
         key_hash: key_hash
       }) do
    {logical_partition, operation_hash, scope_hash, key_hash}
  end

  defp logical_key(%Target{logical_partition: logical_partition}, %{
         operation_hash: operation_hash,
         scope_hash: scope_hash,
         key_hash: key_hash
       }) do
    {logical_partition, operation_hash, scope_hash, key_hash}
  end

  defp relation(%Target{prefix: nil}, name), do: quote_identifier(name)

  defp relation(%Target{prefix: prefix}, name) do
    quote_identifier(prefix) <> "." <> quote_identifier(name)
  end

  defp quote_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")

  defp data_layer_repo(options) do
    case Keyword.get(options, :data_layer_context, %{}) do
      %{repo: repo} when is_atom(repo) or is_pid(repo) -> repo
      %{data_layer: %{repo: repo}} when is_atom(repo) or is_pid(repo) -> repo
      _other -> nil
    end
  end

  # PostgreSQL silently truncates identifiers at 63 bytes (NAMEDATALEN), so two context
  # tenants sharing a 63-byte prefix would route to the same physical schema. Fail closed
  # on an over-long prefix, matching the cleanup-side bound (cleanup_worker.ex, prune task).
  defp valid_prefix?(value), do: is_binary(value) and byte_size(value) in 1..63

  defp valid_logical_partition?(value) do
    is_binary(value) and byte_size(value) in 1..@max_logical_partition_bytes and
      String.valid?(value) and not String.contains?(value, <<0>>)
  end

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)
end
