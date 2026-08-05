defmodule AshOnetime.Store do
  @moduledoc false

  alias AshOnetime.Store.{Claim, Postgres, Result}

  @callback claim(term(), Claim.Request.t()) :: Result.t()
  @callback claim_committed(term(), Claim.Request.t()) :: Result.t()
  @callback complete(term(), Claim.t(), binary(), binary(), binary()) :: Result.t()
  @callback complete_external(term(), Claim.t(), binary(), binary(), binary()) :: Result.t()
  @callback load(term(), Claim.t()) :: Result.t()

  @spec claim(term(), Claim.Request.t()) :: Result.t()
  def claim(target, request), do: Postgres.claim(target, request)

  @spec claim_committed(term(), Claim.Request.t()) :: Result.t()
  def claim_committed(target, request), do: Postgres.claim_committed(target, request)

  @spec complete(term(), Claim.t(), binary(), binary(), binary()) :: Result.t()
  def complete(target, claim, codec, digest, encoded_response) do
    Postgres.complete(target, claim, codec, digest, encoded_response)
  end

  @spec complete_external(term(), Claim.t(), binary(), binary(), binary()) :: Result.t()
  def complete_external(target, claim, codec, digest, encoded_response) do
    Postgres.complete_external(target, claim, codec, digest, encoded_response)
  end

  @spec load(term(), Claim.t()) :: Result.t()
  def load(target, claim), do: Postgres.load(target, claim)

  @spec cleanup(term(), pos_integer()) ::
          {:ok, %{idempotency: non_neg_integer(), nonce: non_neg_integer()}} | Result.t()
  def cleanup(target, batch_size), do: Postgres.cleanup(target, batch_size)
end
