for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.RestoreTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.LogicalReplicationCase, async: false
    @moduletag hash_partitions: partitioning
    alias AshOnetime.Store.Postgres

    for mode <- [:full, :disabled_triggers, :replica, :force_replica] do
      @tag restore_mode: mode
      test "#{partitioning || "plain"}: #{mode} archive restore preserves the trigger trust boundary",
           c do
        seed_completed!(c)
        mode = c.restore_mode
        file = Path.join(System.tmp_dir!(), "ao_restore_#{Ecto.UUID.generate()}.dump")
        on_exit(fn -> File.rm(file) end)
        # The archive contains data once. The destination starts empty, with a
        # current schema for data-only modes and no package objects for full.
        SQL.query!(
          c.sub.admin,
          "TRUNCATE #{rel(c.sub, "ash_onetime_idempotency_claims")},#{rel(c.sub, "ash_onetime_response_payloads")} CASCADE",
          []
        )

        # A fresh destination already has its own migration and maintenance
        # ledgers. Data-only restoration copies the authority relations only.
        options =
          if mode == :full do
            []
          else
            [
              "--data-only",
              "--exclude-table-data=#{c.pub.schema}.schema_migrations",
              "--exclude-table-data=#{c.pub.schema}.ash_onetime_maintenance_runs"
            ]
          end

        {output, status} =
          System.cmd(
            "pg_dump",
            ["--format=custom", "--file", file] ++ options,
            env: pg_environment(c.pub.url, c.pgpassfile),
            stderr_to_stdout: true
          )

        assert status == 0, output

        if mode == :full do
          SQL.query!(c.sub.admin, "DROP SCHEMA #{q(c.sub.schema)} CASCADE", [])

          SQL.query!(
            c.sub.admin,
            "DROP SCHEMA #{q(Postgres.routine_schema(c.sub.schema))} CASCADE",
            []
          )
        end

        if mode == :force_replica, do: force!(c.sub)
        role = if mode in [:replica, :force_replica], do: c.sub.owner, else: "postgres"

        environment = pg_environment(c.sub.url, c.pgpassfile, role)
        environment =
          if mode in [:replica, :force_replica],
            do: [{"PGOPTIONS", "-c session_replication_role=replica"} | environment],
            else: environment

        restore_options = if mode == :disabled_triggers, do: ["--disable-triggers"], else: []

        restore = fn ->
          System.cmd(
            "pg_restore",
            ["--exit-on-error", "--single-transaction", "--dbname="] ++
              restore_options ++ [file],
            env: environment,
            stderr_to_stdout: true
          )
        end

        if mode == :force_replica do
          {output, status} = restore.()
          assert status != 0
          assert output =~ "row-level security"

          assert scalar(
                   c.sub.admin,
                   "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_idempotency_claims")}"
                 ) == 0

          SQL.query!(c.sub.admin, "ALTER ROLE #{q(c.sub.owner)} BYPASSRLS", [])
        end

        {output, status} = restore.()
        assert status == 0, output

        assert scalar(
                 c.sub.admin,
                 "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_idempotency_claims")}"
               ) == 1

        assert scalar(
                 c.sub.admin,
                 "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_effect_outcomes")}"
               ) == 2

        modes =
          SQL.query!(
            c.sub.admin,
            "SELECT t.tgenabled::text FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname=$1 AND NOT t.tgisinternal",
            [c.sub.schema]
          ).rows

        assert modes != []
        if mode == :disabled_triggers do
          assert ["O"] in modes
          assert Enum.all?(modes, &(&1 in [["O"], ["A"]]))
        else
          assert Enum.all?(modes, &(&1 == ["A"]))
        end

        if mode == :disabled_triggers do
          {:ok, %{rows: [[status]]}} =
            SQL.query(
              c.sub.maintainer_repo,
              "SELECT #{q(Postgres.routine_schema(c.sub.schema))}.ash_onetime_maintenance_status()",
              []
            )

          assert status["checks"]["trust"] == false

          for [table, trigger] <-
                SQL.query!(
                  c.sub.admin,
                  "SELECT r.oid::regclass::text,t.tgname FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname=$1 AND NOT t.tgisinternal",
                  [c.sub.schema]
                ).rows do
            SQL.query!(
              c.sub.admin,
              "ALTER TABLE #{table} ENABLE ALWAYS TRIGGER #{q(trigger)}",
              []
            )
          end
        end

        {:ok, %{rows: [[status]]}} =
          SQL.query(
            c.sub.maintainer_repo,
            "SELECT #{q(Postgres.routine_schema(c.sub.schema))}.ash_onetime_maintenance_status()",
            []
          )

        assert status["checks"]["trust"] == true
      end
    end

    @tag :external_state_legacy_archive_mutation
    test "#{partitioning || "plain"}: a pre-2.0 archive derives its response deadline in replica mode",
         c do
      legacy_publisher!(c)
      id = Ecto.UUID.generate()

      SQL.query!(
        c.pub.owner_repo,
        "INSERT INTO #{rel(c.pub, "ash_onetime_idempotency_claims")} (id,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,inserted_at,retain_until) VALUES ($1::uuid,sha256('op'::bytea),sha256('scope'::bytea),sha256('legacy-key'::bytea),sha256('request'::bytea),'processing',transaction_timestamp()-interval '1 day',transaction_timestamp()-interval '1 day',transaction_timestamp()+interval '1 day')",
        [Ecto.UUID.dump!(id)]
      )

      archive = Path.join(System.tmp_dir!(), "ao_legacy_#{Ecto.UUID.generate()}.dump")
      script = archive <> ".sql"
      on_exit(fn -> Enum.each([archive, script], &File.rm/1) end)

      {output, status} =
        System.cmd(
          "pg_dump",
          [
            "--format=custom",
            "--data-only",
            "--exclude-table-data=#{c.pub.schema}.schema_migrations",
            "--file",
            archive
          ],
          env: pg_environment(c.pub.url, c.pgpassfile),
          stderr_to_stdout: true
        )

      assert status == 0, output

      # Extract the archive unchanged, then ask psql for verbose SQLSTATEs.
      # A NOT NULL failure must be visible as 23502 in this row's evidence.
      {output, status} =
        System.cmd("pg_restore", ["--file", script, archive], stderr_to_stdout: true)

      assert status == 0, output

      {output, status} =
        System.cmd(
          "psql",
          [
            "--set=ON_ERROR_STOP=1",
            "--set=VERBOSITY=verbose",
            "--single-transaction",
            "--file",
            script
          ],
          env: [{"PGOPTIONS", "-c session_replication_role=replica"} |
            pg_environment(c.sub.url, c.pgpassfile, c.sub.owner)],
          stderr_to_stdout: true
        )

      assert status == 0, output

      assert scalar(
               c.sub.owner_repo,
               "SELECT response_retain_until=retain_until FROM #{rel(c.sub, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
               [Ecto.UUID.dump!(id)]
             ) == true
    end

    defp pg_environment(url, passfile, role \\ "postgres") do
      uri = URI.parse(url)
      [
        {"PGHOST", uri.host},
        {"PGPORT", Integer.to_string(uri.port)},
        {"PGDATABASE", String.trim_leading(uri.path, "/")},
        {"PGUSER", role},
        {"PGPASSFILE", passfile}
      ]
    end
  end
end
