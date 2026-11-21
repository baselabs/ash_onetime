for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.AuthorityPredicatesTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :enforcement_table_authority_predicate_mutation

    test "#{partitioning || "plain"}: a table-only DELETE holder is refused", c do
      outcomes = rel(c, "ash_onetime_effect_outcomes")
      SQL.query!(c.owner_repo, "GRANT DELETE ON #{outcomes} TO #{q(c.maintainer)}", [])

      refute scalar(
               c.owner_repo,
               "SELECT has_any_column_privilege($1,$2,'UPDATE,REFERENCES')",
               [c.maintainer, outcomes]
             )

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  pg_code: "P0001",
                  message: "untrusted_dependency: effective relation privilege"
                }
              }} =
               step(c, "ash_onetime_cleanup_nonce", "1")
    end
  end
end
