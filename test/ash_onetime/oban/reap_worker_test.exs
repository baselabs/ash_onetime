defmodule AshOnetime.Oban.ReapWorkerTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Oban.ReapWorker

  @moduletag :store

  # Comfortably above the migration's 86_400 s (1 day) hard floor.
  @horizon 7 * 86_400

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "worker reaps abandoned processing recovery points and emits reap telemetry", %{
    prefix: prefix
  } do
    parent = self()
    handler = "ash-onetime-reap-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:ash_onetime, :reap],
        fn event, measurements, metadata, _config ->
          send(parent, {:reap_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    claim_id = insert_abandoned(prefix, "oban-reap")

    job = %Oban.Job{
      args: %{
        "repo" => inspect(Repo),
        "prefix" => prefix,
        "batch_size" => 100,
        "abandonment_seconds" => @horizon
      }
    }

    assert :ok = ReapWorker.perform(job)
    assert claim_count(prefix, claim_id) == 0

    assert_receive {:reap_event, [:ash_onetime, :reap], %{count: 1}, metadata}
    assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :result_class, :strategy]
    assert metadata.action == :reap
    assert metadata.resource == Repo
    assert metadata.result_class == :claims_reaped
  end

  test "worker discards malformed, unresolvable, or below-floor arguments" do
    assert {:discard, :invalid_arguments} = ReapWorker.perform(%Oban.Job{args: %{}})

    assert {:discard, :invalid_arguments} =
             ReapWorker.perform(%Oban.Job{args: %{"repo" => "Missing.Repo"}})

    assert {:discard, :invalid_arguments} =
             ReapWorker.perform(%Oban.Job{
               args: %{"repo" => inspect(Repo), "abandonment_seconds" => 3_600}
             })
  end

  test "backoff is bounded and jittered so transient failures retry within minutes" do
    # ROADMAP H20: bounded linear+jitter backoff in [30,120]s, not the default exponential.
    for attempt <- 1..3 do
      backoff = ReapWorker.backoff(%Oban.Job{attempt: attempt})
      assert is_integer(backoff)
      assert backoff >= 30 * attempt
      assert backoff <= 120
    end
  end

  # L5: the worker error tuple embeds the Store Result.reason so Oban's job error carries the
  # distinguishable cause (:lock_timeout / :disconnected / :store_invariant / ...) past
  # exhaustion, not an opaque :reap_failed. This is a STRUCTURAL LINT (source-grep), not a
  # behavioral tripwire — it confirms the tuple shape is present and not collapsed to the bare
  # atom. It is weaker than the behavioral tripwires (T1-T4): it stays green over a dead arm
  # or a computed-atom refactor. A behavioral fault injection (force :lock_timeout via real
  # lock contention) was not added per ADR-0001's real-Postgres doctrine (real committed
  # connections, not stubs); see .forge/specs/2026-08-10-tripwire-hardening.md § T5.
  test "worker error tuple carries the inner reason, not an opaque atom (L5)" do
    source =
      File.read!(
        Path.join([__DIR__, "..", "..", "..", "lib", "ash_onetime", "oban", "reap_worker.ex"])
      )

    assert source =~ "{:error, {:reap_failed, reason}}"
    refute source =~ "{:error, :reap_failed}"
  end

  defp insert_abandoned(prefix, label) do
    claim_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'processing',
              transaction_timestamp() - interval '40 days',
              transaction_timestamp() - interval '39 days',
              transaction_timestamp() - interval '40 days')
      """,
      [
        Ecto.UUID.dump!(claim_id),
        hash("operation:" <> label),
        hash("scope:" <> label),
        hash("key:" <> label),
        hash("fingerprint:" <> label)
      ]
    )

    claim_id
  end

  defp claim_count(prefix, claim_id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
        [Ecto.UUID.dump!(claim_id)]
      )

    count
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
