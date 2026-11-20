for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.CatalogEdgeInstallTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    for rule <- ~w(catalog-edge-numeric-class catalog-edge-named-class) do
      @rule rule
      @tag [
        {String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}
      ]
      test "#{partitioning || "plain"}: #{@rule} installs native typed catalog traversal", c do
        result =
          try do
            case install(c) do
              {:error, %Postgrex.Error{postgres: %{pg_code: code, message: message}}} ->
                {:error, code, message}

              result ->
                result
            end
          rescue
            error in Postgrex.Error -> {:error, error.postgres.pg_code, error.postgres.message}
          end

        assert result == :ok

        # Use an installed package root as the edge value. PostgreSQL itself
        # rejects the null path the parser mutations would supply to jsonb_set.
        refusal =
          SQL.query(
            c.owner_repo,
            "SELECT pg_catalog.jsonb_set('{}'::jsonb, ARRAY[NULL::text], pg_catalog.to_jsonb($1::text::regclass::oid))",
            [rel(c, "ash_onetime_idempotency_claims")]
          )

        assert {:error,
                %Postgrex.Error{
                  postgres: %{pg_code: "22004", message: "path element at position 1 is null"}
                }} = refusal
      end
    end
  end
end
