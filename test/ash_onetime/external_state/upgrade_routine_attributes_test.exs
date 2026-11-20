for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.UpgradeRoutineAttributesTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.{SchemaFixture, ShippedMigrations}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    setup c do
      options = if c[:hash_partitions], do: [hash_partitions: c.hash_partitions], else: []
      assert :ok = SchemaFixture.migrate!(c, ShippedMigrations.render("v0.6.0", :render, Repo, options), 10)
      assert :ok = SchemaFixture.migrate!(c, Generator.render_logical_partition_upgrade(Repo, []), 11)
      assert :ok = SchemaFixture.migrate!(c, Generator.render_operation_hold_upgrade(Repo, []), 12)
      SQL.query!(c.owner_repo, "CREATE TABLE #{rel(c, "routine_options")} (name text, definer boolean, settings text[], caller name)", [])

      body = """
      BEGIN
        INSERT INTO #{rel(c, "routine_options")}
        SELECT p.proname,p.prosecdef,p.proconfig,current_user
        FROM pg_event_trigger_ddl_commands() command
        JOIN pg_proc p ON command.classid='pg_proc'::regclass AND command.objid=p.oid
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE p.proname IN ('ash_onetime_maintenance_normalize','ash_onetime_maintenance_shape','ash_onetime_maintenance_reference')
          AND n.oid=pg_my_temp_schema();
      END
      """
      SQL.query!(c.owner_repo, "CREATE FUNCTION #{rel(c, "record_routine_options")}() RETURNS event_trigger LANGUAGE plpgsql AS #{literal(body)}", [])
      event = "ao_options_" <> String.replace(Ecto.UUID.generate(), "-", "")
      on_exit(fn -> SQL.query!(Repo, "DROP EVENT TRIGGER IF EXISTS #{q(event)}", []) end)
      SQL.query!(Repo, "CREATE EVENT TRIGGER #{q(event)} ON ddl_command_end EXECUTE FUNCTION #{rel(c, "record_routine_options")}()", [])
      assert :ok = SchemaFixture.migrate!(c, Generator.render_external_state_upgrade(Repo, []), 13)
      :ok
    end

    @tag :enforcement_external_reference_invoker_mutation
    test "#{partitioning || "plain"}: temporary reference routines execute as their caller", c do
      rows = SQL.query!(c.owner_repo, "SELECT name,definer,caller::text FROM #{rel(c, "routine_options")} ORDER BY name", []).rows
      expected = for name <- ~w(ash_onetime_maintenance_normalize ash_onetime_maintenance_reference ash_onetime_maintenance_shape), do: [name, false, c.owner]
      assert rows == expected
    end

    @tag :enforcement_external_reference_search_path_mutation
    test "#{partitioning || "plain"}: temporary reference routines fix their search path", c do
      rows = SQL.query!(c.owner_repo, "SELECT name,settings FROM #{rel(c, "routine_options")} ORDER BY name", []).rows
      expected = for name <- ~w(ash_onetime_maintenance_normalize ash_onetime_maintenance_reference ash_onetime_maintenance_shape), do: [name, ["search_path=pg_catalog, pg_temp"]]
      assert rows == expected
    end

    @tag :enforcement_external_routine_security_mutation
    test "#{partitioning || "plain"}: the upgraded outcome guard retains its declared definer authority", c do
      assert [[true]] = SQL.query!(c.owner_repo, "SELECT prosecdef FROM pg_proc WHERE oid=$1::text::regprocedure", [rel(c, "ash_onetime_guard_effect_outcome") <> "()"]).rows
    end
  end
end
