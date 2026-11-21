for partitioning <- [nil, 2, 4] do
  defmodule Module.concat(
              AshOnetime.ExternalState.ShapeGraphTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_shape_graph_mutation

    test "#{partitioning || "plain"}: trust reconstructs the complete FK graph on an untouched install",
         c do
      actual = scalar(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_capture")}()")

      reference =
        scalar(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_reference")}(false)")

      for root <- reference["package_roots"] do
        assert reference[root] == actual[root]

        if reference[root <> "_children"],
          do: assert(reference[root <> "_children"] == actual[root <> "_children"])
      end

      assert {:ok, _} = step(c, "ash_onetime_maintenance_status", "")
    end

    test "#{partitioning || "plain"}: trust refuses a missing FK, changed action, or additional FK",
         c do
      for mutation <- [:missing, :action, :extra] do
        previous = Repo.put_dynamic_repo(c.owner_repo)

        result =
          try do
            Repo.transaction(fn ->
              case mutation do
                :missing ->
                  SQL.query!(
                    c.owner_repo,
                    "ALTER TABLE #{rel(c, "ash_onetime_effect_outcomes")} DROP CONSTRAINT ash_onetime_effect_outcomes_claim_fkey",
                    []
                  )

                :action ->
                  SQL.query!(
                    c.owner_repo,
                    "ALTER TABLE #{rel(c, "ash_onetime_effect_outcomes")} DROP CONSTRAINT ash_onetime_effect_outcomes_claim_fkey",
                    []
                  )

                  columns =
                    if unquote(partitioning), do: "operation_hash, logical_partition, ", else: ""

                  SQL.query!(
                    c.owner_repo,
                    "ALTER TABLE #{rel(c, "ash_onetime_effect_outcomes")} ADD FOREIGN KEY (#{columns}claim_id) REFERENCES #{rel(c, "ash_onetime_idempotency_claims")}(#{columns}id) ON DELETE NO ACTION",
                    []
                  )

                :extra ->
                  columns =
                    if unquote(partitioning), do: "operation_hash, logical_partition, ", else: ""

                  SQL.query!(
                    c.owner_repo,
                    "ALTER TABLE #{rel(c, "ash_onetime_effect_outcomes")} ADD FOREIGN KEY (#{columns}claim_id) REFERENCES #{rel(c, "ash_onetime_idempotency_claims")}(#{columns}id) ON DELETE CASCADE",
                    []
                  )
              end

              SQL.query!(c.owner_repo, "SAVEPOINT verify_shape", [])

              result =
                SQL.query(
                  c.owner_repo,
                  "SELECT #{routine(c, "ash_onetime_maintenance_trust")}()",
                  []
                )

              assert {:error, %Postgrex.Error{postgres: %{message: "untrusted_dependency:" <> _}}} =
                       result

              Repo.rollback(:restore_catalog)
            end)
          after
            Repo.put_dynamic_repo(previous)
          end

        assert {:error, :restore_catalog} = result
      end
    end
  end
end
