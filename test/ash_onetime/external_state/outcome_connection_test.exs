for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.OutcomeConnectionTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_outcome_connection_mutation

    test "#{partitioning || "plain"}: outcome commits on its own connection after the caller query fails",
         c do
      grant = Postgres.claim_committed(target(c), request!("failed-caller"), lock_timeout_ms: 300)

      assert {:error, :caller_failed} =
               runtime_transaction(c, fn ->
                 assert %Result{status: :processing} =
                          Postgres.lock_for_effect(target(c), grant.claim, lock_timeout_ms: 300)

                 assert {:error, %Postgrex.Error{postgres: %{pg_code: "22012"}}} =
                          SQL.query(c.runtime_repo, "SELECT 1/0", [])

                 started = System.monotonic_time(:millisecond)

                 assert %Result{status: :processing, transaction: :committed} =
                          Postgres.record_outcome_committed(
                            target(c),
                            grant.claim,
                            :held,
                            lock_timeout_ms: 300
                          )

                 assert System.monotonic_time(:millisecond) - started < 300
                 Repo.rollback(:caller_failed)
               end)

      assert [[1, "held"]] =
               SQL.query!(
                 c.runtime_repo,
                 "SELECT attempt,outcome FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1::uuid",
                 [Ecto.UUID.dump!(grant.claim.id)]
               ).rows
    end

    test "#{partitioning || "plain"}: B4 the independent outcome worker obeys its lock bound",
         c do
      grant =
        Postgres.claim_committed(target(c), request!("bounded-outcome"), lock_timeout_ms: 300)

      parent = self()

      blocker =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(c.owner_repo)

          try do
            Repo.transaction(fn ->
              SQL.query!(
                c.owner_repo,
                "LOCK TABLE #{rel(c, "ash_onetime_effect_outcomes")} IN ACCESS EXCLUSIVE MODE",
                []
              )

              send(parent, {:outcome_locked, self()})

              receive do
                :release -> :ok
              end
            end)
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      assert_receive {:outcome_locked, blocker_pid}, 2000

      worker =
        Task.async(fn ->
          Postgres.record_outcome_committed(target(c), grant.claim, :held, lock_timeout_ms: 300)
        end)

      result =
        try do
          Task.yield(worker, 800)
        after
          send(blocker_pid, :release)
          Task.await(blocker, 5000)
        end

      if is_nil(result), do: Task.await(worker, 5000)
      assert {:ok, %Result{status: :failure, reason: :outcome_unrecorded}} = result
    end
  end
end
