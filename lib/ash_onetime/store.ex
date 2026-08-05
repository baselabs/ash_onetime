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

  @type cleanup_counts :: %{
          idempotency: non_neg_integer(),
          nonce: non_neg_integer(),
          payload_partitions: non_neg_integer()
        }

  @spec cleanup(term(), pos_integer()) :: {:ok, cleanup_counts()} | Result.t()
  def cleanup(target, batch_size), do: cleanup(target, batch_size, 8)

  @spec cleanup(term(), pos_integer(), non_neg_integer()) ::
          {:ok, cleanup_counts()} | Result.t()
  def cleanup(target, batch_size, partition_limit) do
    case Postgres.cleanup(target, batch_size, partition_limit) do
      {:ok, counts} = success ->
        emit_cleanup(target, counts)
        success

      %Result{} = result ->
        result
    end
  end

  defp emit_cleanup(%Postgres.Target{repo_module: repo}, counts) do
    _ =
      AshOnetime.Telemetry.cleanup(
        :idempotency,
        repo,
        :cleanup,
        counts.idempotency,
        :claims_deleted
      )

    _ =
      AshOnetime.Telemetry.cleanup(:one_time_nonce, repo, :cleanup, counts.nonce, :claims_deleted)

    _ =
      AshOnetime.Telemetry.cleanup(
        :idempotency,
        repo,
        :cleanup,
        counts.payload_partitions,
        :partitions_dropped
      )

    :ok
  end
end
