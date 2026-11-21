for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.MaintenanceRowLocksTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for {kind, name, arguments} <- [
          {:complete, "ash_onetime_cleanup_idempotency", "1"},
          {:nonce, "ash_onetime_cleanup_nonce", "1"},
          {:processing, "ash_onetime_reap_idempotency", "1,86400"}
        ] do
      @kind kind
      @name name
      @arguments arguments
      @tag [{String.to_atom("enforcement_#{kind}_candidate_lock_mutation"), true}]
      test "#{partitioning || "plain"}: #{@kind} candidates skip a held KEY SHARE without waiting for DELETE",
           c do
        {table, id} =
          if @kind == :nonce do
            id = Ecto.UUID.generate()

            SQL.query!(
              c.runtime_repo,
              "INSERT INTO #{rel(c, "ash_onetime_nonce_claims")} (id,logical_partition,operation_hash,scope_hash,key_hash,issued_at,admitted_at,retain_until,inserted_at,verifier_id) VALUES ($1::uuid,'global',sha256('operation'::bytea),sha256('scope'::bytea),sha256('nonce'::bytea),transaction_timestamp()-interval '2 days',transaction_timestamp()-interval '2 days',transaction_timestamp()-interval '1 day',transaction_timestamp()-interval '2 days','test')",
              [Ecto.UUID.dump!(id)]
            )

            {"ash_onetime_nonce_claims", id}
          else
            id = insert_claim(c, local: true)
            if @kind == :complete, do: complete_claim(c, id)
            age_claim(c, id)
            {"ash_onetime_idempotency_claims", id}
          end

        holder = connection!(c, :owner, 1)
        waiter = connection!(c, :maintainer, 1)
        previous = Repo.put_dynamic_repo(holder)

        try do
          Repo.transaction(fn ->
            SQL.query!(
              holder,
              "SELECT id FROM #{rel(c, table)} WHERE id=$1::uuid FOR KEY SHARE",
              [Ecto.UUID.dump!(id)]
            )

            SQL.query!(waiter, "SET statement_timeout='3s'", [])

            assert {:ok, %{rows: [[0]]}} =
                     SQL.query(waiter, "SELECT #{routine(c, @name)}(#{@arguments})", [])
          end)
        after
          Repo.put_dynamic_repo(previous)
        end

        assert scalar(c.runtime_repo, "SELECT count(*) FROM #{rel(c, table)} WHERE id=$1::uuid", [
                 Ecto.UUID.dump!(id)
               ]) == 1
      end
    end
  end
end
