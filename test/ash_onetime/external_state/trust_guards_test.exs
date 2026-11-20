for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.TrustGuardsTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for {rule, message} <- [
      {"trust-relation-shape-refusal", "untrusted_dependency: relation shape ash_onetime_idempotency_claims"},
      {"trust-policy-refusal", "maintenance_blinded:"},
      {"trust-authority-refusal", "untrusted_dependency: effective relation privilege"},
      {"trust-helper-public-refusal", "untrusted_dependency: ash_onetime_claim_visible missing PUBLIC EXECUTE"},
      {"trust-package-acl-refusal", "untrusted_dependency: package ACL"},
      {"trust-partition-date-refusal", "untrusted_dependency: partition date range"}
    ] do
      @rule rule
      @message message
      @tag [{String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}]
      test "#{partitioning || "plain"}: #{@rule} reports its owning trust refusal", c do
        case @rule do
          "trust-relation-shape-refusal" ->
            SQL.query!(c.owner_repo, "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ADD COLUMN consumer_column text", [])
            on_exit(fn -> SQL.query!(c.owner_repo, "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DROP COLUMN consumer_column", []) end)

          "trust-policy-refusal" ->
            SQL.query!(c.owner_repo, "CREATE POLICY consumer_policy ON #{rel(c, "ash_onetime_response_payloads")} FOR ALL TO #{q(c.owner)} USING (true) WITH CHECK (true)", [])
            on_exit(fn -> SQL.query!(c.owner_repo, "DROP POLICY consumer_policy ON #{rel(c, "ash_onetime_response_payloads")}", []) end)

          "trust-authority-refusal" ->
            [[child]] = SQL.query!(c.owner_repo, "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent=$1::text::regclass ORDER BY inhrelid LIMIT 1", [rel(c, "ash_onetime_response_payloads")]).rows
            SQL.query!(c.owner_repo, "GRANT DELETE ON #{child} TO #{q(c.maintainer)}", [])
            on_exit(fn -> SQL.query!(c.owner_repo, "REVOKE DELETE ON #{child} FROM #{q(c.maintainer)}", []) end)

          "trust-helper-public-refusal" ->
            SQL.query!(c.owner_repo, "REVOKE EXECUTE ON FUNCTION #{routine(c, "ash_onetime_claim_visible")}(bytea,text,uuid) FROM PUBLIC", [])
            on_exit(fn -> SQL.query!(c.owner_repo, "GRANT EXECUTE ON FUNCTION #{routine(c, "ash_onetime_claim_visible")}(bytea,text,uuid) TO PUBLIC", []) end)

          "trust-package-acl-refusal" ->
            SQL.query!(c.owner_repo, "GRANT EXECUTE ON FUNCTION #{routine(c, "ash_onetime_cleanup_eligible")}(timestamptz) TO #{q(c.runtime)}", [])
            on_exit(fn -> SQL.query!(c.owner_repo, "REVOKE EXECUTE ON FUNCTION #{routine(c, "ash_onetime_cleanup_eligible")}(timestamptz) FROM #{q(c.runtime)}", []) end)

          "trust-partition-date-refusal" ->
            SQL.query!(c.owner_repo, "CREATE TABLE #{rel(c, "past_infinite")} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('-infinity') TO ('2000-01-01')", [])
            on_exit(fn -> SQL.query!(c.owner_repo, "DROP TABLE #{rel(c, "past_infinite")}", []) end)
            SQL.query!(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_copy_policy")}($1::text::regclass::oid)", [rel(c, "past_infinite")])
            SQL.query!(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_reset_acl")}($1::text::regclass::oid,false)", [rel(c, "past_infinite")])
        end

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} = SQL.query(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_trust")}()", [])
        assert String.starts_with?(message, @message)
        if @rule == "trust-policy-refusal", do: assert(String.contains?(message, "consumer_policy"))
      end
    end
    if partitioning do
      @tag :enforcement_trust_relation_shape_refusal_mutation
      test "#{partitioning}: trust rejects a changed hash bound through the native child shape", c do
        parent = rel(c, "ash_onetime_nonce_claims")
        previous = Repo.put_dynamic_repo(c.owner_repo)
        try do
          assert {:error, :catalog_restored} = Repo.transaction(fn ->
            for [child] <- SQL.query!(c.owner_repo, "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent=$1::text::regclass", [parent]).rows do
              SQL.query!(c.owner_repo, "ALTER TABLE #{parent} DETACH PARTITION #{child}", [])
            end
            for remainder <- 0..2 do
              child = rel(c, "changed_nonce_#{remainder}")
              SQL.query!(c.owner_repo, "CREATE TABLE #{child} PARTITION OF #{parent} FOR VALUES WITH (MODULUS 3,REMAINDER #{remainder})", [])
              SQL.query!(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_copy_policy")}($1::text::regclass::oid)", [child])
              SQL.query!(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_reset_acl")}($1::text::regclass::oid,true)", [child])
            end
            result = SQL.query(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_trust")}()", [])
            assert {:error, %Postgrex.Error{postgres: %{message: "untrusted_dependency: relation shape changed_nonce_" <> _}}} = result
            Repo.rollback(:catalog_restored)
          end)
        after
          Repo.put_dynamic_repo(previous)
        end
      end
    end
  end
end
