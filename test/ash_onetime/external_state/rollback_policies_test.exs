for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.RollbackPoliciesTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.{SchemaFixture, ShippedMigrations}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    for {rule, attribute} <- [{"rollback-policy-permissive", "polpermissive::text"}, {"rollback-policy-check", "pg_get_expr(polwithcheck,polrelid)"}] do
      @rule rule
      @attribute attribute
      @tag [{String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}]
      test "#{partitioning || "plain"}: #{@rule} restores policies after mixed-owner function recreation", c do
        options = if c[:hash_partitions], do: [hash_partitions: c.hash_partitions], else: []
        assert :ok = SchemaFixture.migrate!(c, ShippedMigrations.render("v0.6.0", :render, Repo, options), 10)
        assert :ok = SchemaFixture.migrate!(c, Generator.render_logical_partition_upgrade(Repo, []), 11)
        assert :ok = SchemaFixture.migrate!(c, Generator.render_operation_hold_upgrade(Repo, []), 12)
        assert :ok = SchemaFixture.migrate!(c, Generator.render_external_state_upgrade(Repo, []), 13)

        SQL.query!(Repo, "GRANT USAGE,CREATE ON SCHEMA #{q(c.schema)} TO #{q(c.migrator)}", [])
        for [identity] <- SQL.query!(Repo, "SELECT p.oid::regprocedure::text FROM pg_proc p WHERE p.pronamespace=$1::text::regnamespace", [c.schema]).rows do
          SQL.query!(Repo, "ALTER FUNCTION #{identity} OWNER TO #{q(c.migrator)}", [])
        end
        migrator = connection!(c, :owner, 2, after_connect: fn connection -> Postgrex.query!(connection, "SET jit=off", []) end)
        migration_context = %{c | owner_repo: migrator}
        source = Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer)
        query = "SELECT c.relname,p.polname,#{@attribute} FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid WHERE c.relnamespace=$1::text::regnamespace ORDER BY c.relname,p.polname"
        before = SQL.query!(c.owner_repo, query, [c.schema]).rows
        assert before != []
        assert :ok = SchemaFixture.migrate!(migration_context, source, 14)
        assert :ok = SchemaFixture.migrate!(migration_context, source, 14, :down)
        after_rollback = SQL.query!(c.owner_repo, query, [c.schema]).rows
        assert after_rollback == before
      end
    end
  end
end
