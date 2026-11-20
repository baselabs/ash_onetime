for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.LockMatrixTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Store.Claim
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_lock_matrix_mutation

    test "#{partitioning || "plain"}: P7 expiry processes a claim while an uncommitted outcome holds KEY SHARE",
         c do
      id =
        insert_claim(c)
        |> then(&complete_claim(c, &1))
        |> then(&age_claim(c, &1, retain: "transaction_timestamp()+interval '1 day'"))

      worker_repo = connection!(c, :runtime, 1)
      parent = self()

      worker =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(worker_repo)

          try do
            Repo.transaction(fn ->
              SQL.query!(worker_repo, "SET LOCAL lock_timeout='5s'", [])
              assert {:ok, _} = record_outcome(%{c | runtime_repo: worker_repo}, id)
              send(parent, {:outcome_inserted, self()})

              receive do
                :release -> :ok
              after
                10_000 -> flunk("outcome barrier was not released")
              end
            end)
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      try do
        assert_receive {:outcome_inserted, _}, 5_000
        started = System.monotonic_time(:millisecond)

        assert {:ok, %{rows: [[1, backend]]}} =
                 SQL.query(
                   c.maintainer_repo,
                   "SELECT #{routine(c, "ash_onetime_expire_responses")}(100),pg_backend_pid()",
                   []
                 )

        assert System.monotonic_time(:millisecond) - started < 500

        assert scalar(
                 c.owner_repo,
                 "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted",
                 [backend]
               ) == 0

        assert scalar(
                 c.runtime_repo,
                 "SELECT response_expired_at IS NOT NULL FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
                 [Ecto.UUID.dump!(id)]
               )
      after
        send(worker.pid, :release)
        Task.await(worker, 5_000)
      end
    end

    for {pair, phase} <- [{"P1", :classify}, {"P2", :finalize_read}, {"P14", :replay}] do
      test "#{partitioning || "plain"}: #{pair} a late outcome commits while the caller holds its claim",
           c do
        key = "late-#{unquote(pair)}"
        first = Postgres.claim_committed(target(c), request!(key), lock_timeout_ms: 1000)
        grant = Postgres.claim_committed(target(c), request!(key), lock_timeout_ms: 1000)
        if unquote(phase) == :replay, do: complete_claim(c, grant.claim.id)

        {holder, _, locked} =
          hold(c, :runtime, fn repo ->
            t = %{target(c) | dynamic_repo: repo}

            if unquote(phase) == :replay do
              Postgres.load(t, grant.claim, lock_timeout_ms: 1000)
            else
              assert %Result{status: :processing} =
                       Postgres.lock_for_effect(t, grant.claim, lock_timeout_ms: 1000)

              if unquote(phase) == :finalize_read,
                do: Postgres.load(t, grant.claim, lock_timeout_ms: 1000),
                else: :locked
            end
          end)

        worker_repo = connection!(c, :runtime, 1)
        t = %{target(c) | dynamic_repo: worker_repo}
        backend = scalar(worker_repo, "SELECT pg_backend_pid()")

        try do
          started = System.monotonic_time(:millisecond)

          assert %Result{status: :processing, transaction: :committed} =
                   Postgres.record_outcome_committed(t, first.claim, :held, lock_timeout_ms: 1000)

          assert System.monotonic_time(:millisecond) - started < 100

          assert scalar(
                   c.owner_repo,
                   "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted",
                   [backend]
                 ) == 0

          if unquote(phase) == :replay,
            do: assert(%Result{status: :complete, payload: "response"} = locked)
        after
          release(holder)
        end
      end
    end

    @tag :enforcement_nonce_select_lock_mutation
    test "#{partitioning || "plain"}: nonce load waits for the native row lock", c do
      {:ok, request} =
        Claim.nonce(
          operation_hash: :crypto.hash(:sha256, "nonce-lock-operation"),
          scope_hash: :crypto.hash(:sha256, "nonce-lock-scope"),
          key_hash: :crypto.hash(:sha256, "nonce-select-lock"),
          verified: [
            %AshOnetime.Verified{
              key: "nonce-select-lock",
              issued_at: DateTime.utc_now(),
              verifier_id: "native"
            }
          ],
          max_age: 60,
          clock_skew: 0,
          clock: AshOnetime.Clock
        )

      assert {:ok, %Result{status: :admitted, claim: claim}} =
               runtime_transaction(c, fn -> Postgres.claim(target(c), request) end)

      {holder, _, _} =
        hold(c, :runtime, fn repo ->
          SQL.query!(
            repo,
            "SELECT id FROM #{rel(c, "ash_onetime_nonce_claims")} WHERE id=$1::uuid FOR UPDATE",
            [Ecto.UUID.dump!(claim.id)]
          )
        end)

      try do
        parent = self()

        runtime_transaction(c, fn ->
          send(parent, {:nonce_load, Postgres.load(target(c), claim, lock_timeout_ms: 300)})
        end)

        assert_receive {:nonce_load, %Result{status: :failure, reason: :lock_timeout}}, 1000
      after
        release(holder)
      end
    end

    test "#{partitioning || "plain"}: P3 an outcome commits beside uncommitted completion", c do
      grant = Postgres.claim_committed(target(c), request!("P3"), lock_timeout_ms: 1000)

      {holder, _, %Result{status: :complete}} =
        hold(c, :runtime, fn repo ->
          t = %{target(c) | dynamic_repo: repo}

          assert %Result{status: :processing} =
                   Postgres.lock_for_effect(t, grant.claim, lock_timeout_ms: 1000)

          Postgres.complete_external(
            t,
            grant.claim,
            "test",
            :crypto.hash(:sha256, "response"),
            "response",
            nil,
            lock_timeout_ms: 1000
          )
        end)

      try do
        assert %Result{status: :processing, transaction: :committed} =
                 Postgres.record_outcome_committed(target(c), grant.claim, :held,
                   lock_timeout_ms: 1000
                 )
      after
        release(holder)
      end
    end

    for {pair, action} <- [
          {"P4", :classify},
          {"P5", :complete},
          {"P6", :release},
          {"P9", :outcome}
        ] do
      test "#{partitioning || "plain"}: #{pair} an uncommitted outcome does not block compatible work",
           c do
        grant =
          Postgres.claim_committed(target(c), request!(unquote(pair)), lock_timeout_ms: 1000)

        grant =
          if unquote(action) == :outcome,
            do:
              Postgres.claim_committed(target(c), request!(unquote(pair)), lock_timeout_ms: 1000),
            else: grant

        if unquote(action) == :release, do: complete_claim(c, grant.claim.id, hold: "held")

        {holder, _, _} =
          hold(c, :runtime, fn repo ->
            assert {:ok, _} = record_outcome(%{c | runtime_repo: repo}, grant.claim.id, :held, 1)
          end)

        try do
          started = System.monotonic_time(:millisecond)

          case unquote(action) do
            :outcome ->
              assert %Result{status: :processing, transaction: :committed} =
                       Postgres.record_outcome_committed(target(c), grant.claim, :held,
                         lock_timeout_ms: 1000
                       )

            :release ->
              assert {:ok, {:ok, 1}} =
                       runtime_transaction(c, fn -> Postgres.release(target(c), "held") end)

            action ->
              assert {:ok, %Result{status: status}} =
                       runtime_transaction(c, fn -> run_caller(c, grant, action) end)

              assert status in [:processing, :complete]
          end

          assert System.monotonic_time(:millisecond) - started < 100
        after
          release(holder)
        end
      end
    end

    test "#{partitioning || "plain"}: P13 cleanup cascades C2 without touching locked C1", c do
      grant = Postgres.claim_committed(target(c), request!("P13-C1"), lock_timeout_ms: 1000)

      c2 =
        insert_claim(c, key: "P13-C2") |> then(&complete_claim(c, &1)) |> then(&age_claim(c, &1))

      assert {:ok, _} = record_outcome(c, c2)

      {holder, _, _} =
        hold(c, :runtime, fn repo ->
          Postgres.lock_for_effect(%{target(c) | dynamic_repo: repo}, grant.claim,
            lock_timeout_ms: 1000
          )
        end)

      try do
        assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")

        assert scalar(
                 c.runtime_repo,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1::uuid",
                 [Ecto.UUID.dump!(c2)]
               ) == 0

        assert scalar(
                 c.runtime_repo,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
                 [Ecto.UUID.dump!(grant.claim.id)]
               ) == 1
      after
        release(holder)
      end
    end

    test "#{partitioning || "plain"}: P8 a queued grant does not stop a late outcome beside the caller",
         c do
      grant = Postgres.claim_committed(target(c), request!("P8"), lock_timeout_ms: 1000)

      {holder, _, _} =
        hold(c, :runtime, fn repo ->
          Postgres.lock_for_effect(%{target(c) | dynamic_repo: repo}, grant.claim,
            lock_timeout_ms: 1000
          )
        end)

      queued_repo = connection!(c, :runtime, 1)
      backend = scalar(queued_repo, "SELECT pg_backend_pid()")

      queued =
        Task.async(fn ->
          Postgres.claim_committed(%{target(c) | dynamic_repo: queued_repo}, request!("P8"),
            lock_timeout_ms: 3000
          )
        end)

      try do
        await_wait(c, backend)
        started = System.monotonic_time(:millisecond)

        assert %Result{status: :processing, transaction: :committed} =
                 Postgres.record_outcome_committed(target(c), grant.claim, :held,
                   lock_timeout_ms: 1000
                 )

        assert System.monotonic_time(:millisecond) - started < 100
      after
        release(holder)
      end

      assert %Result{status: :processing} = Task.await(queued, 5000)
    end

    test "#{partitioning || "plain"}: P10 maintenance table locks permit reserve, caller and outcome statements",
         c do
      {holder, _, _} =
        hold(c, :owner, fn repo ->
          SQL.query!(repo, "SELECT #{routine(c, "ash_onetime_maintenance_lock")}(false,5000)", [])
        end)

      try do
        started = System.monotonic_time(:millisecond)
        grant = Postgres.claim_committed(target(c), request!("P10"), lock_timeout_ms: 2000)
        assert %Result{status: :admitted} = grant

        assert {:ok, %Result{status: :processing}} =
                 runtime_transaction(c, fn ->
                   Postgres.lock_for_effect(target(c), grant.claim, lock_timeout_ms: 2000)
                 end)

        assert %Result{status: :processing} =
                 Postgres.record_outcome_committed(target(c), grant.claim, :held,
                   lock_timeout_ms: 2000
                 )

        assert {:ok, %Result{status: :complete}} =
                 runtime_transaction(c, fn ->
                   Postgres.complete_external(
                     target(c),
                     grant.claim,
                     "test",
                     :crypto.hash(:sha256, "response"),
                     "response",
                     nil,
                     lock_timeout_ms: 2000
                   )
                 end)

        assert System.monotonic_time(:millisecond) - started < 200
      after
        release(holder)
      end
    end

    test "#{partitioning || "plain"}: P11 outcome visibility reads do not lock the caller's claim",
         c do
      grant = Postgres.claim_committed(target(c), request!("P11"), lock_timeout_ms: 1000)
      assert {:ok, _} = record_outcome(c, grant.claim.id)

      {holder, _, _} =
        hold(c, :runtime, fn repo ->
          Postgres.lock_for_effect(%{target(c) | dynamic_repo: repo}, grant.claim,
            lock_timeout_ms: 1000
          )
        end)

      reader = connection!(c, :runtime, 1)
      SQL.query!(reader, "SET lock_timeout='1s'", [])
      backend = scalar(reader, "SELECT pg_backend_pid()")

      try do
        started = System.monotonic_time(:millisecond)

        assert scalar(
                 reader,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1::uuid",
                 [Ecto.UUID.dump!(grant.claim.id)]
               ) == 1

        assert System.monotonic_time(:millisecond) - started < 100

        assert scalar(
                 c.owner_repo,
                 "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted",
                 [backend]
               ) == 0
      after
        release(holder)
      end
    end

    for {pair, operation} <- [{"B1", :grant}, {"B2", :classify}] do
      test "#{partitioning || "plain"}: #{pair} caller or grant contention ends at its armed bound",
           c do
        key = unquote(pair)
        grant = Postgres.claim_committed(target(c), request!(key), lock_timeout_ms: 1000)

        {holder, _, _} =
          hold(c, :runtime, fn repo ->
            Postgres.lock_for_effect(%{target(c) | dynamic_repo: repo}, grant.claim,
              lock_timeout_ms: 1000
            )
          end)

        waiter_repo = connection!(c, :runtime, 1)
        backend = scalar(waiter_repo, "SELECT pg_backend_pid()")

        waiter =
          Task.async(fn ->
            t = %{target(c) | dynamic_repo: waiter_repo}

            if unquote(operation) == :grant do
              Postgres.claim_committed(t, request!(key), lock_timeout_ms: 500)
            else
              {:error, result} =
                runtime_transaction(%{c | runtime_repo: waiter_repo}, fn ->
                  result = Postgres.lock_for_effect(t, grant.claim, lock_timeout_ms: 500)
                  Repo.rollback(result)
                end)

              result
            end
          end)

        try do
          await_wait(c, backend)
          assert %Result{status: :failure, reason: :lock_timeout} = Task.await(waiter, 2000)
        after
          release(holder)
        end
      end
    end

    for resolution <- [:timeout, :commit, :rollback] do
      test "#{partitioning || "plain"}: B4 outcome FK waits for cleanup #{resolution}", c do
        grant =
          Postgres.claim_committed(target(c), request!("B4-#{unquote(resolution)}"),
            lock_timeout_ms: 1000
          )

        complete_claim(c, grant.claim.id)
        age_claim(c, grant.claim.id)

        {holder, _, _} =
          hold(c, :maintainer, fn repo ->
            SQL.query!(repo, "SELECT #{routine(c, "ash_onetime_cleanup_idempotency")}(100)", [])
          end)

        worker_repo = connection!(c, :runtime, 1)
        backend = scalar(worker_repo, "SELECT pg_backend_pid()")

        worker =
          Task.async(fn ->
            Postgres.record_outcome_committed(
              %{target(c) | dynamic_repo: worker_repo},
              grant.claim,
              :held,
              lock_timeout_ms: 600
            )
          end)

        try do
          await_wait(c, backend)

          if unquote(resolution) != :timeout do
            send(holder.pid, if(unquote(resolution) == :commit, do: :release, else: :rollback))
            Task.await(holder, 3000)
          end

          result = Task.await(worker, 2000)

          if unquote(resolution) == :rollback do
            assert %Result{status: :processing, transaction: :committed} = result
          else
            assert %Result{status: :failure, reason: :outcome_unrecorded} = result
          end
        after
          if Process.alive?(holder.pid), do: release(holder)
        end
      end
    end

    test "#{partitioning || "plain"}: B5 cleanup skips an uncommitted outcome then cascades after commit",
         c do
      grant = Postgres.claim_committed(target(c), request!("B5"), lock_timeout_ms: 1000)
      complete_claim(c, grant.claim.id)
      age_claim(c, grant.claim.id)

      {barrier, worker, handler} =
        statement_barrier(c, "INSERT INTO #{rel(c, "ash_onetime_effect_outcomes")}", fn repo ->
          Postgres.record_outcome_committed(%{target(c) | dynamic_repo: repo}, grant.claim, :held,
            lock_timeout_ms: 1000
          )
        end)

      try do
        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")

        assert scalar(
                 c.owner_repo,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
               ) == 1
      after
        release_statement(barrier, worker, handler)
      end

      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")

      assert scalar(c.owner_repo, "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}") ==
               0
    end

    test "#{partitioning || "plain"}: B7 expiry and cleanup skip the locked caller and process after release",
         c do
      grant = Postgres.claim_committed(target(c), request!("B7"), lock_timeout_ms: 1000)
      complete_claim(c, grant.claim.id)
      age_claim(c, grant.claim.id)

      {holder, _, _} =
        hold(c, :runtime, fn repo ->
          Postgres.load(%{target(c) | dynamic_repo: repo}, grant.claim, lock_timeout_ms: 1000)
        end)

      try do
        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_expire_responses", "100")
        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")

        assert scalar(
                 c.owner_repo,
                 "SELECT response_expired_at IS NULL FROM #{rel(c, "ash_onetime_idempotency_claims")}"
               )
      after
        release(holder)
      end

      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_expire_responses", "100")
      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")
    end

    for operation <- [:reserve, :outcome] do
      test "#{partitioning || "plain"}: #{if operation == :reserve, do: "U1/B10", else: "U2"} unique-index contention is bounded",
           c do
        key = "unique-#{unquote(operation)}"

        grant =
          if unquote(operation) == :outcome,
            do: Postgres.claim_committed(target(c), request!(key), lock_timeout_ms: 1000)

        table =
          if unquote(operation) == :reserve,
            do: "ash_onetime_idempotency_claims",
            else: "ash_onetime_effect_outcomes"

        action = fn repo, timeout ->
          t = %{target(c) | dynamic_repo: repo}

          if unquote(operation) == :reserve,
            do: Postgres.claim_committed(t, request!(key), lock_timeout_ms: timeout),
            else:
              Postgres.record_outcome_committed(t, grant.claim, :held, lock_timeout_ms: timeout)
        end

        {barrier, worker, handler} =
          statement_barrier(c, "INSERT INTO #{rel(c, table)}", &action.(&1, 1000))

        waiter_repo = connection!(c, :runtime, 1)
        backend = scalar(waiter_repo, "SELECT pg_backend_pid()")
        waiter = Task.async(fn -> action.(waiter_repo, 500) end)

        try do
          await_wait(c, backend)

          assert scalar(
                   c.owner_repo,
                   "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted AND locktype='transactionid'",
                   [backend]
                 ) > 0

          result = Task.await(waiter, 2000)
          assert %Result{status: :failure} = result

          assert result.reason ==
                   if(unquote(operation) == :reserve,
                     do: :lock_timeout,
                     else: :outcome_unrecorded
                   )
        after
          release_statement(barrier, worker, handler)
        end
      end
    end

    test "#{partitioning || "plain"}: B11 completion's payload write is bounded and leaves the original claim",
         c do
      grant = Postgres.claim_committed(target(c), request!("B11"), lock_timeout_ms: 1000)

      {holder, _, _} =
        hold(c, :owner, fn repo ->
          SQL.query!(
            repo,
            "LOCK TABLE #{rel(c, "ash_onetime_response_payloads")} IN ACCESS EXCLUSIVE MODE",
            []
          )
        end)

      try do
        assert {:error, %AshOnetime.Error{code: :request_in_progress}} =
                 runtime_transaction(c, fn ->
                   Postgres.complete_external(
                     target(c),
                     grant.claim,
                     "test",
                     :crypto.hash(:sha256, "response"),
                     "response",
                     nil,
                     lock_timeout_ms: 300
                   )
                 end)

        assert scalar(
                 c.owner_repo,
                 "SELECT state='processing' AND effect_attempt=1 FROM #{rel(c, "ash_onetime_idempotency_claims")}"
               )

        assert scalar(
                 c.owner_repo,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
               ) == 0
      after
        release(holder)
      end

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_response_payloads")}"
             ) == 0
    end

    test "#{partitioning || "plain"}: B3 an outcome waits for the native grant transaction to commit",
         c do
      grant = Postgres.claim_committed(target(c), request!("B3"), lock_timeout_ms: 1000)

      {barrier, worker, handler} =
        statement_barrier(c, "FOR UPDATE OF claims", fn repo ->
          Postgres.claim_committed(%{target(c) | dynamic_repo: repo}, request!("B3"),
            lock_timeout_ms: 1000
          )
        end)

      worker_repo = connection!(c, :runtime, 1)
      backend = scalar(worker_repo, "SELECT pg_backend_pid()")

      outcome =
        Task.async(fn ->
          Postgres.record_outcome_committed(
            %{target(c) | dynamic_repo: worker_repo},
            grant.claim,
            :held,
            lock_timeout_ms: 2000
          )
        end)

      try do
        await_wait(c, backend)
      after
        release_statement(barrier, worker, handler)
      end

      assert %Result{status: :processing, transaction: :committed} = Task.await(outcome, 3000)

      assert scalar(
               c.runtime_repo,
               "SELECT effect_attempt FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             ) == 2

      assert scalar(
               c.runtime_repo,
               "SELECT attempt FROM #{rel(c, "ash_onetime_effect_outcomes")}"
             ) == 1
    end

    test "#{partitioning || "plain"}: P11 outcome visibility reads beside the native grant lock",
         c do
      grant = Postgres.claim_committed(target(c), request!("P11-L2"), lock_timeout_ms: 1000)
      assert {:ok, _} = record_outcome(c, grant.claim.id)

      {barrier, worker, handler} =
        statement_barrier(c, "FOR UPDATE OF claims", fn repo ->
          Postgres.claim_committed(%{target(c) | dynamic_repo: repo}, request!("P11-L2"),
            lock_timeout_ms: 1000
          )
        end)

      reader = connection!(c, :runtime, 1)
      backend = scalar(reader, "SELECT pg_backend_pid()")
      SQL.query!(reader, "SET lock_timeout='1s'", [])

      try do
        started = System.monotonic_time(:millisecond)

        assert scalar(reader, "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}") ==
                 1

        assert System.monotonic_time(:millisecond) - started < 100

        assert scalar(
                 c.owner_repo,
                 "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted",
                 [backend]
               ) == 0
      after
        release_statement(barrier, worker, handler)
      end
    end

    test "#{partitioning || "plain"}: B7 reap skips a local claim held by the caller statement",
         c do
      request = request!("B7-local", effect_local: true)

      assert {:ok, %Result{status: :admitted, claim: claim}} =
               runtime_transaction(c, fn -> Postgres.claim(target(c), request) end)

      age_claim(c, claim.id)

      {holder, _, %Result{status: :failure, reason: :request_in_progress}} =
        hold(c, :runtime, fn repo ->
          Postgres.lock_for_effect(%{target(c) | dynamic_repo: repo}, claim,
            lock_timeout_ms: 1000
          )
        end)

      try do
        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_reap_idempotency", "100,86400")

        assert scalar(
                 c.runtime_repo,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
               ) == 1
      after
        release(holder)
      end

      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_reap_idempotency", "100,86400")
    end

    test "#{partitioning || "plain"}: U1/B10 reserve waits for cleanup commit then creates a new generation",
         c do
      request = request!("U1-deleted")
      grant = Postgres.claim_committed(target(c), request, lock_timeout_ms: 1000)
      complete_claim(c, grant.claim.id)
      age_claim(c, grant.claim.id)

      {holder, _, _} =
        hold(c, :maintainer, fn repo ->
          assert %{rows: [[1]]} =
                   SQL.query!(
                     repo,
                     "SELECT #{routine(c, "ash_onetime_cleanup_idempotency")}(100)",
                     []
                   )
        end)

      waiter_repo = connection!(c, :runtime, 1)
      backend = scalar(waiter_repo, "SELECT pg_backend_pid()")

      waiter =
        Task.async(fn ->
          Postgres.claim_committed(
            %{target(c) | dynamic_repo: waiter_repo},
            request!("U1-deleted"),
            lock_timeout_ms: 2000
          )
        end)

      try do
        await_wait(c, backend)

        assert scalar(
                 c.owner_repo,
                 "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted AND locktype='transactionid'",
                 [backend]
               ) > 0
      after
        release(holder)
      end

      assert %Result{status: :admitted, claim: fresh} = Task.await(waiter, 3000)
      refute fresh.id == grant.claim.id
      assert fresh.effect_attempt == 1
    end

    test "#{partitioning || "plain"}: the payload lock-order cycle ends within the armed bounds",
         c do
      grant =
        Postgres.claim_committed(target(c), request!("lock-order-C2"), lock_timeout_ms: 1000)

      before_claim =
        scalar(
          c.runtime_repo,
          "SELECT to_jsonb(c) FROM #{rel(c, "ash_onetime_idempotency_claims")} c WHERE id=$1::uuid",
          [Ecto.UUID.dump!(grant.claim.id)]
        )

      parent = self()
      t1_repo = connection!(c, :runtime, 1)
      t2_repo = connection!(c, :runtime, 1)
      maintenance_repo = connection!(c, :owner, 1)
      t2_backend = scalar(t2_repo, "SELECT pg_backend_pid()")
      maintenance_backend = scalar(maintenance_repo, "SELECT pg_backend_pid()")

      t1 =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: t1_repo}, fn ->
            SQL.query!(t1_repo, "SET LOCAL lock_timeout='2s'", [])

            SQL.query!(
              t1_repo,
              "SELECT encoded_response FROM #{rel(c, "ash_onetime_response_payloads")} LIMIT 0",
              []
            )

            send(parent, {:payload_read_held, self()})

            receive do
              :read_c2 -> :ok
            after
              5000 -> flunk("first reader was not released")
            end

            started = System.monotonic_time(:millisecond)

            result =
              Postgres.load(%{target(c) | dynamic_repo: t1_repo}, grant.claim,
                lock_timeout_ms: 2000
              )

            send(parent, {:cycle_t1, result, System.monotonic_time(:millisecond) - started})
            result
          end)
        end)

      assert_receive {:payload_read_held, t1_pid}, 2000

      maintenance =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(maintenance_repo)

          try do
            Repo.transaction(fn ->
              SQL.query!(maintenance_repo, "SET LOCAL lock_timeout='2500ms'", [])
              started = System.monotonic_time(:millisecond)

              result =
                SQL.query(
                  maintenance_repo,
                  "LOCK TABLE #{rel(c, "ash_onetime_response_payloads")} IN ACCESS EXCLUSIVE MODE",
                  []
                )

              send(
                parent,
                {:cycle_maintenance, result, System.monotonic_time(:millisecond) - started}
              )

              result
            end)
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      await_wait(c, maintenance_backend)

      t2 =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: t2_repo}, fn ->
            started = System.monotonic_time(:millisecond)

            result =
              Postgres.load(%{target(c) | dynamic_repo: t2_repo}, grant.claim,
                lock_timeout_ms: 2000
              )

            send(parent, {:cycle_t2, result, System.monotonic_time(:millisecond) - started})
            result
          end)
        end)

      await_wait(c, t2_backend)

      assert scalar(c.owner_repo, "SELECT $2=ANY(pg_blocking_pids($1))", [
               t2_backend,
               maintenance_backend
             ])

      send(t1_pid, :read_c2)
      assert_receive {:cycle_t1, t1_result, t1_elapsed}, 3500
      assert_receive {:cycle_t2, t2_result, t2_elapsed}, 3500
      assert_receive {:cycle_maintenance, maintenance_result, maintenance_elapsed}, 3500
      assert %Result{status: :processing} = t1_result
      assert %Result{status: :processing} = t2_result
      assert {:ok, _} = maintenance_result
      assert t1_elapsed < 2500
      assert t2_elapsed < 2500
      assert maintenance_elapsed < 3000
      assert {:ok, %Result{status: :processing}} = Task.await(t1, 1000)
      assert {:ok, %Result{status: :processing}} = Task.await(t2, 1000)
      assert {:ok, {:ok, _}} = Task.await(maintenance, 1000)

      assert scalar(
               c.runtime_repo,
               "SELECT to_jsonb(c) FROM #{rel(c, "ash_onetime_idempotency_claims")} c WHERE id=$1::uuid",
               [Ecto.UUID.dump!(grant.claim.id)]
             ) == before_claim

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM pg_locks WHERE pid=ANY($1) AND NOT granted",
               [[t2_backend, maintenance_backend]]
             ) == 0
    end

    defp statement_barrier(c, needle, action) do
      handler = {__MODULE__, make_ref()}
      parent = self()
      prefix = Repo.config()[:telemetry_prefix]
      once = :atomics.new(1, [])

      :ok =
        :telemetry.attach(
          handler,
          prefix ++ [:query],
          fn _, _, metadata, _ ->
            if is_binary(metadata.query) and String.contains?(metadata.query, needle) and
                 String.contains?(metadata.query, c.schema) and
                 :atomics.compare_exchange(once, 1, 0, 1) == :ok do
              send(parent, {:statement_held, self()})

              receive do
                {:release_statement, ^handler} -> :ok
              after
                10_000 -> raise "statement barrier expired"
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      repo = connection!(c, :runtime, 1)
      task = Task.async(fn -> action.(repo) end)
      assert_receive {:statement_held, worker}, 5000
      {task, worker, handler}
    end

    defp release_statement(task, worker, handler) do
      :telemetry.detach(handler)
      send(worker, {:release_statement, handler})
      Task.await(task, 5000)
    end

    defp await_wait(c, backend, remaining \\ 100) do
      if scalar(c.owner_repo, "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted", [
           backend
         ]) == 0 do
        assert remaining > 0
        Process.sleep(5)
        await_wait(c, backend, remaining - 1)
      else
        :ok
      end
    end

    defp run_caller(c, grant, action) do
      assert %Result{status: :processing} =
               result = Postgres.lock_for_effect(target(c), grant.claim, lock_timeout_ms: 1000)

      if action == :complete,
        do:
          Postgres.complete_external(
            target(c),
            grant.claim,
            "test",
            :crypto.hash(:sha256, "response"),
            "response",
            nil,
            lock_timeout_ms: 1000
          ),
        else: result
    end

    defp hold(c, role, action) do
      repo = connection!(c, role, 1)
      parent = self()

      task =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(repo)

          try do
            Repo.transaction(fn ->
              SQL.query!(repo, "SET LOCAL lock_timeout='5s'", [])
              result = action.(repo)
              send(parent, {:held, self(), result})

              receive do
                :release -> :ok
                :rollback -> Repo.rollback(:rollback)
              after
                15_000 -> flunk("transaction barrier expired")
              end
            end)
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      assert_receive {:held, _, result}, 5000
      {task, repo, result}
    end

    defp release(task) do
      send(task.pid, :release)
      Task.await(task, 5000)
    end
  end
end
