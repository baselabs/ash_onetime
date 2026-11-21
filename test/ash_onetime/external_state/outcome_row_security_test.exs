for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.OutcomeRowSecurityTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag force_claim_rls: true
    @moduletag :external_state_outcome_row_security_mutation

    test "#{partitioning || "plain"}: FORCE follows claims and permits the legitimate outcome writer",
         c do
      assert scalar(
               c.owner_repo,
               "SELECT bool_and(relrowsecurity AND relforcerowsecurity) FROM pg_class WHERE oid=$1::text::regclass OR oid IN (SELECT inhrelid FROM pg_inherits WHERE inhparent=$1::text::regclass)",
               [rel(c, "ash_onetime_effect_outcomes")]
             )

      grant =
        Postgres.claim_committed(target(c), request!("forced-outcome"), lock_timeout_ms: 300)

      assert %Result{status: :admitted} = grant

      assert %Result{status: :processing, transaction: :committed} =
               Postgres.record_outcome_committed(target(c), grant.claim, :held,
                 lock_timeout_ms: 300
               )
    end

    test "#{partitioning || "plain"}: cleanup cascades under FORCE through the definer guard",
         c do
      id = insert_claim(c) |> then(&complete_claim(c, &1)) |> then(&age_claim(c, &1))
      assert {:ok, _} = record_outcome(c, id)
      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
             ) == 0
    end
  end
end
