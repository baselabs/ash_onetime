defmodule AshOnetime.Store.Claim do
  @moduledoc false

  alias AshOnetime.Verified

  @hash_bytes 32
  @max_verifier_id_bytes 128
  @max_retention_seconds 2_147_483_647

  defmodule Request do
    @moduledoc false

    @enforce_keys [:strategy, :id, :operation_hash, :scope_hash, :key_hash]
    defstruct [
      :strategy,
      :id,
      :operation_hash,
      :scope_hash,
      :key_hash,
      :fingerprint,
      :retention_seconds,
      :verified,
      :max_age,
      :clock_skew,
      clock: AshOnetime.Clock
    ]

    @type t :: %__MODULE__{
            strategy: :idempotency | :one_time_nonce,
            id: Ecto.UUID.t(),
            operation_hash: binary(),
            scope_hash: binary(),
            key_hash: binary(),
            fingerprint: binary() | nil,
            retention_seconds: pos_integer() | nil,
            verified: Verified.t() | nil,
            max_age: non_neg_integer() | nil,
            clock_skew: non_neg_integer() | nil,
            clock: module()
          }
  end

  @enforce_keys [
    :strategy,
    :id,
    :operation_hash,
    :scope_hash,
    :key_hash,
    :admitted_at,
    :retain_until,
    :inserted_at
  ]
  defstruct [
    :strategy,
    :id,
    :operation_hash,
    :scope_hash,
    :key_hash,
    :fingerprint,
    :state,
    :response_partition,
    :response_codec,
    :response_digest,
    :issued_at,
    :expires_at,
    :verifier_id,
    :admitted_at,
    :retain_until,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          strategy: :idempotency | :one_time_nonce,
          id: Ecto.UUID.t(),
          operation_hash: binary(),
          scope_hash: binary(),
          key_hash: binary(),
          fingerprint: binary() | nil,
          state: :processing | :complete | nil,
          response_partition: Date.t() | nil,
          response_codec: binary() | nil,
          response_digest: binary() | nil,
          issued_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          verifier_id: binary() | nil,
          admitted_at: DateTime.t(),
          retain_until: DateTime.t(),
          inserted_at: DateTime.t()
        }

  @spec idempotency(keyword()) :: {:ok, Request.t()} | {:error, :invalid_request}
  def idempotency(attributes) when is_list(attributes) do
    with {:ok, common} <- common(attributes),
         fingerprint when is_binary(fingerprint) and byte_size(fingerprint) == @hash_bytes <-
           Keyword.get(attributes, :fingerprint),
         retention_seconds
         when is_integer(retention_seconds) and retention_seconds > 0 and
                retention_seconds <= @max_retention_seconds <-
           Keyword.get(attributes, :retention_seconds) do
      {:ok,
       struct!(
         Request,
         common ++
           [
             strategy: :idempotency,
             fingerprint: fingerprint,
             retention_seconds: retention_seconds
           ]
       )}
    else
      _other -> {:error, :invalid_request}
    end
  end

  def idempotency(_attributes), do: {:error, :invalid_request}

  @spec nonce(keyword()) :: {:ok, Request.t()} | {:error, :invalid_request}
  def nonce(attributes) when is_list(attributes) do
    with {:ok, common} <- common(attributes),
         %Verified{verifier_id: verifier_id} = verified <- Keyword.get(attributes, :verified),
         true <- valid_verifier_id?(verifier_id),
         max_age when is_integer(max_age) and max_age >= 0 <- Keyword.get(attributes, :max_age),
         clock_skew when is_integer(clock_skew) and clock_skew >= 0 <-
           Keyword.get(attributes, :clock_skew),
         clock when is_atom(clock) <- Keyword.get(attributes, :clock, AshOnetime.Clock) do
      {:ok,
       struct!(
         Request,
         common ++
           [
             strategy: :one_time_nonce,
             verified: verified,
             max_age: max_age,
             clock_skew: clock_skew,
             clock: clock
           ]
       )}
    else
      _other -> {:error, :invalid_request}
    end
  end

  def nonce(_attributes), do: {:error, :invalid_request}

  defp common(attributes) do
    values =
      for name <- [:operation_hash, :scope_hash, :key_hash] do
        {name, Keyword.get(attributes, name)}
      end

    if Enum.all?(values, fn {_name, value} ->
         is_binary(value) and byte_size(value) == @hash_bytes
       end) do
      {:ok, [id: Ecto.UUID.generate()] ++ values}
    else
      {:error, :invalid_request}
    end
  end

  defp valid_verifier_id?(value) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_verifier_id_bytes
  end
end
