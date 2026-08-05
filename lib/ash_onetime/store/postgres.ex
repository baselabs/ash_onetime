defmodule AshOnetime.Store.Postgres do
  @moduledoc false

  @behaviour AshOnetime.Store

  alias AshOnetime.Store.{Claim, Result}
  alias AshOnetime.Store.Claim.Request
  alias Ecto.Adapters.SQL

  @payload_ceiling 16_777_216
  @max_retention_seconds 2_147_483_647
  @max_codec_bytes 128
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

  @spec cleanup(Target.t(), pos_integer()) ::
          {:ok, %{idempotency: non_neg_integer(), nonce: non_neg_integer()}} | Result.t()
  def cleanup(%Target{} = target, batch_size)
      when is_integer(batch_size) and batch_size > 0 and batch_size <= 10_000 do
    with_dynamic_repo(target, fn -> cleanup_transaction(target, batch_size) end)
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

  def cleanup(_target, _batch_size),
    do: Result.failure(:invalid_request, :not_started, :not_applicable)

  defp cleanup_transaction(target, batch_size) do
    target.repo_module.transaction(fn -> cleanup_counts(target, batch_size) end)
  end

  defp cleanup_counts(target, batch_size) do
    with {:ok, idempotency} <- cleanup_strategy(target, :idempotency, batch_size),
         {:ok, nonce} <- cleanup_strategy(target, :nonce, batch_size) do
      %{idempotency: idempotency, nonce: nonce}
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

  defp complete_transaction(target, claim, codec, digest, encoded_response) do
    with :ok <- validate_completion(codec, digest, encoded_response),
         {:ok, partition_date} <- database_date(target),
         :ok <- insert_payload(target, partition_date, claim.id, encoded_response),
         {:ok, completed} <- update_complete(target, claim, partition_date, codec, digest) do
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
            GREATEST($8::timestamptz, transaction_timestamp() + interval '1 microsecond'),
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

  defp update_complete(target, claim, partition_date, codec, digest) do
    sql = """
    UPDATE #{relation(target, "ash_onetime_idempotency_claims")}
    SET state = 'complete', response_partition = $1, response_codec = $2, response_digest = $3
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

  defp database_date(target) do
    case dispatched_query(target, "SELECT transaction_timestamp()::date", []) do
      {:ok, %{rows: [[%Date{} = date]]}} -> {:ok, date}
      {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}
      {:error, %Result{} = result} -> {:error, result}
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

  defp valid_prefix?(value), do: is_binary(value) and byte_size(value) > 0

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)
end
