defmodule AshOnetime.Oban.ReapWorkerTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Oban.ReapWorker
  alias AshOnetime.Test.LockContention

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
    for attempt <- 1..3 do
      backoff = ReapWorker.backoff(%Oban.Job{attempt: attempt})
      assert is_integer(backoff)
      assert backoff >= 30 * attempt
      assert backoff <= 120
    end
  end

  # Contended reaping returns {:error, {:reap_failed, :lock_unavailable}}.
  # The Store reason must survive in the Oban job error.
  # A separate real connection holds the conflicting claims-table lock.
  # The contention helper releases the holder on every path.
  @tag unboxed: true
  test "worker surfaces :lock_unavailable from a contended reap (L5 behavioral)", %{
    prefix: prefix
  } do
    LockContention.with_contention(
      ~s(LOCK TABLE "#{prefix}"."ash_onetime_idempotency_claims" IN ACCESS EXCLUSIVE MODE),
      [],
      fn ->
        job = %Oban.Job{
          args: %{
            "repo" => inspect(Repo),
            "prefix" => prefix,
            "batch_size" => 100,
            "abandonment_seconds" => @horizon
          }
        }

        assert {:error, {:reap_failed, :lock_unavailable}} = ReapWorker.perform(job)
      end
    )
  end

  defp insert_abandoned(prefix, label) do
    claim_id = Ecto.UUID.generate()

    restore_fixture!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state, effect_local,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'processing', true,
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
