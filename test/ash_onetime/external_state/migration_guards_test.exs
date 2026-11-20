for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.MigrationGuardsTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.{SchemaFixture, ShippedMigrations}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    for {rule, message, code} <- [
          {"logical-column-check", "logical_partition_check", "23514"},
          {"logical-downgrade-refusal",
           "cannot remove logical partitions while non-global claims exist", "23514"},
          {"logical-collision-required", "legacy ash_onetime collision constraint is missing",
           "23514"},
          {"operation-hold-check", "ash_onetime_idempotency_claims_hold_check", "23514"},
          {"operation-hold-rollback-held",
           "release operation holds before removing operation-hold support", "23514"},
          {"operation-hold-rollback-unresolved", "unresolved external claims prevent rollback",
           "23514"},
          {"external-hold-required",
           "operation_hold_required: apply operation-hold before external-state", "P0001"},
          {"maintenance-hold-required",
           "operation_hold_required: apply the 2.0 operation-hold migration first", "P0001"},
          {"maintenance-external-required",
           "untrusted_dependency: upgrade relation shape ash_onetime_idempotency_claims", "P0001"}
        ] do
      @rule rule
      @message Regex.compile!(Regex.escape(message))
      @code code
      @tag [
        {String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}
      ]
      test "#{partitioning || "plain"}: #{@rule} refuses at its owning migration guard", c do
        options = if c[:hash_partitions], do: [hash_partitions: c.hash_partitions], else: []
        hold = Generator.render_operation_hold_upgrade(Repo, [])
        logical = Generator.render_logical_partition_upgrade(Repo, [])
        external = Generator.render_external_state_upgrade(Repo, [])
        maintenance = Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer)

        action =
          if @rule == "operation-hold-rollback-unresolved" do
            assert :ok = install(c)
            assert :ok = SchemaFixture.migrate!(c, hold, 12)
            insert_claim(c)
            fn -> SchemaFixture.migrate!(c, hold, 12, :down) end
          else
            assert :ok =
                     SchemaFixture.migrate!(
                       c,
                       ShippedMigrations.render("v0.6.0", :render, Repo, options),
                       10
                     )

            if @rule == "logical-collision-required" do
              [[name]] =
                SQL.query!(
                  c.owner_repo,
                  "SELECT conname FROM pg_constraint WHERE conrelid=$1::text::regclass AND contype='u'",
                  [rel(c, "ash_onetime_idempotency_claims")]
                ).rows

              SQL.query!(
                c.owner_repo,
                "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DROP CONSTRAINT #{q(name)}",
                []
              )

              fn -> SchemaFixture.migrate!(c, logical, 11) end
            else
              assert :ok = SchemaFixture.migrate!(c, logical, 11)

              case @rule do
                "logical-column-check" ->
                  id = seed(c, "processing")

                  fn ->
                    SQL.query!(
                      c.owner_repo,
                      "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET logical_partition='' WHERE id=$1::uuid",
                      [Ecto.UUID.dump!(id)]
                    )
                  end

                "logical-downgrade-refusal" ->
                  id = seed(c, "processing")

                  SQL.query!(
                    c.owner_repo,
                    "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET logical_partition='separate' WHERE id=$1::uuid",
                    [Ecto.UUID.dump!(id)]
                  )

                  fn -> SchemaFixture.migrate!(c, logical, 11, :down) end

                "external-hold-required" ->
                  fn -> SchemaFixture.migrate!(c, external, 12) end

                "maintenance-hold-required" ->
                  fn -> SchemaFixture.migrate!(c, maintenance, 12) end

                rule
                when rule in [
                       "operation-hold-check",
                       "operation-hold-rollback-held",
                       "maintenance-external-required"
                     ] ->
                  assert :ok = SchemaFixture.migrate!(c, hold, 12)

                  case rule do
                    "operation-hold-check" ->
                      id = seed(c, "processing")

                      fn ->
                        SQL.query!(
                          c.owner_repo,
                          "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET hold_reference='held' WHERE id=$1::uuid",
                          [Ecto.UUID.dump!(id)]
                        )
                      end

                    "operation-hold-rollback-held" ->
                      id = seed(c, "complete")

                      SQL.query!(
                        c.owner_repo,
                        "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET hold_reference='held' WHERE id=$1::uuid",
                        [Ecto.UUID.dump!(id)]
                      )

                      fn -> SchemaFixture.migrate!(c, hold, 12, :down) end

                    "maintenance-external-required" ->
                      fn -> SchemaFixture.migrate!(c, maintenance, 13) end
                  end
              end
            end
          end

        error = assert_raise Postgrex.Error, @message, action
        assert error.postgres.pg_code == @code
      end
    end

    @tag :enforcement_upgrade_enable_claim_delete_mutation
    test "#{partitioning || "plain"}: the hold upgrade activates the claim guard in every replication mode",
         c do
      options = if c[:hash_partitions], do: [hash_partitions: c.hash_partitions], else: []

      assert :ok =
               SchemaFixture.migrate!(
                 c,
                 ShippedMigrations.render("v0.6.0", :render, Repo, options),
                 10
               )

      assert :ok =
               SchemaFixture.migrate!(c, Generator.render_logical_partition_upgrade(Repo, []), 11)

      assert :ok =
               SchemaFixture.migrate!(c, Generator.render_operation_hold_upgrade(Repo, []), 12)

      assert [["A"]] =
               SQL.query!(
                 c.owner_repo,
                 "SELECT tgenabled::text FROM pg_trigger WHERE tgrelid=$1::text::regclass AND tgname='ash_onetime_idempotency_delete_guard'",
                 [rel(c, "ash_onetime_idempotency_claims")]
               ).rows
    end

    defp seed(c, state) do
      id = Ecto.UUID.generate()

      response =
        if state == "complete",
          do: "CURRENT_DATE,'test',sha256('response'::bytea)",
          else: "NULL,NULL,NULL"

      SQL.query!(
        c.owner_repo,
        "INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,retain_until,inserted_at,response_partition,response_codec,response_digest) VALUES ($1::uuid,'global',sha256('operation'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('request'::bytea),$2,transaction_timestamp(),transaction_timestamp()+interval '1 day',transaction_timestamp(),#{response})",
        [Ecto.UUID.dump!(id), state]
      )

      id
    end
  end
end
