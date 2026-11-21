for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.DeleteGuardTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_delete_guard_mutation

    test "#{partitioning || "plain"}: a runtime DELETE of a retained complete claim gets the guard's refusal",
         c do
      id = insert_claim(c) |> then(&complete_claim(c, &1))

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               SQL.query(
                 c.runtime_repo,
                 "DELETE FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
                 [Ecto.UUID.dump!(id)]
               )
    end

    test "#{partitioning || "plain"}: a runtime DELETE of an unexpired nonce gets the guard's refusal",
         c do
      id = Ecto.UUID.generate()

      SQL.query!(
        c.runtime_repo,
        """
        INSERT INTO #{rel(c, "ash_onetime_nonce_claims")}
          (id,operation_hash,scope_hash,key_hash,issued_at,verifier_id,admitted_at,retain_until,inserted_at)
        VALUES ($1::uuid,sha256('nonce-operation'::bytea),sha256('scope'::bytea),sha256('nonce-key'::bytea),
          transaction_timestamp(),'test',transaction_timestamp(),transaction_timestamp()+interval '1 day',transaction_timestamp())
        """,
        [Ecto.UUID.dump!(id)]
      )

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               SQL.query(
                 c.runtime_repo,
                 "DELETE FROM #{rel(c, "ash_onetime_nonce_claims")} WHERE id=$1::uuid",
                 [Ecto.UUID.dump!(id)]
               )
    end
  end
end
