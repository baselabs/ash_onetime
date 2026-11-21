for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.ReviewAclTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_review_acl

    for root <- ~w(ash_onetime_idempotency_claims ash_onetime_nonce_claims ash_onetime_response_payloads),
        not is_nil(partitioning) or root == "ash_onetime_response_payloads" do
      @root root
      test "#{partitioning || "plain"}: ACL refuses every table and column grant on #{@root} children", c do
        children = SQL.query!(c.owner_repo, "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent=$1::text::regclass ORDER BY inhrelid", [rel(c, @root)]).rows
        for [child] <- children, privilege <- ["SELECT", "INSERT", "UPDATE", "DELETE", "SELECT(id)", "INSERT(id)", "UPDATE(id)"] do
          privilege = if @root == "ash_onetime_response_payloads", do: String.replace(privilege, "(id)", "(claim_id)"), else: privilege
          SQL.query!(c.owner_repo, "GRANT #{privilege} ON #{child} TO #{q(c.runtime)}", [])
          try do
            assert [[false]] = SQL.query!(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_acl")}()", []).rows
          after
            SQL.query!(c.owner_repo, "REVOKE #{privilege} ON #{child} FROM #{q(c.runtime)}", [])
          end
        end
      end
    end
  end

  defmodule Module.concat(AshOnetime.ExternalState.ReviewSchemaUsageTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag force_claim_rls: true
    @moduletag :external_state_review_schema_usage

    test "#{partitioning || "plain"}: the private routine schema grants no PUBLIC usage", c do
      refute scalar(c.owner_repo, "SELECT has_schema_privilege($1,$2,'USAGE')", [c.runtime, Postgres.routine_schema(c.schema)])
    end

    test "#{partitioning || "plain"}: bound RLS policies need helper EXECUTE without schema USAGE", c do
      schema = Postgres.routine_schema(c.schema)
      SQL.query!(c.owner_repo, "REVOKE USAGE ON SCHEMA #{q(schema)} FROM PUBLIC", [])
      try do
        id = insert_claim(c)
        assert {:ok, _} = record_outcome(c, id)
        refute scalar(c.owner_repo, "SELECT has_schema_privilege($1,$2,'USAGE')", [c.runtime, schema])
        assert scalar(c.owner_repo, "SELECT has_function_privilege($1,$2,'EXECUTE')", [c.runtime, routine(c, "ash_onetime_claim_visible") <> "(bytea,text,uuid)"])
        assert {:ok, %{rows: [[1]]}} = SQL.query(c.runtime_repo, "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}", [])
      after
        SQL.query!(c.owner_repo, "GRANT USAGE ON SCHEMA #{q(schema)} TO PUBLIC", [])
      end
    end
  end
end
