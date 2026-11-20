for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.InstallMismatchTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    @tag :enforcement_maintenance_upgrade_validation_mutation
    test "#{partitioning || "plain"}: maintenance upgrade authenticates the current relation shape", c do
      assert :ok = install(c)
      SQL.query!(c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_response_payloads")} ADD CONSTRAINT consumer_check CHECK (octet_length(encoded_response)>0)", [])
      error = assert_raise Postgrex.Error, fn ->
        AshOnetime.Test.SchemaFixture.migrate!(c,
          Mix.Tasks.AshOnetime.Gen.Migrations.render_maintenance_upgrade(Repo,
            maintenance_role: c.maintainer), 20_261_116_000_002)
      end
      assert error.postgres.pg_code == "P0001"
      assert error.postgres.message == "untrusted_dependency: upgrade relation shape ash_onetime_response_payloads"
    end

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
