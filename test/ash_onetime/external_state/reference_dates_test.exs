for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.ReferenceDatesTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.{SchemaFixture, ShippedMigrations}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    for rule <- ~w(reference-date-encoding-refusal legacy-reference-date-encoding-refusal) do
      @rule rule
      @tag [
        {String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}
      ]
      test "#{partitioning || "plain"}: #{@rule} refuses a reference changed by owner DDL", c do
        if @rule == "legacy-reference-date-encoding-refusal" do
          options = if c[:hash_partitions], do: [hash_partitions: c.hash_partitions], else: []

          assert :ok =
                   SchemaFixture.migrate!(
                     c,
                     ShippedMigrations.render("v0.6.0", :render, Repo, options),
                     10
                   )

          assert :ok =
                   SchemaFixture.migrate!(
                     c,
                     Generator.render_logical_partition_upgrade(Repo, []),
                     11
                   )

          assert :ok =
                   SchemaFixture.migrate!(
                     c,
                     Generator.render_operation_hold_upgrade(Repo, []),
                     12
                   )
        else
          assert :ok = install(c)
        end

        body = """
        DECLARE command record;
        BEGIN
          FOR command IN SELECT c.oid::regclass AS child,i.inhparent::regclass AS parent
            FROM pg_event_trigger_ddl_commands() d JOIN pg_class c ON d.classid='pg_class'::regclass AND d.objid=c.oid
            JOIN pg_inherits i ON i.inhrelid=c.oid
            WHERE d.command_tag='CREATE TABLE' AND c.relnamespace=#{literal(c.schema)}::regnamespace
              AND c.relname ~ '^aor_[0-9]+_response_payloads_month$'
          LOOP
            EXECUTE format('ALTER TABLE %s DETACH PARTITION %s',command.parent,command.child);
            EXECUTE format('ALTER TABLE %s ATTACH PARTITION %s FOR VALUES FROM (''2000-03-01'') TO (''2000-04-01'')',command.parent,command.child);
          END LOOP;
        END
        """

        SQL.query!(
          c.owner_repo,
          "CREATE FUNCTION #{rel(c, "change_reference_bound")}() RETURNS event_trigger LANGUAGE plpgsql AS #{literal(body)}",
          []
        )

        event = "ao_bound_" <> String.replace(Ecto.UUID.generate(), "-", "")
        on_exit(fn -> SQL.query!(Repo, "DROP EVENT TRIGGER IF EXISTS #{q(event)}", []) end)

        SQL.query!(
          Repo,
          "CREATE EVENT TRIGGER #{q(event)} ON ddl_command_end EXECUTE FUNCTION #{rel(c, "change_reference_bound")}()",
          []
        )

        result =
          if @rule == "reference-date-encoding-refusal" do
            SQL.query(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_reference")}(false)", [])
          else
            try do
              SchemaFixture.migrate!(c, Generator.render_external_state_upgrade(Repo, []), 13)
            rescue
              error in Postgrex.Error -> {:error, error}
            end
          end

        actual =
          case result do
            {:error,
             %Postgrex.Error{
               postgres: %{
                 pg_code: "P0001",
                 message: "untrusted_dependency: unsupported date encoding"
               }
             }} ->
              true

            _ ->
              false
          end

        assert actual, inspect(result)
      end
    end
  end
end
