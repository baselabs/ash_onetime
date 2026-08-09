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
  @phase_key {__MODULE__, :admission_phase}
  @logical_key_predicate "operation_hash = $1 AND scope_hash = $2 AND key_hash = $3"
  @completion_key_predicate "operation_hash = $4 AND scope_hash = $5 AND key_hash = $6"

  defmodule Target do
    @moduledoc false

    @enforce_keys [:repo_module, :dynamic_repo]
    defstruct [:repo_module, :dynamic_repo, :prefix, context_multitenant?: false]

    @type t :: %__MODULE__{
            repo_module: Ecto.Repo.t(),
            dynamic_repo: atom() | pid(),
            prefix: binary() | nil,
            context_multitenant?: boolean()
          }
  end

  @spec for_repo(Ecto.Repo.t(), binary() | nil) :: Target.t()
  def for_repo(repo, prefix \\ nil) when is_atom(repo) do
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

    %Target{repo_module: repo, dynamic_repo: repo.get_dynamic_repo(), prefix: prefix}
  end

  @spec target(Ash.Resource.t(), keyword()) :: {:ok, Target.t()} | Result.t()
  def target(resource, options \\ []) when is_atom(resource) and is_list(options) do
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)
    dynamic_repo = data_layer_repo(options) || repo.get_dynamic_repo()
    context_multitenant? = Ash.Resource.Info.multitenancy_strategy(resource) == :context

    prefix =
      if context_multitenant? do
        Keyword.get(options, :tenant)
      else
        AshPostgres.DataLayer.Info.schema(resource)
      end

    if context_multitenant? and not valid_prefix?(prefix) do
      Result.failure(:missing_prefix, :not_started, :not_applicable)
    else
      {:ok,
       %Target{
         repo_module: repo,
         dynamic_repo: dynamic_repo,
         prefix: prefix,
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
  def claim_committed(%Target{} = target, %Request{strategy: :idempotency} = request) do
    parent = self()
    message_ref = make_ref()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        result = committed_claim_transaction(target, request)
        send(parent, {message_ref, result})
      end)

    receive_committed_claim(worker, monitor_ref, message_ref)
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    _kind, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def claim_committed(_target, _request),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @impl AshOnetime.Store
  def complete(
        %Target{} = target,
        %Claim{strategy: :idempotency} = claim,
        codec,
        digest,
        encoded_response
      ) do
    with_checkout(target, fn ->
      case transaction_preconditions(target) do
        :ok -> complete_transaction(target, claim, codec, digest, encoded_response)
        {:error, %Result{} = result} -> result
      end
    end)
  end

  def complete(_target, _claim, _codec, _digest, _encoded_response),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @impl AshOnetime.Store
  def complete_external(
        %Target{} = target,
        %Claim{strategy: :idempotency} = claim,
        codec,
        digest,
        encoded_response
      ) do
    with_checkout(target, fn ->
      case transaction_preconditions(target) do
        :ok ->
          complete_transaction(target, claim, codec, digest, encoded_response, :external)

        {:error, %Result{} = result} ->
          result
      end
    end)
  end

  def complete_external(_target, _claim, _codec, _digest, _encoded_response),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

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
             payload_partitions: non_neg_integer()
           }}
          | Result.t()
  def cleanup(%Target{} = target, batch_size, partition_limit)
      when is_integer(batch_size) and batch_size > 0 and batch_size <= 10_000 and
             is_integer(partition_limit) and partition_limit >= 0 and
             partition_limit <= @max_partition_drops do
    with_dynamic_repo(target, fn -> cleanup_transaction(target, batch_size, partition_limit) end)
    |> case do
      {:ok, counts} -> {:ok, counts}
      {:error, %Result{} = result} -> result
      _other -> Result.failure(:dispatched_unknown, :unknown, :unknown)
    end
  rescue
    _exception -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  catch
    :exit, _reason -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)
  end

  def cleanup(_target, _batch_size, _partition_limit),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  @spec reap(Target.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | Result.t()
  def reap(%Target{} = target, batch_size, abandonment_seconds)
      when is_integer(batch_size) and batch_size > 0 and batch_size <= 10_000 and
             is_integer(abandonment_seconds) and abandonment_seconds > 0 do
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
  @default_lock_timeout_seconds 5
  # Fixed advisory-lock key for response-payload partition creation. pg_advisory_xact_lock
  # serializes concurrent rolls within one transaction so two cannot race on CREATE PARTITION
  # OF (Postgres has no CREATE PARTITION OF IF NOT EXISTS). The key is arbitrary but constant.
  # "ASHOT"
  @partition_roll_advisory_key 0x41_5348_4F54

  @doc """
  Creates the next `months_ahead` monthly `ash_onetime_response_payloads` range partitions,
  from the current month forward, so retention stays bounded past the install window. Without
  this, payloads whose `response_partition` falls outside the generated window route to the
  `_default` partition and are never dropped (they are excluded from `prune_payload_partitions`),
  silently defeating bounded retention (ADR-0001:65).

  Idempotent and concurrency-safe: an transaction-scoped advisory lock serializes concurrent
  rolls, and each partition is created only if absent (existence read from `pg_inherits` after
  acquiring the lock, so no read/write race). A bounded `lock_timeout` (default 5s) makes a roll
  blocked by a long cleanup fail closed rather than hang. Returns `{:ok,
  %{partitions_created: n}}` or an `AshOnetime.Store.Result` failure.
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

  defp processing_backlog_query(target) do
    sql = """
    SELECT count(*),
           EXTRACT(EPOCH FROM (transaction_timestamp() - min(inserted_at)))::bigint
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
    case dispatched_query(
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

  defp cleanup_transaction(target, batch_size, partition_limit) do
    target.repo_module.transaction(fn -> cleanup_counts(target, batch_size, partition_limit) end)
  end

  defp cleanup_counts(target, batch_size, partition_limit) do
    with {:ok, idempotency} <- cleanup_strategy(target, :idempotency, batch_size),
         {:ok, nonce} <- cleanup_strategy(target, :nonce, batch_size),
         {:ok, payload_partitions} <- prune_payload_partitions(target, partition_limit) do
      %{idempotency: idempotency, nonce: nonce, payload_partitions: payload_partitions}
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
        Result.failure(:invalid_nonce_window, :not_started, :open)
    end
  end

  defp claim_attempt(target, %Request{strategy: :idempotency} = request, attempt) do
    resolve_insert(target, request, insert_claim(target, request, nil), attempt)
  end

  defp complete_transaction(target, claim, codec, digest, encoded_response),
    do: complete_transaction(target, claim, codec, digest, encoded_response, :database)

  defp complete_transaction(target, claim, codec, digest, encoded_response, mode) do
    with :ok <- validate_completion(codec, digest, encoded_response),
         {:ok, partition_date} <- database_date(target, mode),
         :ok <- insert_payload(target, partition_date, claim.id, encoded_response),
         {:ok, completed} <- update_complete(target, claim, partition_date, codec, digest, mode) do
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
    case select_claim(target, request.strategy, logical_key(request)) do
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
      (id, operation_hash, scope_hash, key_hash, fingerprint, state,
       admitted_at, retain_until, inserted_at)
    VALUES ($1::uuid, $2, $3, $4, $5, 'processing',
            transaction_timestamp(),
            transaction_timestamp() + ($6::bigint * interval '1 second'),
            transaction_timestamp())
    ON CONFLICT DO NOTHING
    RETURNING id, operation_hash, scope_hash, key_hash, fingerprint, state,
              response_partition, response_codec, response_digest,
              admitted_at, retain_until, inserted_at
    """

    query_claim(
      target,
      sql,
      [
        dump_uuid(request.id),
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
      (id, operation_hash, scope_hash, key_hash, issued_at, expires_at, verifier_id,
       admitted_at, retain_until, inserted_at)
    VALUES ($1::uuid, $2, $3, $4, $5, $6, $7,
            transaction_timestamp(),
            GREATEST(
              $8::timestamptz,
              transaction_timestamp() + (#{AshOnetime.Window.cleanup_skew_margin_seconds()} * interval '1 second')
            ),
            transaction_timestamp())
    ON CONFLICT DO NOTHING
    RETURNING id, operation_hash, scope_hash, key_hash, issued_at, expires_at, verifier_id,
              admitted_at, retain_until, inserted_at
    """

    query_claim(
      target,
      sql,
      [
        dump_uuid(request.id),
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

  defp select_claim(target, strategy, {operation_hash, scope_hash, key_hash}) do
    {table, columns} =
      case strategy do
        :idempotency ->
          {"ash_onetime_idempotency_claims",
           "id, operation_hash, scope_hash, key_hash, fingerprint, state, " <>
             "response_partition, response_codec, response_digest, " <>
             "admitted_at, retain_until, inserted_at"}

        :one_time_nonce ->
          {"ash_onetime_nonce_claims",
           "id, operation_hash, scope_hash, key_hash, issued_at, expires_at, verifier_id, " <>
             "admitted_at, retain_until, inserted_at"}
      end

    sql = """
    SELECT #{columns}
    FROM #{relation(target, table)}
    WHERE #{@logical_key_predicate}
    FOR UPDATE
    """

    case dispatched_query(target, sql, [operation_hash, scope_hash, key_hash]) do
      {:ok, %{num_rows: 1, rows: [row]}} -> {:ok, decode_claim(strategy, row)}
      {:ok, %{num_rows: 0}} -> {:error, :missing}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp insert_payload(target, partition_date, id, encoded_response) do
    sql = """
    INSERT INTO #{relation(target, "ash_onetime_response_payloads")}
      (partition_date, claim_id, encoded_response)
    VALUES ($1, $2::uuid, $3)
    ON CONFLICT DO NOTHING
    RETURNING claim_id
    """

    case dispatched_query(target, sql, [partition_date, dump_uuid(id), encoded_response]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp update_complete(target, claim, partition_date, codec, digest, mode) do
    retention_update =
      case mode do
        :database -> ""
        :external -> ", retain_until = statement_timestamp() + (retain_until - admitted_at)"
      end

    sql = """
    UPDATE #{relation(target, "ash_onetime_idempotency_claims")}
    SET state = 'complete', response_partition = $1, response_codec = $2,
        response_digest = $3#{retention_update}
    WHERE #{@completion_key_predicate}
      AND id = $7::uuid AND state = 'processing'
      AND (
        SELECT count(*)
        FROM #{relation(target, "ash_onetime_response_payloads")}
        WHERE claim_id = $7::uuid
      ) = 1
      AND EXISTS (
        SELECT 1
        FROM #{relation(target, "ash_onetime_response_payloads")}
        WHERE claim_id = $7::uuid AND partition_date = $1
      )
    RETURNING id, operation_hash, scope_hash, key_hash, fingerprint, state,
              response_partition, response_codec, response_digest,
              admitted_at, retain_until, inserted_at
    """

    parameters =
      [partition_date, codec, digest] ++
        Tuple.to_list(logical_key(claim)) ++ [dump_uuid(claim.id)]

    case dispatched_query(target, sql, parameters) do
      {:ok, %{num_rows: 1, rows: [row]}} -> {:ok, decode_claim(:idempotency, row)}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp load_payload(target, claim) do
    sql = """
    SELECT partition_date, encoded_response
    FROM #{relation(target, "ash_onetime_response_payloads")}
    WHERE claim_id = $1::uuid
    """

    case dispatched_query(target, sql, [dump_uuid(claim.id)]) do
      {:ok, %{num_rows: 1, rows: [[partition_date, payload]]}}
      when partition_date == claim.response_partition and is_binary(payload) and
             byte_size(payload) <= @payload_ceiling ->
        if :crypto.hash(:sha256, payload) == claim.response_digest do
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

  defp committed_claim_transaction(target, request) do
    with_dynamic_repo(target, fn -> run_committed_claim_transaction(target, request) end)
  rescue
    _exception -> Result.failure(:dispatched_unknown, :unknown, :unknown)
  catch
    :exit, _reason -> Result.failure(:disconnected, :unknown, :unknown)
    _kind, _reason -> Result.failure(:dispatched_unknown, :unknown, :unknown)
  end

  defp run_committed_claim_transaction(target, request) do
    if target.repo_module.in_transaction?() do
      Result.failure(:store_invariant, :not_started, :not_applicable)
    else
      target.repo_module.transaction(fn -> claim_for_commit(target, request) end)
      |> committed_transaction_result()
    end
  end

  defp claim_for_commit(target, request) do
    case claim(target, request) do
      %Result{status: status, transaction: :open} = result
      when status in [:admitted, :processing, :complete] ->
        result

      %Result{} = result ->
        target.repo_module.rollback(result)
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
            Result.failure(:dispatched_unknown, :unknown, :unknown)
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

        Result.failure(:dispatched_unknown, :unknown, :unknown)
    end
  end

  defp cleanup_strategy(target, strategy, batch_size) do
    function =
      case strategy do
        :idempotency -> "ash_onetime_cleanup_idempotency"
        :nonce -> "ash_onetime_cleanup_nonce"
      end

    case dispatched_query(target, "SELECT #{relation(target, function)}($1)", [batch_size]) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 -> {:ok, count}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :rolled_back)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp prune_payload_partitions(_target, 0), do: {:ok, 0}

  defp prune_payload_partitions(target, limit) do
    with {:ok, schema, database_date} <- database_schema_and_date(target),
         {:ok, partitions} <- payload_partitions(target, schema) do
      partitions
      |> Enum.filter(&(Date.compare(database_date, &1.until_date) == :gt))
      |> Enum.sort_by(&{&1.until_date, &1.name})
      |> Enum.take(limit)
      |> drop_empty_partitions(target)
    end
  end

  defp database_schema_and_date(target) do
    case dispatched_query(
           target,
           "SELECT current_schema(), transaction_timestamp()::date",
           []
         ) do
      {:ok, %{rows: [[schema, %Date{} = date]]}} when is_binary(schema) ->
        {:ok, target.prefix || schema, date}

      {:ok, _result} ->
        {:error, Result.failure(:store_invariant, :sent, :rolled_back)}

      {:error, %Result{} = result} ->
        {:error, result}
    end
  end

  defp payload_partitions(target, schema) do
    sql = """
    SELECT child.relname, pg_get_expr(child.relpartbound, child.oid)
    FROM pg_inherits
    JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
    JOIN pg_namespace parent_namespace ON parent_namespace.oid = parent.relnamespace
    JOIN pg_class child ON child.oid = pg_inherits.inhrelid
    WHERE parent_namespace.nspname = $1
      AND parent.relname = 'ash_onetime_response_payloads'
    """

    case dispatched_query(target, sql, [schema]) do
      {:ok, %{rows: rows}} when is_list(rows) -> decode_payload_partitions(rows)
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :rolled_back)}
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp decode_payload_partitions(rows) do
    Enum.reduce_while(rows, {:ok, []}, &decode_payload_partition/2)
  end

  defp decode_payload_partition([_name, "DEFAULT"], accumulator),
    do: {:cont, accumulator}

  defp decode_payload_partition([name, bound], {:ok, partitions})
       when is_binary(name) and is_binary(bound) do
    case Regex.run(
           ~r/^FOR VALUES FROM \('([^']+)'\) TO \('([^']+)'\)$/,
           bound,
           capture: :all_but_first
         ) do
      [from, until_date] -> build_payload_partition(name, from, until_date, partitions)
      _invalid -> partition_decode_failure()
    end
  end

  defp decode_payload_partition(_row, _accumulator), do: partition_decode_failure()

  defp build_payload_partition(name, from, until_date, partitions) do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(until_date) do
      {:cont, {:ok, [%{name: name, from_date: from_date, until_date: to_date} | partitions]}}
    else
      _invalid -> partition_decode_failure()
    end
  end

  defp partition_decode_failure,
    do: {:halt, {:error, Result.failure(:store_invariant, :sent, :rolled_back)}}

  defp drop_empty_partitions(partitions, target) do
    Enum.reduce_while(partitions, {:ok, 0}, &drop_empty_partition(&1, &2, target))
  end

  defp drop_empty_partition(partition, {:ok, count}, target) do
    with {:ok, _lock} <-
           dispatched_query(
             target,
             "LOCK TABLE #{relation(target, partition.name)} IN SHARE MODE",
             []
           ),
         {:ok, empty?} <- partition_empty?(target, partition) do
      if empty?,
        do: drop_payload_partition(target, partition.name, count),
        else: {:cont, {:ok, count}}
    else
      {:error, %Result{} = result} -> {:halt, {:error, result}}
    end
  end

  defp partition_empty?(target, partition) do
    payload_sql = "SELECT count(*) FROM #{relation(target, partition.name)}"

    claims_sql = """
    SELECT count(*)
    FROM #{relation(target, "ash_onetime_idempotency_claims")}
    WHERE response_partition >= $1 AND response_partition < $2
    """

    with {:ok, %{rows: [[payload_count]]}} <- dispatched_query(target, payload_sql, []),
         {:ok, %{rows: [[claim_count]]}} <-
           dispatched_query(target, claims_sql, [partition.from_date, partition.until_date]),
         true <- is_integer(payload_count) and payload_count >= 0,
         true <- is_integer(claim_count) and claim_count >= 0 do
      {:ok, payload_count == 0 and claim_count == 0}
    else
      {:error, %Result{} = result} -> {:error, result}
      _other -> {:error, Result.failure(:store_invariant, :sent, :rolled_back)}
    end
  end

  defp drop_payload_partition(target, name, count) do
    case dispatched_query(target, "DROP TABLE #{relation(target, name)}", []) do
      {:ok, _result} -> {:cont, {:ok, count + 1}}
      {:error, %Result{} = result} -> {:halt, {:error, result}}
    end
  end

  defp roll_partitions_transaction(target, months_ahead) do
    target.repo_module.transaction(fn -> roll_partitions_counts(target, months_ahead) end)
  end

  defp roll_partitions_counts(target, months_ahead) do
    lock_timeout = partition_roll_lock_timeout()

    with :ok <- arm_partition_roll_lock(target, lock_timeout),
         {:ok, schema, database_date} <- database_schema_and_date(target),
         {:ok, existing} <- payload_partition_names(target, schema),
         {:ok, count} <-
           create_roll_partitions(target, schema, database_date, months_ahead, existing) do
      count
    else
      {:error, %Result{} = result} -> target.repo_module.rollback(result)
    end
  end

  defp partition_roll_lock_timeout do
    @default_lock_timeout_seconds * 1000
  end

  # Acquire a transaction-scoped advisory lock so concurrent rolls serialize (no CREATE PARTITION
  # OF race), and set a bounded lock_timeout so a roll blocked by a long cleanup fails closed
  # instead of hanging the worker. Both are scoped to this transaction and released on commit/
  # rollback. lock_timeout is an integer in milliseconds (Postgres accepts the bare integer).
  defp arm_partition_roll_lock(target, lock_timeout_ms) do
    with {:ok, _} <-
           dispatched_query(target, "SET LOCAL lock_timeout = #{lock_timeout_ms}", []),
         {:ok, _} <-
           dispatched_query(
             target,
             "SELECT pg_advisory_xact_lock($1::bigint)",
             [@partition_roll_advisory_key]
           ) do
      :ok
    end
  end

  defp payload_partition_names(target, schema) do
    case payload_partitions(target, schema) do
      {:ok, partitions} -> {:ok, MapSet.new(partitions, & &1.name)}
      {:error, %Result{}} = error -> error
    end
  end

  defp create_roll_partitions(target, schema, database_date, months_ahead, existing) do
    database_date
    |> roll_partition_descriptors(months_ahead)
    |> Enum.reject(&MapSet.member?(existing, &1.name))
    |> Enum.reduce_while({:ok, 0}, fn descriptor, {:ok, count} ->
      case create_one_partition(target, schema, descriptor) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, %Result{} = result} -> {:halt, {:error, result}}
      end
    end)
  end

  defp roll_partition_descriptors(first_month, months_ahead) do
    beginning = Date.beginning_of_month(first_month)

    for offset <- 0..(months_ahead - 1) do
      from = shift_month(beginning, offset)
      to = shift_month(beginning, offset + 1)

      %{
        name: "ash_onetime_response_payloads_#{from.year}_#{pad_month(from.month)}",
        from: from,
        to: to
      }
    end
  end

  defp create_one_partition(target, schema, %{name: name, from: from, to: to}) do
    sql = """
    CREATE TABLE #{relation(target, name)} PARTITION OF #{relation(target, "ash_onetime_response_payloads")}
    FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(to)}')
    """

    case dispatched_query(target, sql, []) do
      {:ok, _result} ->
        :ok

      # A duplicate_relation (42P07) is converted by dispatched_query to a store_invariant
      # Result. Under the advisory lock this should not happen (rolls serialize), but treat it
      # as idempotent success if it does — never fail a roll on a partition that already exists.
      # partition_exists? is SCHEMA-SCOPED (joins pg_namespace + filters nspname) so a
      # same-named partition in another tenant's schema never satisfies this check — the
      # multitenant isolation invariant its sibling payload_partitions enforces.
      {:error, %Result{reason: :store_invariant} = result} ->
        if partition_exists?(target, schema, name), do: :ok, else: {:error, result}

      {:error, %Result{} = result} ->
        {:error, result}
    end
  end

  defp partition_exists?(target, schema, name) do
    sql = """
    SELECT 1
    FROM pg_inherits
    JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
    JOIN pg_namespace parent_namespace ON parent_namespace.oid = parent.relnamespace
    JOIN pg_class child ON child.oid = pg_inherits.inhrelid
    WHERE parent_namespace.nspname = $1
      AND parent.relname = 'ash_onetime_response_payloads'
      AND child.relname = $2
    LIMIT 1
    """

    case dispatched_query(target, sql, [schema, name]) do
      {:ok, %{rows: [[1]]}} -> true
      _other -> false
    end
  end

  defp shift_month(date, offset) do
    month_index = date.year * 12 + date.month - 1 + offset
    Date.new!(div(month_index, 12), rem(month_index, 12) + 1, 1)
  end

  defp pad_month(month), do: String.pad_leading(Integer.to_string(month), 2, "0")

  defp validate_request(%Request{strategy: :idempotency, retention_seconds: retention_seconds})
       when is_integer(retention_seconds) and retention_seconds > 0 and
              retention_seconds <= @max_retention_seconds,
       do: :ok

  defp validate_request(%Request{
         strategy: :one_time_nonce,
         verified: verified,
         max_age: max_age,
         clock_skew: skew,
         clock: clock
       })
       when is_list(verified) and verified != [] and is_integer(max_age) and max_age >= 0 and
              is_integer(skew) and skew >= 0 and is_atom(clock),
       do: :ok

  defp validate_request(_request), do: {:error, :invalid_request}

  defp validate_nonce(%Request{
         verified: verified_facts,
         max_age: max_age,
         clock_skew: skew,
         clock: clock
       }) do
    evaluated_at = clock.now()

    with :ok <- validate_verified_facts(verified_facts, evaluated_at, max_age, skew),
         {:ok, aggregate} <- aggregate_verified_facts(verified_facts, max_age, skew) do
      {:ok, aggregate}
    else
      _other -> {:error, :invalid_nonce_window}
    end
  rescue
    _exception -> {:error, :invalid_nonce_window}
  catch
    _kind, _reason -> {:error, :invalid_nonce_window}
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

  defp aggregate_verified_facts([verified], max_age, skew) do
    {:ok,
     %{
       issued_at: verified.issued_at,
       expires_at: verified.expires_at,
       verifier_id: verified.verifier_id,
       cleanup_after: AshOnetime.Window.cleanup_after(verified.issued_at, max_age, skew)
     }}
  end

  defp aggregate_verified_facts(verified_facts, max_age, skew) do
    latest = Enum.max_by(verified_facts, & &1.issued_at, DateTime)

    cleanup_after =
      verified_facts
      |> Enum.map(&AshOnetime.Window.cleanup_after(&1.issued_at, max_age, skew))
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
         :crypto.hash(:sha256, encoded_response) == digest do
      :ok
    else
      {:error, :invalid_request}
    end
  end

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
         operation_hash,
         scope_hash,
         key_hash,
         fingerprint,
         state,
         response_partition,
         response_codec,
         response_digest,
         admitted_at,
         retain_until,
         inserted_at
       ]) do
    %Claim{
      strategy: :idempotency,
      id: decode_uuid(id),
      operation_hash: operation_hash,
      scope_hash: scope_hash,
      key_hash: key_hash,
      fingerprint: fingerprint,
      state: String.to_existing_atom(state),
      response_partition: response_partition,
      response_codec: response_codec,
      response_digest: response_digest,
      admitted_at: admitted_at,
      retain_until: retain_until,
      inserted_at: inserted_at
    }
  end

  defp decode_claim(:one_time_nonce, [
         id,
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

  defp logical_key(%{operation_hash: operation_hash, scope_hash: scope_hash, key_hash: key_hash}) do
    {operation_hash, scope_hash, key_hash}
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

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)
end
