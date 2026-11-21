for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.AttemptRaceTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_attempt_race_mutation

    test "#{partitioning || "plain"}: stale classification refuses before a peer can run", c do
      a = Postgres.claim_committed(target(c), request!("race"), lock_timeout_ms: 300)
      b = Postgres.claim_committed(target(c), request!("race"), lock_timeout_ms: 300)
      assert b.claim.effect_attempt == a.claim.effect_attempt + 1

      result =
        runtime_transaction(c, fn ->
          Postgres.lock_for_effect(target(c), a.claim, lock_timeout_ms: 300)
        end)

      assert {:ok, %Result{status: :failure, reason: :request_in_progress}} = result
    end

    test "#{partitioning || "plain"}: a late caller replays a completed claim", c do
      grant = Postgres.claim_committed(target(c), request!("late-caller"), lock_timeout_ms: 300)
      complete_claim(c, grant.claim.id)

      assert {:ok, %Result{status: :complete, payload: "response"}} =
               runtime_transaction(c, fn ->
                 Postgres.lock_for_effect(target(c), grant.claim, lock_timeout_ms: 300)
               end)
    end

    test "#{partitioning || "plain"}: stale completion rolls its own payload back", c do
      a = Postgres.claim_committed(target(c), request!("completion"), lock_timeout_ms: 300)
      b = Postgres.claim_committed(target(c), request!("completion"), lock_timeout_ms: 300)

      assert {:error, %Result{reason: :store_invariant}} =
               runtime_transaction(c, fn ->
                 Postgres.complete_external(
                   target(c),
                   a.claim,
                   "test",
                   :crypto.hash(:sha256, "response"),
                   "response",
                   nil,
                   lock_timeout_ms: 300
                 )
               end)

      assert [["processing", b.claim.effect_attempt]] ==
               SQL.query!(
                 c.runtime_repo,
                 "SELECT state,effect_attempt FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
                 [Ecto.UUID.dump!(a.claim.id)]
               ).rows

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1::uuid",
               [Ecto.UUID.dump!(a.claim.id)]
             ) == 0
    end

    @tag :external_state_outcome_attempt_mutation
    test "#{partitioning || "plain"}: an outcome records the granted attempt and recovery classifies it held",
         c do
      Postgres.claim_committed(target(c), request!("outcome-attempt"), lock_timeout_ms: 300)

      grant =
        Postgres.claim_committed(target(c), request!("outcome-attempt"), lock_timeout_ms: 300)

      assert grant.claim.effect_attempt >= 2

      assert %Result{status: :processing, transaction: :committed} =
               Postgres.record_outcome_committed(target(c), grant.claim, :held,
                 lock_timeout_ms: 300
               )

      stored_attempt =
        scalar(
          c.runtime_repo,
          "SELECT attempt FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1::uuid",
          [Ecto.UUID.dump!(grant.claim.id)]
        )

      assert {:ok, %Result{claim: %{effect_state: state}}} =
               runtime_transaction(c, fn ->
                 Postgres.load(target(c), grant.claim, lock_timeout_ms: 300)
               end)

      assert {stored_attempt, state} == {grant.claim.effect_attempt, :held}
    end
  end
end
