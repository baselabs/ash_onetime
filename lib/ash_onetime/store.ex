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

  @type processing_backlog :: %{
          processing_count: non_neg_integer(),
          oldest_age_seconds: non_neg_integer() | nil
        }

  @doc """
  Observes the abandoned-`processing` backlog: how many idempotency recovery points are in
  `processing` state and the age, in seconds, of the oldest.

  A pull-based surface for operators to watch abandonment accumulate before it becomes a storage
  denial of service and to size the reaper's abandonment horizon. `oldest_age_seconds` is `nil`
  when there are no processing claims. Returns `{:ok, backlog}` or an `AshOnetime.Store.Result`
  failure.
  """
  @spec processing_backlog(term()) :: {:ok, processing_backlog()} | Result.t()
  def processing_backlog(target), do: Postgres.processing_backlog(target)

  @doc """
  Deletes abandoned `processing` idempotency recovery points past an abandonment horizon.

  Opt-in and bounded. A `processing` claim is reaped only when it is older than
  `abandonment_seconds` AND older than the migration's hard safety floor AND past its own
  retention horizon — the delete guard re-enforces all three, so a still-recoverable in-flight
  claim is never removed. `abandonment_seconds` must be at least the migration floor (86_400 s);
  a smaller horizon is rejected by the database.

  Returns `{:ok, reaped_count}` or an `AshOnetime.Store.Result` failure.
  """
  @spec reap(term(), pos_integer(), pos_integer()) :: {:ok, non_neg_integer()} | Result.t()
  def reap(target, batch_size, abandonment_seconds) do
    case Postgres.reap(target, batch_size, abandonment_seconds) do
      {:ok, count} = success ->
        emit_reap(target, count)
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

  defp emit_reap(%Postgres.Target{repo_module: repo}, count) do
    _ = AshOnetime.Telemetry.reap(:idempotency, repo, :reap, count, :claims_reaped)
    :ok
  end
end
