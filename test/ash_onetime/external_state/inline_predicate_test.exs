for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.InlinePredicateTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_inline_eligible_mutation

    test "#{partitioning || "plain"}: early expiry uses its inline deadline predicate", c do
      id = insert_claim(c) |> then(&complete_claim(c, &1))

      SQL.query!(
        c.runtime_repo,
        "DELETE FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1::uuid",
        [Ecto.UUID.dump!(id)]
      )

      previous = Repo.put_dynamic_repo(c.owner_repo)

      try do
        Repo.transaction(fn ->
          SQL.query!(c.owner_repo, "SET LOCAL ash_onetime.maintenance='on'", [])

          SQL.query!(
            c.owner_repo,
            "REVOKE EXECUTE ON FUNCTION #{routine(c, "ash_onetime_cleanup_eligible")}(timestamptz) FROM #{q(c.owner)}",
            []
          )

          assert {:error,
                  %Postgrex.Error{
                    postgres: %{
                      pg_code: "23514",
                      message: "idempotency response is inside its retention horizon"
                    }
                  }} =
                   SQL.query(
                     c.owner_repo,
                     "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET response_partition=NULL,response_codec=NULL,response_digest=NULL,response_expired_at=transaction_timestamp() WHERE id=$1::uuid",
                     [Ecto.UUID.dump!(id)]
                   )

          Repo.rollback(:inline_checked)
        end)
      after
        Repo.put_dynamic_repo(previous)
      end
    end
  end
end
