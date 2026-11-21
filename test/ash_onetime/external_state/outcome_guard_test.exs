for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.OutcomeGuardTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_outcome_guard_mutation

    setup c do
      on_exit(fn ->
        SQL.query!(
          c.owner_repo,
          "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} NO FORCE ROW LEVEL SECURITY",
          []
        )

        SQL.query!(
          c.owner_repo,
          "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DISABLE ROW LEVEL SECURITY",
          []
        )

        SQL.query!(
          c.owner_repo,
          "REVOKE UPDATE, DELETE ON #{rel(c, "ash_onetime_effect_outcomes")} FROM #{q(c.runtime)}",
          []
        )
      end)

      :ok
    end

    test "#{partitioning || "plain"}: default privileges cannot make the outcome record mutable",
         c do
      id = insert_claim(c)
      assert {:ok, %{num_rows: 1}} = insert_outcome(c, id)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               SQL.query(
                 c.runtime_repo,
                 "UPDATE #{rel(c, "ash_onetime_effect_outcomes")} SET outcome='absent_proven' WHERE claim_id=$1::uuid",
                 [Ecto.UUID.dump!(id)]
               )

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               SQL.query(
                 c.runtime_repo,
                 "DELETE FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1::uuid",
                 [Ecto.UUID.dump!(id)]
               )
    end

    test "#{partitioning || "plain"}: outcome guard refuses update even after an owner grant",
         c do
      id = insert_claim(c)
      assert {:ok, _} = insert_outcome(c, id)

      SQL.query!(
        c.owner_repo,
        "GRANT UPDATE ON #{rel(c, "ash_onetime_effect_outcomes")} TO #{q(c.runtime)}",
        []
      )

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               SQL.query(
                 c.runtime_repo,
                 "UPDATE #{rel(c, "ash_onetime_effect_outcomes")} SET outcome='absent_proven' WHERE claim_id=$1::uuid",
                 [Ecto.UUID.dump!(id)]
               )

      SQL.query!(
        c.owner_repo,
        "REVOKE UPDATE ON #{rel(c, "ash_onetime_effect_outcomes")} FROM #{q(c.runtime)}",
        []
      )
    end

    test "#{partitioning || "plain"}: outcome guard sees a parent hidden from the runtime role",
         c do
      id = insert_claim(c)
      assert {:ok, _} = insert_outcome(c, id)

      SQL.query!(
        c.owner_repo,
        "GRANT DELETE ON #{rel(c, "ash_onetime_effect_outcomes")} TO #{q(c.runtime)}",
        []
      )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ENABLE ROW LEVEL SECURITY",
        []
      )

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               SQL.query(
                 c.runtime_repo,
                 "DELETE FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1::uuid",
                 [Ecto.UUID.dump!(id)]
               )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DISABLE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "REVOKE DELETE ON #{rel(c, "ash_onetime_effect_outcomes")} FROM #{q(c.runtime)}",
        []
      )
    end

    test "#{partitioning || "plain"}: outcome guard fails closed when FORCE hides the parent from its owner",
         c do
      id = insert_claim(c)
      assert {:ok, _} = insert_outcome(c, id)

      SQL.query!(
        c.owner_repo,
        "GRANT DELETE ON #{rel(c, "ash_onetime_effect_outcomes")} TO #{q(c.runtime)}",
        []
      )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ENABLE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} FORCE ROW LEVEL SECURITY",
        []
      )

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               SQL.query(
                 c.runtime_repo,
                 "DELETE FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1::uuid",
                 [Ecto.UUID.dump!(id)]
               )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} NO FORCE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DISABLE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "REVOKE DELETE ON #{rel(c, "ash_onetime_effect_outcomes")} FROM #{q(c.runtime)}",
        []
      )
    end

    test "#{partitioning || "plain"}: the insert bound refuses an ungranted attempt and admits late attempts",
         c do
      id = insert_claim(c)
      assert {:ok, _} = query(c, "effect_attempt=2", id)
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = insert_outcome(c, id, 3)
      assert {:ok, _} = insert_outcome(c, id, 1)
      assert {:ok, _} = insert_outcome(c, id, 2)
    end

    test "#{partitioning || "plain"}: a late outcome cannot outlive its missing parent", c do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23503"}}} =
               insert_outcome(c, Ecto.UUID.generate())
    end

    defp insert_outcome(c, id, attempt \\ 1) do
      columns = if unquote(partitioning), do: "operation_hash,logical_partition,", else: ""
      values = if unquote(partitioning), do: "sha256('operation'::bytea),'global',", else: ""

      SQL.query(
        c.runtime_repo,
        "INSERT INTO #{rel(c, "ash_onetime_effect_outcomes")} (#{columns}claim_id,attempt,outcome,recorded_at) VALUES (#{values}$1::uuid,$2,'held',transaction_timestamp())",
        [Ecto.UUID.dump!(id), attempt]
      )
    end
  end
end
