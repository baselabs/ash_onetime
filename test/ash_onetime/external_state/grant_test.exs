for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.GrantTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_grant_mutation

    test "#{partitioning || "plain"}: reservation commits external attempt one", c do
      request = request!("fresh")
      result = Postgres.claim_committed(target(c), request, lock_timeout_ms: 300)

      assert %Result{
               status: :admitted,
               transaction: :committed,
               claim: %{effect_local: false, effect_attempt: 1, effect_state: :unresolved}
             } = result

      assert [[false, 1]] =
               SQL.query!(
                 c.runtime_repo,
                 "SELECT effect_local,effect_attempt FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
                 [Ecto.UUID.dump!(result.claim.id)]
               ).rows
    end

    for prior <- [:unresolved, :held, :absent_proven, :unknown] do
      test "#{partitioning || "plain"}: regrant advances #{prior} before redispatch", c do
        prior = unquote(prior)

        id =
          insert_claim(c, key: "retry", attempt: unquote(if(prior == :unknown, do: 0, else: 1)))

        if unquote(prior in [:held, :absent_proven]), do: record_outcome(c, id, prior)
        result = Postgres.claim_committed(target(c), request!("retry"), lock_timeout_ms: 300)

        assert %{
                 status: :processing,
                 transaction: :committed,
                 previous_effect_state: ^prior,
                 claim: %{id: ^id, effect_local: false}
               } = result

        assert result.claim.effect_attempt == unquote(if(prior == :unknown, do: 1, else: 2))
        assert result.claim.effect_state == :unresolved
      end
    end
  end
end
