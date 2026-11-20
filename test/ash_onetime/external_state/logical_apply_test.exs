for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.LogicalApplyTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_logical_apply_mutation

    test "#{partitioning || "plain"}: replica runtime cannot insert an ungranted claim", c do
      result =
        replica(c, c.runtime_repo, fn ->
          SQL.query(
            c.runtime_repo,
            "INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (id,operation_hash,scope_hash,key_hash,fingerprint,state,effect_local,effect_attempt,admitted_at,inserted_at,retain_until,response_retain_until) VALUES (gen_random_uuid(),sha256('operation'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('request'::bytea),'processing',false,2,transaction_timestamp(),transaction_timestamp(),transaction_timestamp()+interval '1 day',transaction_timestamp()+interval '1 day')",
            []
          )
        end)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = result
    end

    test "#{partitioning || "plain"}: replica runtime cannot delete a retained outcome", c do
      id = insert_claim(c)
      assert {:ok, _} = record_outcome(c, id)

      SQL.query!(
        c.owner_repo,
        "GRANT DELETE ON #{rel(c, "ash_onetime_effect_outcomes")} TO #{q(c.runtime)}",
        []
      )

      try do
        result =
          replica(c, c.runtime_repo, fn ->
            SQL.query(c.runtime_repo, "DELETE FROM #{rel(c, "ash_onetime_effect_outcomes")}", [])
          end)

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = result
      after
        SQL.query!(
          c.owner_repo,
          "REVOKE DELETE ON #{rel(c, "ash_onetime_effect_outcomes")} FROM #{q(c.runtime)}",
          []
        )
      end
    end

    test "#{partitioning || "plain"}: replica runtime cannot insert an ungranted outcome", c do
      id = insert_claim(c)
      result = replica(c, c.runtime_repo, fn -> record_outcome(c, id, :held, 2) end)
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = result
    end

    test "#{partitioning || "plain"}: trusted replica restore derives a legacy response deadline",
         c do
      result =
        replica(c, c.owner_repo, fn ->
          SQL.query(
            c.owner_repo,
            "INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (id,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,inserted_at,retain_until) VALUES (gen_random_uuid(),sha256('operation'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('request'::bytea),'processing',transaction_timestamp()-interval '1 day',transaction_timestamp()-interval '1 day',transaction_timestamp()+interval '1 day') RETURNING response_retain_until=retain_until",
            []
          )
        end)

      assert {:ok, %{rows: [[true]]}} = result
    end

    defp replica(c, repo, action) do
      SQL.query!(Repo, "GRANT SET ON PARAMETER session_replication_role TO #{q(c.runtime)}", [])
      previous = Repo.put_dynamic_repo(repo)

      try do
        case Repo.transaction(fn ->
               SQL.query!(repo, "SET LOCAL session_replication_role=replica", [])

               case action.() do
                 {:error, error} -> Repo.rollback(error)
                 result -> result
               end
             end) do
          {:ok, result} -> result
          {:error, error} -> {:error, error}
        end
      after
        Repo.put_dynamic_repo(previous)

        SQL.query!(
          Repo,
          "REVOKE SET ON PARAMETER session_replication_role FROM #{q(c.runtime)}",
          []
        )
      end
    end
  end
end
