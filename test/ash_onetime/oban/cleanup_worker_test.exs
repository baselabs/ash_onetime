defmodule AshOnetime.Oban.CleanupWorkerTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Oban.CleanupWorker
  alias AshOnetime.Test.LockContention

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "worker invokes the same bounded cleanup operation with an explicit repo and prefix", %{
    prefix: prefix
  } do
    parent = self()
    handler = "ash-onetime-cleanup-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:ash_onetime, :cleanup],
        fn event, measurements, metadata, _config ->
          send(parent, {:cleanup_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    insert_expired_nonce(prefix, "oban")

    job = %Oban.Job{
      args: %{
        "repo" => inspect(Repo),
        "prefix" => prefix,
        "batch_size" => 1,
        "partition_limit" => 1
      }
    }

    assert :ok = CleanupWorker.perform(job)
    assert table_count(prefix, "ash_onetime_nonce_claims") == 0

    for _index <- 1..3 do
      assert_receive {:cleanup_event, [:ash_onetime, :cleanup], %{count: count}, metadata}
      assert is_integer(count) and count >= 0
      assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :result_class, :strategy]
      assert metadata.action == :cleanup
      assert metadata.resource == Repo
    end
  end

  test "worker discards malformed or unresolvable arguments" do
    assert {:discard, :invalid_arguments} = CleanupWorker.perform(%Oban.Job{args: %{}})

    assert {:discard, :invalid_arguments} =
             CleanupWorker.perform(%Oban.Job{args: %{"repo" => "Missing.Repo"}})
  end

  test "backoff is bounded and jittered so transient failures retry within minutes" do
    # ROADMAP H20: bounded linear+jitter backoff in [30,120]s — spaced DDL-class retries
    # with a wide jitter (ADR-0005).
    for attempt <- 1..3 do
      backoff = CleanupWorker.backoff(%Oban.Job{attempt: attempt})
      assert is_integer(backoff)
      assert backoff >= 30 * attempt
      assert backoff <= 120
    end
  end

  # L5 (behavioral): a cleanup whose first DELETE is blocked by a contended table lock
  # surfaces as {:error, {:cleanup_failed, :lock_timeout}} — the worker embeds the Store
  # Result.reason so Oban's job error carries the distinguishable cause past exhaustion, not an
  # opaque :cleanup_failed. cleanup does not set its own lock_timeout, so a short session
  # lock_timeout is set around the contention; an ACCESS EXCLUSIVE lock held on the idempotency
  # claims table in a separate connection blocks cleanup_strategy(:idempotency)'s DELETE, which
  # times out to :lock_timeout. The SET/RESET + holder release are handled by with_contention
  # so no GUC or connection leaks on any path (incl. an assertion failure).
  @tag unboxed: true
  test "worker surfaces :lock_timeout from a contended cleanup (L5 behavioral)", %{
    prefix: prefix
  } do
    LockContention.with_contention(
      ~s(LOCK TABLE "#{prefix}"."ash_onetime_idempotency_claims" IN ACCESS EXCLUSIVE MODE),
      [],
      [lock_timeout_ms: 300],
      fn ->
        job = %Oban.Job{
          args: %{
            "repo" => inspect(Repo),
            "prefix" => prefix,
            "batch_size" => 500,
            "partition_limit" => 8
          }
        }

        assert {:error, {:cleanup_failed, :lock_timeout}} = CleanupWorker.perform(job)
      end
    )
  end

  defp insert_expired_nonce(prefix, label) do
    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_nonce_claims")}
        (id, operation_hash, scope_hash, key_hash, issued_at, verifier_id,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4,
              transaction_timestamp() - interval '3 hours', 'test',
              transaction_timestamp() - interval '2 hours',
              transaction_timestamp() - interval '1 hour',
              transaction_timestamp() - interval '2 hours')
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        hash("o:#{label}"),
        hash("s:#{label}"),
        hash("k:#{label}")
      ]
    )
  end

  defp table_count(prefix, table) do
    %{rows: [[count]]} = SQL.query!(Repo, "SELECT count(*) FROM #{relation(prefix, table)}", [])
    count
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
