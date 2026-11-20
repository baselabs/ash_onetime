for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.AuthorityPredicatesTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :enforcement_table_authority_predicate_mutation

    test "#{partitioning || "plain"}: a table-only DELETE holder is refused", c do
      [[child]] = SQL.query!(c.owner_repo, "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent=$1::text::regclass ORDER BY inhrelid LIMIT 1", [rel(c, "ash_onetime_response_payloads")]).rows
      SQL.query!(c.owner_repo, "GRANT DELETE ON #{child} TO #{q(c.maintainer)}", [])

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: "untrusted_dependency: effective relation privilege"}}} =
               step(c, "ash_onetime_cleanup_nonce", "1")
    end
  end
end
