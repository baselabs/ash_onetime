for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.LockedStaleTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @tag :enforcement_classify_locked_stale_attempt_mutation
    test "#{partitioning || "plain"}: a stale locked attempt stays in progress", c do
      first = Postgres.claim_committed(target(c), request!("stale-lock"), lock_timeout_ms: 300)
      second = Postgres.claim_committed(target(c), request!("stale-lock"), lock_timeout_ms: 300)
      assert second.claim.effect_attempt > first.claim.effect_attempt
      {:ok, result} = runtime_transaction(c, fn -> Postgres.lock_for_effect(target(c), first.claim, lock_timeout_ms: 300) end)
      assert %Result{status: :failure, reason: :request_in_progress, admission_dispatch: :sent, transaction: :open} = result
      assert scalar(c.runtime_repo, "SELECT effect_attempt FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid", [Ecto.UUID.dump!(first.claim.id)]) == second.claim.effect_attempt
    end
  end
end
