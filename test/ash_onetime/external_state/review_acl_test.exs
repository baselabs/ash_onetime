for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.ReviewAclTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_review_acl

    @tag :external_state_review_journal_acl
    test "#{partitioning || "plain"}: reset ACL keeps the rollback journal owner-only in every mode",
         c do
      journal = rel(c, "ash_onetime_external_state_restore")

      SQL.query!(
        c.owner_repo,
        "GRANT SELECT,INSERT,UPDATE,DELETE ON #{journal} TO #{q(c.runtime)}",
        []
      )

      SQL.query!(
        c.owner_repo,
        "GRANT SELECT(routine_identity),UPDATE(definition) ON #{journal} TO #{q(c.runtime)}",
        []
      )

      assert {:ok, _} =
               SQL.query(
                 c.owner_repo,
                 "SELECT #{routine(c, "ash_onetime_maintenance_reset_acl")}($1::text::regclass::oid,false)",
                 [journal]
               )

      refute scalar(
               c.owner_repo,
               "SELECT has_table_privilege($1,$2,'SELECT,INSERT,UPDATE,DELETE') OR has_any_column_privilege($1,$2,'SELECT,INSERT,UPDATE')",
               [c.runtime, journal]
             )
    end

    @tag :external_state_review_journal_acl
    test "#{partitioning || "plain"}: ACL audits table and column grants on the rollback journal",
         c do
      journal = rel(c, "ash_onetime_external_state_restore")

      for privilege <- ["SELECT", "UPDATE(definition)"] do
        SQL.query!(c.owner_repo, "GRANT #{privilege} ON #{journal} TO #{q(c.runtime)}", [])

        try do
          assert [[false]] =
                   SQL.query!(
                     c.owner_repo,
                     "SELECT #{routine(c, "ash_onetime_maintenance_acl")}()",
                     []
                   ).rows
        after
          SQL.query!(c.owner_repo, "REVOKE #{privilege} ON #{journal} FROM #{q(c.runtime)}", [])
        end
      end
    end

    @tag :external_state_review_journal_trust
    @tag :enforcement_trust_missing_root_refusal_mutation
    test "#{partitioning || "plain"}: trust refuses a missing rollback journal", c do
      journal = rel(c, "ash_onetime_external_state_restore")
      SQL.query!(c.owner_repo, "ALTER TABLE #{journal} RENAME TO displaced_restore", [])

      try do
        assert {:error,
                %Postgrex.Error{
                  postgres: %{
                    pg_code: "P0001",
                    message: "untrusted_dependency: missing package root"
                  }
                }} =
                 SQL.query(
                   c.owner_repo,
                   "SELECT #{routine(c, "ash_onetime_maintenance_trust")}()",
                   []
                 )
      after
        SQL.query!(
          c.owner_repo,
          "ALTER TABLE #{rel(c, "displaced_restore")} RENAME TO ash_onetime_external_state_restore",
          []
        )
      end
    end

    for root <-
          ~w(ash_onetime_idempotency_claims ash_onetime_nonce_claims ash_onetime_response_payloads),
        not is_nil(partitioning) or root == "ash_onetime_response_payloads" do
      @root root
      test "#{partitioning || "plain"}: ACL refuses every table and column grant on #{@root} children",
           c do
        children =
          SQL.query!(
            c.owner_repo,
            "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent=$1::text::regclass ORDER BY inhrelid",
            [rel(c, @root)]
          ).rows

        for [child] <- children,
            privilege <- [
              "SELECT",
              "INSERT",
              "UPDATE",
              "DELETE",
              "SELECT(id)",
              "INSERT(id)",
              "UPDATE(id)"
            ] do
          privilege =
            if @root == "ash_onetime_response_payloads",
              do: String.replace(privilege, "(id)", "(claim_id)"),
              else: privilege

          SQL.query!(c.owner_repo, "GRANT #{privilege} ON #{child} TO #{q(c.runtime)}", [])

          try do
            assert [[false]] =
                     SQL.query!(
                       c.owner_repo,
                       "SELECT #{routine(c, "ash_onetime_maintenance_acl")}()",
                       []
                     ).rows
          after
            SQL.query!(c.owner_repo, "REVOKE #{privilege} ON #{child} FROM #{q(c.runtime)}", [])
          end
        end
      end
    end
  end

  defmodule Module.concat(
              AshOnetime.ExternalState.ReviewSchemaUsageTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag force_claim_rls: true
    @moduletag :external_state_review_schema_usage

    test "#{partitioning || "plain"}: the private routine schema grants no PUBLIC usage", c do
      refute scalar(c.owner_repo, "SELECT has_schema_privilege($1,$2,'USAGE')", [
               c.runtime,
               Postgres.routine_schema(c.schema)
             ])
    end

    test "#{partitioning || "plain"}: bound RLS policies need helper EXECUTE without schema USAGE",
         c do
      schema = Postgres.routine_schema(c.schema)
      SQL.query!(c.owner_repo, "REVOKE USAGE ON SCHEMA #{q(schema)} FROM PUBLIC", [])

      try do
        id = insert_claim(c)
        assert {:ok, _} = record_outcome(c, id)

        refute scalar(c.owner_repo, "SELECT has_schema_privilege($1,$2,'USAGE')", [
                 c.runtime,
                 schema
               ])

        assert scalar(c.owner_repo, "SELECT has_function_privilege($1,$2,'EXECUTE')", [
                 c.runtime,
                 routine(c, "ash_onetime_claim_visible") <> "(bytea,text,uuid)"
               ])

        assert {:ok, %{rows: [[1]]}} =
                 SQL.query(
                   c.runtime_repo,
                   "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}",
                   []
                 )
      after
        SQL.query!(c.owner_repo, "GRANT USAGE ON SCHEMA #{q(schema)} TO PUBLIC", [])
      end
    end
  end
end
