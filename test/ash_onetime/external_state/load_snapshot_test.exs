for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.LoadSnapshotTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_load_snapshot_mutation

    test "#{partitioning || "plain"}: expiry cannot remove a replay's payload between its claim and payload reads",
         c do
      grant = Postgres.claim_committed(target(c), request!("snapshot"), lock_timeout_ms: 300)
      complete_claim(c, grant.claim.id)
      age_claim(c, grant.claim.id, retain: "transaction_timestamp()+interval '1 day'")
      parent = self()
      handler = {__MODULE__, make_ref()}
      once = :atomics.new(1, [])

      :ok =
        :telemetry.attach(
          handler,
          Repo.config()[:telemetry_prefix] ++ [:query],
          fn _, _, metadata, _ ->
            if is_binary(metadata.query) and String.contains?(metadata.query, c.schema) and
                 String.contains?(metadata.query, "FOR NO KEY UPDATE OF claims") and
                 :atomics.compare_exchange(once, 1, 0, 1) == :ok do
              send(parent, {:claim_read, self()})

              receive do
                {:continue_replay, ^handler} -> :ok
              after
                5000 -> raise "replay barrier expired"
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      reader_repo = connection!(c, :runtime, 1)
      reader_c = %{c | runtime_repo: reader_repo}

      reader =
        Task.async(fn ->
          runtime_transaction(reader_c, fn ->
            Postgres.load(%{target(c) | dynamic_repo: reader_repo}, grant.claim,
              lock_timeout_ms: 300
            )
          end)
        end)

      assert_receive {:claim_read, backend}, 3000

      try do
        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_expire_responses", "100")
      after
        :telemetry.detach(handler)
        send(backend, {:continue_replay, handler})
      end

      assert {:ok, %Result{status: :complete, payload: "response"}} = Task.await(reader, 5000)
      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_expire_responses", "100")
    end

    test "#{partitioning || "plain"}: replay queued behind completion reads its newly committed payload",
         c do
      grant = Postgres.claim_committed(target(c), request!("queued-replay"), lock_timeout_ms: 300)
      parent = self()

      completer =
        Task.async(fn ->
          runtime_transaction(c, fn ->
            assert %Result{status: :complete} =
                     Postgres.complete_external(
                       target(c),
                       grant.claim,
                       "test",
                       :crypto.hash(:sha256, "response"),
                       "response",
                       nil,
                       lock_timeout_ms: 300
                     )

            send(parent, {:completed_uncommitted, self()})

            receive do
              :commit -> :ok
            end
          end)
        end)

      assert_receive {:completed_uncommitted, completer_pid}, 2000
      reader_repo = connection!(c, :runtime, 1)
      backend = scalar(reader_repo, "SELECT pg_backend_pid()")

      reader =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: reader_repo}, fn ->
            Postgres.load(%{target(c) | dynamic_repo: reader_repo}, grant.claim,
              lock_timeout_ms: 2000
            )
          end)
        end)

      try do
        Enum.reduce_while(1..200, nil, fn _, _ ->
          if scalar(
               c.owner_repo,
               "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid=$1 AND NOT granted)",
               [backend]
             ) do
            {:halt, :waiting}
          else
            receive do
            after
              5 -> :ok
            end

            {:cont, nil}
          end
        end)
        |> then(&assert(&1 == :waiting))
      after
        send(completer_pid, :commit)
        assert {:ok, :ok} = Task.await(completer, 5000)
      end

      assert {:ok, %Result{status: :complete, payload: "response"}} = Task.await(reader, 5000)
    end

    @tag :external_state_load_after_claim_lock_mutation
    test "#{partitioning || "plain"}: lock wait, outcome during the wait", c do
      grant = Postgres.claim_committed(target(c), request!("wait-outcome"), lock_timeout_ms: 1000)
      parent = self()
      holder_repo = connection!(c, :runtime, 1)

      holder =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: holder_repo}, fn ->
            SQL.query!(holder_repo, "SET LOCAL lock_timeout='2s'", [])

            SQL.query!(
              holder_repo,
              "SELECT id FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid FOR NO KEY UPDATE",
              [Ecto.UUID.dump!(grant.claim.id)]
            )

            send(parent, {:holder_locked, self()})

            receive do
              :commit -> :ok
            after
              5000 -> flunk("claim holder was not released")
            end
          end)
        end)

      assert_receive {:holder_locked, holder_pid}, 2000
      reader_repo = connection!(c, :runtime, 1)
      backend = scalar(reader_repo, "SELECT pg_backend_pid()")

      reader =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: reader_repo}, fn ->
            Postgres.load(%{target(c) | dynamic_repo: reader_repo}, grant.claim,
              lock_timeout_ms: 2000
            )
          end)
        end)

      try do
        await_wait(c, backend)

        assert %Result{status: :processing, transaction: :committed} =
                 Postgres.record_outcome_committed(target(c), grant.claim, :held,
                   lock_timeout_ms: 1000
                 )
      after
        send(holder_pid, :commit)
        assert {:ok, :ok} = Task.await(holder, 3000)
      end

      assert {:ok, %Result{status: :processing, claim: %{effect_state: :held}}} =
               Task.await(reader, 3000)
    end

    test "#{partitioning || "plain"}: replay queued behind expiry uses its committed claim columns",
         c do
      grant =
        Postgres.claim_committed(target(c), request!("queued-expiry"), lock_timeout_ms: 1000)

      complete_claim(c, grant.claim.id)
      age_claim(c, grant.claim.id, retain: "transaction_timestamp()+interval '1 day'")
      parent = self()
      expiry_repo = connection!(c, :maintainer, 1)

      expiry =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(expiry_repo)

          try do
            Repo.transaction(fn ->
              SQL.query!(expiry_repo, "SET LOCAL lock_timeout='2s'", [])

              assert %{rows: [[1]]} =
                       SQL.query!(
                         expiry_repo,
                         "SELECT #{routine(c, "ash_onetime_expire_responses")}(100)",
                         []
                       )

              send(parent, {:expiry_held, self()})

              receive do
                :commit -> :ok
              after
                5000 -> flunk("expiry was not released")
              end
            end)
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      assert_receive {:expiry_held, expiry_pid}, 2000
      reader_repo = connection!(c, :runtime, 1)
      backend = scalar(reader_repo, "SELECT pg_backend_pid()")

      reader =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: reader_repo}, fn ->
            Postgres.load(%{target(c) | dynamic_repo: reader_repo}, grant.claim,
              lock_timeout_ms: 2000
            )
          end)
        end)

      try do
        await_wait(c, backend)
      after
        send(expiry_pid, :commit)
        assert {:ok, :ok} = Task.await(expiry, 3000)
      end

      assert {:ok, %Result{status: :complete_expired}} = Task.await(reader, 3000)
    end

    defp await_wait(c, backend, remaining \\ 200) do
      if scalar(
           c.owner_repo,
           "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid=$1 AND NOT granted)",
           [backend]
         ) do
        :ok
      else
        assert remaining > 0
        Process.sleep(5)
        await_wait(c, backend, remaining - 1)
      end
    end
  end
end
