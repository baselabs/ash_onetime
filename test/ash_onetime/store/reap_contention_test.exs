defmodule AshOnetime.Store.ReapContentionTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Store
  alias AshOnetime.Store.{Claim, Postgres, Result}
  alias AshOnetime.Test.{Migration, RealConnection, Repo}
  alias Ecto.Adapters.SQL

  @moduletag :store

  # Cross-process coordination ceiling. The spawned completer/reaper reach their observable
  # state in milliseconds on a healthy machine; this bound only adds headroom on a loaded CI
  # runner, and stays well under ExUnit's 60s per-test timeout even across three sequential waits.
  @receive_timeout 10_000

  # Comfortably above the migration's 86_400 s (1 day) hard floor and any legitimate in-flight
  # window, so a genuinely abandoned recovery point is reapable.
  @horizon 7 * 86_400

  @database_options [
    hostname: "127.0.0.1",
    port: 18_841,
    username: "postgres",
    password: "postgres",
    database: System.get_env("ASH_ONETIME_EXPECTED_TEST_DATABASE", "ash_onetime_test")
  ]

  setup_all do
    installation = Migration.install_generated!()
    on_exit(fn -> Migration.uninstall_generated!(installation) end)
    {:ok, prefix: installation.schema}
  end

  # C3 reverse interleave: a reap running while a recovery of the SAME abandoned claim is
  # mid-finalization must SKIP the row the finalizer holds locked, never delete a live commit.
  @tag reap_skips_locked_recovery_mutation: true
  test "the reaper skips a recovery point locked by an in-flight finalization", %{prefix: prefix} do
    target = Postgres.for_repo(Repo, prefix)
    observer = observer!()
    claim = insert_abandoned_processing!(prefix, "reap-skip-locked")
    parent = self()

    completer = spawn(fn -> completer_worker(parent, target, claim) end)
    # Best-effort teardown: a graceful release lets the finalizer commit and clean up its
    # connection even if an assertion below fails (and unblocks a reaper that a mutant made wait),
    # so the shared schema's DROP never deadlocks on an orphaned row lock.
    on_exit(fn -> if Process.alive?(completer), do: send(completer, :release) end)

    send(completer, :start)
    assert_receive {:completer_ready, ^completer, %Result{status: :complete}}, @receive_timeout

    # The finalizer now holds the claim row locked (updated to complete, uncommitted). A concurrent
    # reap must observe the still-committed `processing` row, find it locked, and SKIP it.
    reaper = spawn(fn -> reaper_worker(parent, target) end)
    send(reaper, :start)
    assert_receive {:reaper_done, ^reaper, {:ok, 0}}, @receive_timeout

    send(completer, :release)

    assert_receive {:completer_done, ^completer, {:ok, %Result{status: :complete}}},
                   @receive_timeout

    # The recovery point survived the reap and finalized normally.
    assert claim_state(observer, prefix, claim.id) == "complete"
    assert payload_count(observer, prefix, claim.id) == 1
  end

  # C3 forward interleave: once a reaper has removed an abandoned recovery point, a lagging
  # finalizer of the same claim must fail closed with a FULL rollback — no orphan payload row may
  # outlive the reaped claim.
  test "finalizing a reaped recovery point fails closed and leaves no orphan payload", %{
    prefix: prefix
  } do
    target = Postgres.for_repo(Repo, prefix)
    observer = observer!()
    claim = insert_abandoned_processing!(prefix, "reap-then-complete")

    assert {:ok, 1} = RealConnection.with_connection(fn -> Store.reap(target, 100, @horizon) end)

    payload = "reap-orphan-guard"
    digest = :crypto.hash(:sha256, payload)

    result =
      RealConnection.with_connection(fn ->
        Repo.transaction(fn -> Store.complete(target, claim, "test", digest, payload) end)
      end)

    assert {:error,
            %Result{status: :failure, reason: :store_invariant, transaction: :rolled_back}} =
             result

    assert claim_count(observer, prefix, claim.id) == 0
    assert payload_count(observer, prefix, claim.id) == 0
  end

  # --- workers ---

  defp completer_worker(parent, target, claim) do
    receive do
      :start -> :ok
    end

    result =
      RealConnection.with_connection(fn ->
        Repo.transaction(fn ->
          payload = "reap-skip-locked-payload"

          complete =
            Store.complete(target, claim, "test", :crypto.hash(:sha256, payload), payload)

          send(parent, {:completer_ready, self(), complete})

          receive do
            :release -> complete
          end
        end)
      end)

    send(parent, {:completer_done, self(), result})
  end

  defp reaper_worker(parent, target) do
    receive do
      :start -> :ok
    end

    result = RealConnection.with_connection(fn -> Store.reap(target, 100, @horizon) end)
    send(parent, {:reaper_done, self(), result})
  end

  # --- helpers ---

  defp insert_abandoned_processing!(prefix, label) do
    claim_id = Ecto.UUID.generate()

    RealConnection.with_connection(fn ->
      Repo.transaction(fn ->
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
      end)
    end)

    # `Store.complete` reads only the claim id and its logical key (operation/scope/key hash); the
    # timestamps below are never inspected by completion and stand in for the persisted row.
    %Claim{
      strategy: :idempotency,
      id: claim_id,
      logical_partition: "global",
      operation_hash: hash("operation:" <> label),
      scope_hash: hash("scope:" <> label),
      key_hash: hash("key:" <> label),
      fingerprint: hash("fingerprint:" <> label),
      state: :processing,
      admitted_at: ~U[2020-01-01 00:00:00Z],
      retain_until: ~U[2020-01-02 00:00:00Z],
      inserted_at: ~U[2020-01-01 00:00:00Z]
    }
  end

  defp observer! do
    {:ok, observer} = Postgrex.start_link(@database_options)
    Process.unlink(observer)

    on_exit(fn ->
      if Process.alive?(observer), do: GenServer.stop(observer, :normal, 5_000)
    end)

    observer
  end

  defp claim_state(observer, prefix, id) do
    %{rows: rows} =
      Postgrex.query!(
        observer,
        "SELECT state FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      )

    case rows do
      [[state]] -> state
      [] -> nil
    end
  end

  defp claim_count(observer, prefix, id) do
    %{rows: [[count]]} =
      Postgrex.query!(
        observer,
        "SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      )

    count
  end

  defp payload_count(observer, prefix, id) do
    %{rows: [[count]]} =
      Postgrex.query!(
        observer,
        "SELECT count(*) FROM #{relation(prefix, "ash_onetime_response_payloads")} WHERE claim_id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      )

    count
  end

  defp hash(value), do: :crypto.hash(:sha256, value)
  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
