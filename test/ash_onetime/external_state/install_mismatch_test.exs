for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.InstallMismatchTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    test "#{partitioning || "plain"}: missing external state refuses before a claim write", c do
      assert :ok = install(c)

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DROP COLUMN effect_attempt CASCADE",
        []
      )

      assert %Result{status: :failure, reason: :install_mismatch} =
               Postgres.claim_committed(target(c), request!("missing-state"),
                 lock_timeout_ms: 300
               )

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             ) == 0
    end
  end
end
