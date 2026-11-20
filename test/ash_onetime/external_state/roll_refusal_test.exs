for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.RollRefusalTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for phase <- [1, 2] do
      @phase phase
      @tag [{String.to_atom("enforcement_roll_default_force_#{phase}_mutation"), true}]
      test "#{partitioning || "plain"}: rolling refuses DEFAULT FORCE reapplied at phase #{@phase}", c do
        default = rel(c, "ash_onetime_response_payloads_default")
        SQL.query!(c.owner_repo, "ALTER TABLE #{default} ENABLE ROW LEVEL SECURITY", [])
        SQL.query!(c.owner_repo, "ALTER TABLE #{default} FORCE ROW LEVEL SECURITY", [])
        SQL.query!(c.owner_repo, "CREATE TABLE #{rel(c, "ddl_phase")}(calls integer NOT NULL)", [])
        SQL.query!(c.owner_repo, "INSERT INTO #{rel(c, "ddl_phase")} VALUES (0)", [])

        body = """
        DECLARE command record; calls integer;
        BEGIN
          FOR command IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
            IF command.classid='pg_class'::regclass AND command.objid=#{literal(default)}::regclass
              AND command.command_tag='ALTER TABLE'
              AND NOT (SELECT relforcerowsecurity FROM pg_class WHERE oid=command.objid) THEN
              UPDATE #{rel(c, "ddl_phase")} SET calls=ddl_phase.calls+1 RETURNING ddl_phase.calls INTO calls;
              IF calls=#{@phase} THEN
                ALTER TABLE #{default} FORCE ROW LEVEL SECURITY;
              END IF;
            END IF;
          END LOOP;
        END
        """

        SQL.query!(c.owner_repo, "CREATE FUNCTION #{rel(c, "reforce_default")}() RETURNS event_trigger LANGUAGE plpgsql AS #{literal(body)}", [])
        event = "ao_reforce_" <> String.replace(Ecto.UUID.generate(), "-", "")
        on_exit(fn -> SQL.query!(Repo, "DROP EVENT TRIGGER IF EXISTS #{q(event)}", []) end)
        SQL.query!(Repo, "CREATE EVENT TRIGGER #{q(event)} ON ddl_command_end EXECUTE FUNCTION #{rel(c, "reforce_default")}()", [])

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: "prune_blocked: FORCE reapplied to DEFAULT"}}} =
                 step(c, "ash_onetime_roll_payload_partitions", "24")
      end
    end
  end
end
