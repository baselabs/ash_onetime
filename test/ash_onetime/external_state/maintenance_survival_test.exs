for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.MaintenanceSurvivalTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_maintenance_survival_mutation

    test "#{partitioning || "plain"}: reap finishes beside unresolved, held, absent and unknown claims",
         c do
      ids =
        for state <- [:unresolved, :held, :absent_proven, :unknown] do
          id = insert_claim(c, attempt: if(state == :unknown, do: 0, else: 1))
          age_claim(c, id)
          if state in [:held, :absent_proven], do: record_outcome(c, id, state)
          id
        end

      local = insert_claim(c, local: true)
      age_claim(c, local)
      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_reap_idempotency", "100,86400")

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=ANY($1::uuid[])",
               [Enum.map(ids, &Ecto.UUID.dump!/1)]
             ) == 4

      assert scalar(
               c.owner_repo,
               "SELECT (last_counts->>'kept_external')::integer FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE step='reap'"
             ) == 4

      assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_expire_responses", "100")
      assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")
      assert {:ok, _} = step(c, "ash_onetime_prune_payload_partitions", "100,1000")
      assert {:ok, _} = step(c, "ash_onetime_roll_payload_partitions", "2")

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=ANY($1::uuid[])",
               [Enum.map(ids, &Ecto.UUID.dump!/1)]
             ) == 4

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=ANY($1::uuid[])",
               [Enum.map(ids, &Ecto.UUID.dump!/1)]
             ) == 2
    end

    test "#{partitioning || "plain"}: the delete guard refuses an armed direct reap of an external claim",
         c do
      id = insert_claim(c)
      age_claim(c, id)
      previous = Repo.put_dynamic_repo(c.runtime_repo)

      try do
        assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
                 Repo.transaction(fn ->
                   SQL.query!(c.runtime_repo, "SET LOCAL ash_onetime.reap_before='infinity'", [])

                   case SQL.query(
                          c.runtime_repo,
                          "DELETE FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
                          [Ecto.UUID.dump!(id)]
                        ) do
                     {:error, error} -> Repo.rollback(error)
                     {:ok, result} -> result
                   end
                 end)
      after
        Repo.put_dynamic_repo(previous)
      end
    end

    test "#{partitioning || "plain"}: compound cleanup expires responses before retaining their claims",
         c do
      id =
        insert_claim(c)
        |> then(&complete_claim(c, &1))
        |> then(&age_claim(c, &1, retain: "transaction_timestamp()+interval '1 day'"))

      maintenance_target = %{target(c) | dynamic_repo: c.maintainer_repo}

      assert {:ok, %{responses_expired: 1, idempotency: 0, nonce: 0}} =
               Postgres.cleanup(maintenance_target, 100, 0)

      assert scalar(
               c.runtime_repo,
               "SELECT response_expired_at IS NOT NULL FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
               [Ecto.UUID.dump!(id)]
             )
    end
  end
end
