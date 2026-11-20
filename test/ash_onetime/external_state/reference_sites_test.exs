for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.ReferenceSitesTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.{SchemaFixture, ShippedMigrations}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    for rule <- ~w(reference-always-delete reference-always-claim-update reference-always-outcome-guard reference-always-outcome-bound) do
      @rule rule
      @tag [{String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}]
      test "#{partitioning || "plain"}: #{@rule} authenticates the fresh native trigger graph", c do
        result = install(c)
        assert result == :ok
      end
    end

    for rule <- ~w(legacy-reference-always-delete legacy-reference-primary-key legacy-reference-claim-shape) do
      @rule rule
      @tag [{String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}]
      test "#{partitioning || "plain"}: #{@rule} authenticates a shipped native schema", c do
        options = if c[:hash_partitions], do: [hash_partitions: c.hash_partitions], else: []
        assert :ok = SchemaFixture.migrate!(c, ShippedMigrations.render("v0.6.0", :render, Repo, options), 10)
        assert :ok = SchemaFixture.migrate!(c, Generator.render_logical_partition_upgrade(Repo, []), 11)
        assert :ok = SchemaFixture.migrate!(c, Generator.render_operation_hold_upgrade(Repo, []), 12)
        result = try do
          SchemaFixture.migrate!(c, Generator.render_external_state_upgrade(Repo, []), 13)
        rescue
          error in Postgrex.Error -> {:error, error.postgres.pg_code, error.postgres.message}
        end
        assert result == :ok
      end
    end
  end
end
