defmodule AshOnetime.Transaction do
  @moduledoc """
  Transaction-owned idempotency and one-time nonce admission.

  This boundary is for hosts that already own one authoritative Ecto transaction and need
  `ash_onetime` admission to commit or roll back with the host's effect. It never starts or
  commits a transaction. The repository must already be inside a PostgreSQL `READ COMMITTED`
  transaction.

  `:operation` is a local-code `{module, action}` pair. `:partition`, `:scope`, and `:key` are
  exact bounded UTF-8 binaries. A logical partition isolates otherwise identical locators in one
  store installation without importing a host application's tenant or actor types.
  """

  alias AshOnetime.{Error, Fingerprint, Verified}
  alias AshOnetime.Store.{Claim, Postgres, Result}

  @max_identity_bytes 4_096
  @max_codec_bytes 128
  @idempotency_options ~w(operation partition prefix scope key fingerprint retention_seconds codec)a
  @nonce_options ~w(operation partition prefix scope key verified max_age clock_skew clock)a

  defmodule Admission do
    @moduledoc false

    @enforce_keys [:claim_id, :owner, :target, :request, :claim, :codec]
    defstruct [:claim_id, :owner, :target, :request, :claim, :codec]

    @opaque t :: %__MODULE__{
              claim_id: Ecto.UUID.t(),
              owner: pid(),
              target: AshOnetime.Store.Postgres.Target.t(),
              request: AshOnetime.Store.Claim.Request.t(),
              claim: AshOnetime.Store.Claim.t(),
              codec: binary()
            }
  end

  @typedoc "Opaque fresh idempotency admission returned by `idempotency/2`."
  @opaque admission :: %Admission{}

  @doc """
  Reserves an idempotency key inside the caller's current transaction.

  Returns `{:execute, admission}` for a new request, `{:replay, exact_bytes}` for a completed
  matching request, or a typed `AshOnetime.Error`. Reusing the locator with a different
  fingerprint returns `:key_reused_with_different_request`; an incomplete matching request
  returns `:request_in_progress`.
  """
  @spec idempotency(Ecto.Repo.t(), keyword()) ::
          {:execute, admission()} | {:replay, binary()} | {:error, Error.t()}
  def idempotency(repo, options) when is_atom(repo) and is_list(options) do
    with :ok <- exact_options(options, @idempotency_options),
         {:ok, common} <- common(repo, options),
         fingerprint when is_binary(fingerprint) and byte_size(fingerprint) == 32 <-
           Keyword.get(options, :fingerprint),
         retention when is_integer(retention) and retention > 0 <-
           Keyword.get(options, :retention_seconds),
         codec when is_binary(codec) <- Keyword.get(options, :codec),
         :ok <- bounded_utf8(codec, @max_codec_bytes),
         {:ok, request} <-
           Claim.idempotency(
             operation_hash: common.operation_hash,
             scope_hash: common.scope_hash,
             key_hash: common.key_hash,
             fingerprint: fingerprint,
             retention_seconds: retention
           ) do
      common.target
      |> Postgres.claim(request)
      |> resolve_idempotency(common.target, request, codec)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid_request()
    end
  rescue
    _exception -> unavailable()
  catch
    kind, reason -> contain_or_propagate(kind, reason)
  end

  def idempotency(_repo, _options), do: invalid_request()

  @doc """
  Reserves a one-time nonce inside the caller's current transaction.

  `:verified` must contain trusted `AshOnetime.Verified` facts whose exact key equals `:key`.
  A collision returns the typed `:nonce_already_used` error. No response payload is created.
  """
  @spec nonce(Ecto.Repo.t(), keyword()) :: :ok | {:error, Error.t()}
  def nonce(repo, options) when is_atom(repo) and is_list(options) do
    with :ok <- exact_options(options, @nonce_options),
         {:ok, common} <- common(repo, options),
         verified when is_list(verified) and verified != [] <- Keyword.get(options, :verified),
         true <- Enum.all?(verified, &verified_for_key?(&1, common.key)),
         max_age when is_integer(max_age) and max_age >= 0 <- Keyword.get(options, :max_age),
         clock_skew when is_integer(clock_skew) and clock_skew >= 0 <-
           Keyword.get(options, :clock_skew),
         clock when is_atom(clock) <- Keyword.get(options, :clock, AshOnetime.Clock),
         {:ok, request} <-
           Claim.nonce(
             operation_hash: common.operation_hash,
             scope_hash: common.scope_hash,
             key_hash: common.key_hash,
             verified: verified,
             max_age: max_age,
             clock_skew: clock_skew,
             clock: clock
           ) do
      common.target
      |> Postgres.claim(request)
      |> resolve_nonce(common.target, request)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid_request()
    end
  rescue
    _exception -> unavailable()
  catch
    kind, reason -> contain_or_propagate(kind, reason)
  end

  def nonce(_repo, _options), do: invalid_request()

  @doc """
  Completes a fresh idempotency admission with exact response bytes.

  Completion must run in the same process and caller-owned transaction as `idempotency/2`.
  The codec selected during admission, the SHA-256 digest, and the exact bytes are bound
  atomically to the claim.
  """
  @spec complete(admission(), binary()) :: :ok | {:error, Error.t()}
  def complete(%Admission{owner: owner} = admission, payload)
      when owner == self() and is_binary(payload) do
    digest = :crypto.hash(:sha256, payload)

    admission.target
    |> Postgres.complete(admission.claim, admission.codec, digest, payload)
    |> resolve_completion(admission, digest, payload)
  rescue
    _exception -> unavailable()
  catch
    kind, reason -> contain_or_propagate(kind, reason)
  end

  def complete(_admission, _payload), do: invalid_request()

  defp common(repo, options) do
    with {:ok, operation_hash} <- operation_hash(Keyword.get(options, :operation)),
         partition when is_binary(partition) <- Keyword.get(options, :partition),
         :ok <- bounded_utf8(partition, 255),
         scope when is_binary(scope) <- Keyword.get(options, :scope),
         :ok <- bounded_utf8(scope, @max_identity_bytes),
         key when is_binary(key) <- Keyword.get(options, :key),
         :ok <- bounded_utf8(key, @max_identity_bytes),
         {:ok, scope_hash} <- identity_hash(:transaction_scope, scope),
         {:ok, key_hash} <- identity_hash(:transaction_key, key),
         prefix <- Keyword.get(options, :prefix),
         :ok <- valid_prefix(prefix),
         target <- Postgres.for_repo(repo, prefix, logical_partition: partition) do
      {:ok,
       %{
         target: target,
         operation_hash: operation_hash,
         scope_hash: scope_hash,
         key_hash: key_hash,
         key: key
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid_request()
    end
  end

  defp operation_hash({module, action}) when is_atom(module) and is_atom(action) do
    Fingerprint.compute(%{
      domain: :transaction_operation,
      module: Atom.to_string(module),
      action: Atom.to_string(action)
    })
  end

  defp operation_hash(_operation), do: invalid_request()

  defp identity_hash(domain, value), do: Fingerprint.compute(%{domain: domain, value: value})

  defp valid_prefix(nil), do: :ok
  defp valid_prefix(value) when is_binary(value), do: bounded_utf8(value, 63)
  defp valid_prefix(_value), do: invalid_request()

  defp contain_or_propagate(
         :throw,
         {DBConnection, connection_reference, _reason} = rollback
       )
       when is_reference(connection_reference),
       do: throw(rollback)

  defp contain_or_propagate(_kind, _reason), do: unavailable()

  defp resolve_idempotency(
         %Result{status: :admitted, transaction: :open, claim: %Claim{} = claim},
         target,
         request,
         codec
       ) do
    if admitted_claim?(claim, target, request) do
      {:execute,
       %Admission{
         claim_id: claim.id,
         owner: self(),
         target: target,
         request: request,
         claim: claim,
         codec: codec
       }}
    else
      invariant_error()
    end
  end

  defp resolve_idempotency(
         %Result{
           status: :complete,
           transaction: :open,
           claim: %Claim{} = claim,
           payload: payload
         },
         target,
         request,
         codec
       )
       when is_binary(payload) do
    cond do
      not locator_matches?(claim, target, request) ->
        invariant_error()

      not digest_matches?(claim.fingerprint, request.fingerprint) ->
        fingerprint_error()

      claim.response_codec != codec ->
        invariant_error()

      not digest_matches?(:crypto.hash(:sha256, payload), claim.response_digest) ->
        invariant_error()

      true ->
        {:replay, payload}
    end
  end

  defp resolve_idempotency(
         %Result{status: :processing, transaction: :open, claim: %Claim{} = claim},
         target,
         request,
         _codec
       ) do
    cond do
      not locator_matches?(claim, target, request) -> invariant_error()
      not digest_matches?(claim.fingerprint, request.fingerprint) -> fingerprint_error()
      true -> {:error, Error.new(:request_in_progress, "request is already processing")}
    end
  end

  defp resolve_idempotency(%Result{status: :failure} = result, _target, _request, _codec),
    do: result_error(result)

  defp resolve_idempotency(_result, _target, _request, _codec), do: invariant_error()

  defp resolve_nonce(
         %Result{status: :admitted, transaction: :open, claim: %Claim{} = claim},
         target,
         request
       ) do
    if admitted_nonce?(claim, target, request), do: :ok, else: invariant_error()
  end

  defp resolve_nonce(
         %Result{status: :collision, transaction: :open, claim: %Claim{} = claim},
         target,
         request
       ) do
    if locator_matches?(claim, target, request) do
      {:error, Error.new(:nonce_already_used, "nonce was already used")}
    else
      invariant_error()
    end
  end

  defp resolve_nonce(%Result{status: :failure} = result, _target, _request),
    do: result_error(result)

  defp resolve_nonce(_result, _target, _request), do: invariant_error()

  defp resolve_completion(
         %Result{
           status: :complete,
           transaction: :open,
           claim: %Claim{} = claim,
           payload: stored
         },
         admission,
         digest,
         payload
       ) do
    if locator_matches?(claim, admission.target, admission.request) and
         claim.id == admission.claim.id and claim.state == :complete and
         claim.response_codec == admission.codec and stored == payload and
         digest_matches?(claim.response_digest, digest) do
      :ok
    else
      invariant_error()
    end
  end

  defp resolve_completion(%Result{status: :failure} = result, _admission, _digest, _payload),
    do: result_error(result)

  defp resolve_completion(_result, _admission, _digest, _payload), do: invariant_error()

  defp admitted_claim?(claim, target, request) do
    locator_matches?(claim, target, request) and claim.id == request.id and
      claim.state == :processing and digest_matches?(claim.fingerprint, request.fingerprint) and
      is_nil(claim.response_partition) and is_nil(claim.response_codec) and
      is_nil(claim.response_digest)
  end

  defp admitted_nonce?(claim, target, request) do
    locator_matches?(claim, target, request) and claim.id == request.id and
      is_nil(claim.state) and is_struct(claim.issued_at, DateTime) and
      is_binary(claim.verifier_id)
  end

  defp locator_matches?(claim, target, request) do
    claim.strategy == request.strategy and claim.logical_partition == target.logical_partition and
      digest_matches?(claim.operation_hash, request.operation_hash) and
      digest_matches?(claim.scope_hash, request.scope_hash) and
      digest_matches?(claim.key_hash, request.key_hash)
  end

  defp digest_matches?(left, right)
       when is_binary(left) and byte_size(left) == 32 and is_binary(right) and
              byte_size(right) == 32,
       do: :crypto.hash_equals(left, right)

  defp digest_matches?(_left, _right), do: false

  defp verified_for_key?(%Verified{key: key}, expected), do: key == expected
  defp verified_for_key?(_verified, _expected), do: false

  defp exact_options(options, allowed) do
    if Keyword.keyword?(options) do
      keys = Keyword.keys(options)

      if length(keys) == length(Enum.uniq(keys)) and
           Enum.sort(keys) == Enum.sort(allowed -- optional_absent(options, allowed)) do
        :ok
      else
        invalid_request()
      end
    else
      invalid_request()
    end
  end

  defp optional_absent(options, allowed) do
    Enum.filter(allowed, fn key ->
      key in [:prefix, :clock] and not Keyword.has_key?(options, key)
    end)
  end

  defp bounded_utf8(value, maximum) do
    if byte_size(value) in 1..maximum and String.valid?(value) and
         not String.contains?(value, <<0>>) do
      :ok
    else
      invalid_request()
    end
  end

  defp result_error(%Result{reason: reason}) when is_atom(reason),
    do: {:error, Error.new(reason, "authoritative admission store failed")}

  defp result_error(_result), do: unavailable()

  defp fingerprint_error,
    do:
      {:error,
       Error.new(:key_reused_with_different_request, "key was reused with a different request")}

  defp invariant_error,
    do: {:error, Error.new(:store_invariant, "store result violated an invariant")}

  defp invalid_request,
    do: {:error, Error.new(:invalid_request, "transaction admission request is invalid")}

  defp unavailable,
    do: {:error, Error.new(:admission_unavailable, "transaction admission is unavailable")}
end
