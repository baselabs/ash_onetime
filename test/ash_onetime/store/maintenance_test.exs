defmodule AshOnetime.Store.MaintenanceTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Store.Postgres
  alias AshOnetime.Store.Result
  alias AshOnetime.Test.ClusterIsolation
  alias AshOnetime.Test.DSTWindow
  alias AshOnetime.Test.ExternalPeer
  alias AshOnetime.Test.Repo
  alias AshOnetime.Test.ShippedMigrations
  alias AshOnetime.Test.StoreCase
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AshOnetime.Doctor
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  setup context do
    Sandbox.mode(Repo, :auto)

    if context[:shipped_release] do
      :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: 900_000)
    end

    ClusterIsolation.assert_per_run_server!()

    suffix = Ecto.UUID.generate() |> String.replace("-", "")

    schema =
      cond do
        context[:quoted_schema] && context[:legacy_install] -> "ao_'$copy$#{suffix}"
        context[:quoted_schema] -> "ao_'\"$copy$#{suffix}"
        true -> "ao_maintenance_#{suffix}"
      end

    migration_schema =
      if context[:quoted_schema] && !context[:legacy_install],
        do: "ao_ledger_#{suffix}",
        else: schema

    owner = "ao_owner_#{suffix}"
    runtime = "ao_runtime_#{suffix}"
    maintainer = "ao_maintainer_#{suffix}"
    outsider = "ao_outsider_#{suffix}"
    migrator = "ao_migrator_#{suffix}"
    roles = [owner, runtime, maintainer, outsider, migrator]

    credentials =
      Map.new([runtime, outsider, migrator], fn role ->
        {role, :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)}
      end)

    on_exit(fn ->
      SQL.query!(Repo, "DROP SCHEMA IF EXISTS #{q(schema)} CASCADE", [])

      if migration_schema != schema,
        do: SQL.query!(Repo, "DROP SCHEMA IF EXISTS #{q(migration_schema)} CASCADE", [])

      for role <- roles do
        SQL.query!(Repo, "DROP OWNED BY #{q(role)}", [])
        SQL.query!(Repo, "DROP ROLE #{q(role)}", [])
      end

      assert SQL.query!(Repo, "SELECT rolname FROM pg_roles WHERE rolname = ANY($1)", [roles]).rows ==
               []

      assert SQL.query!(Repo, "SELECT nspname FROM pg_namespace WHERE nspname = $1", [schema]).rows ==
               []

      assert SQL.query!(Repo, "SELECT nspname FROM pg_namespace WHERE nspname=$1", [
               routine_schema(schema)
             ]).rows == []

      Sandbox.mode(Repo, :manual)
    end)

    for role <- roles do
      login = if role == owner or role == maintainer, do: "NOLOGIN", else: "LOGIN"

      password =
        case credentials[role] do
          nil -> ""
          value -> " PASSWORD " <> literal(value)
        end

      case SQL.query(
             Repo,
             "CREATE ROLE #{q(role)} #{login} NOSUPERUSER NOBYPASSRLS#{password}",
             [],
             log: false
           ) do
        {:ok, _} ->
          :ok

        {:error, %Postgrex.Error{postgres: %{pg_code: code}}} ->
          flunk("role provisioning failed with #{code}")
      end
    end

    SQL.query!(Repo, "GRANT #{q(owner)} TO #{q(migrator)} WITH INHERIT TRUE, SET TRUE", [])
    database = SQL.query!(Repo, "SELECT current_database()", []).rows |> hd() |> hd()
    SQL.query!(Repo, "GRANT CREATE ON DATABASE #{q(database)} TO #{q(owner)}, #{q(migrator)}", [])

    for role <- [owner, runtime, outsider, migrator] do
      login = if role == owner, do: migrator, else: role
      Process.put({__MODULE__, :credential, role}, {login, Map.fetch!(credentials, login)})
    end

    SQL.query!(Repo, "GRANT #{q(maintainer)} TO #{q(runtime)}", [])
    SQL.query!(Repo, "CREATE SCHEMA #{q(schema)} AUTHORIZATION #{q(owner)}", [])

    if migration_schema != schema,
      do: SQL.query!(Repo, "CREATE SCHEMA #{q(migration_schema)} AUTHORIZATION #{q(owner)}", [])

    SQL.query!(Repo, "GRANT USAGE, CREATE ON SCHEMA #{q(schema)} TO #{q(runtime)}", [])
    SQL.query!(Repo, "GRANT USAGE ON SCHEMA #{q(schema)} TO #{q(maintainer)}, #{q(outsider)}", [])

    SQL.query!(
      Repo,
      "ALTER DEFAULT PRIVILEGES FOR ROLE #{q(owner)} IN SCHEMA #{q(schema)} GRANT ALL ON TABLES TO #{q(runtime)}",
      []
    )

    {:ok, owner_repo} = subject(owner, 2)
    {:ok, runtime_repo} = subject(runtime)
    {:ok, outsider_repo} = subject(outsider)

    source =
      if context[:legacy_install] do
        release = context[:shipped_release] || "v1.10.0"

        ShippedMigrations.render(release, :render, Repo,
          hash_partitions: context[:hash_partitions],
          partition_start: context[:partition_start] || ~D[2000-01-01]
        )
      else
        Generator.render(Repo,
          maintenance_role: maintainer,
          hash_partitions: context[:hash_partitions],
          prefix: if(context[:quoted_schema], do: schema, else: nil)
        )
      end

    source =
      source
      |> String.replace(
        "AshOnetime.Test.Repo.Migrations.InstallAshOnetime",
        "AshOnetime.Test.MaintenanceInstall#{suffix}"
      )

    [{module, _}] = Code.compile_string(source)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    previous = Repo.put_dynamic_repo(owner_repo)

    try do
      :ok =
        Ecto.Migrator.up(Repo, 20_261_113_000_001, module, prefix: migration_schema, log: false)

      if context[:shipped_release] do
        seed_shipped_payload!(owner_repo, schema)

        if context[:shipped_release] == "v0.1.0" do
          migrate_source!(
            owner_repo,
            schema,
            ShippedMigrations.render("v0.6.0", :render_roll_forward, Repo,
              partition_start: ~D[2000-01-01],
              months: 1
            )
          )
        end

        if context[:shipped_release] in ["v0.1.0", "v0.2.0", "v0.6.0"] do
          migrate_source!(
            owner_repo,
            schema,
            ShippedMigrations.render("v1.1.0", :render_logical_partition_upgrade, Repo, [])
          )
        end

        unless context[:shipped_release] == "v1.10.0" do
          migrate_source!(
            owner_repo,
            schema,
            ShippedMigrations.render("v1.10.0", :render_operation_hold_upgrade, Repo, [])
          )
        end
      end

      if context[:shipped_release] in ["v1.1.0", "v1.10.0"] do
        migrate_source!(
          owner_repo,
          schema,
          ShippedMigrations.render("v1.8.0", :render_fact_tables, Repo,
            fact_tables: ["maintenance_facts", "additional_facts"]
          )
        )

        sql!(
          owner_repo,
          "INSERT INTO #{q(schema)}.maintenance_facts (tenant,type,tags) VALUES ('partition-a','retained',ARRAY['fact'])"
        )
      end

      if context[:legacy_install] && !context[:firing_upgrade_mutation] do
        migrate_source!(owner_repo, schema, Generator.render_operation_hold_upgrade(Repo, []))

        unless context[:shipped_release] do
          migrate_source!(owner_repo, schema, Generator.render_external_state_upgrade(Repo, []))
        end
      end

      for table <- [
            "ash_onetime_idempotency_claims",
            "ash_onetime_nonce_claims",
            "ash_onetime_response_payloads"
          ] do
        SQL.query!(
          owner_repo,
          "ALTER TABLE #{q(schema)}.#{q(table)} ENABLE ROW LEVEL SECURITY",
          []
        )

        SQL.query!(
          owner_repo,
          "ALTER TABLE #{q(schema)}.#{q(table)} FORCE ROW LEVEL SECURITY",
          []
        )

        SQL.query!(
          owner_repo,
          "CREATE POLICY runtime_tenant ON #{q(schema)}.#{q(table)} TO #{q(runtime)} USING (logical_partition=current_setting('ash_onetime.tenant',true))",
          []
        )
      end

      unless context[:legacy_install] do
        for [child] <-
              SQL.query!(
                owner_repo,
                "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent=$1::text::regclass",
                [q(schema) <> ".ash_onetime_response_payloads"]
              ).rows do
          SQL.query!(owner_repo, "ALTER TABLE #{child} ENABLE ROW LEVEL SECURITY", [])
          SQL.query!(owner_repo, "ALTER TABLE #{child} FORCE ROW LEVEL SECURITY", [])
        end
      end
    after
      Repo.put_dynamic_repo(previous)
    end

    %{
      schema: schema,
      owner: owner,
      runtime: runtime,
      outsider: outsider,
      maintainer: maintainer,
      migrator: migrator,
      owner_repo: owner_repo,
      runtime_repo: runtime_repo,
      outsider_repo: outsider_repo
    }
  end

  @tag defects_batch: true
  @tag complete_restore_mutation: true
  test "non-aborting completion errors restore the timeout before rollback on the same connection",
       c do
    previous = Repo.put_dynamic_repo(c.runtime_repo)

    try do
      for site <- [:payload, :claim] do
        assert {:ok, claim} =
                 Repo.transaction(fn ->
                   sql!(c.runtime_repo, "SET LOCAL ash_onetime.tenant = 'global'")
                   target = Postgres.for_repo(Repo, c.schema)

                   assert %Result{status: :admitted, claim: claim} =
                            Postgres.claim(target, dst_request("restore-#{site}", 3600))

                   if site == :payload do
                     assert %Result{status: :complete} =
                              Postgres.complete(
                                target,
                                claim,
                                "test",
                                :crypto.hash(:sha256, "response"),
                                "response"
                              )
                   end

                   claim
                 end)

        # An existing payload makes INSERT return zero rows. A stale logical
        # key makes UPDATE return zero rows after its successful payload INSERT.
        claim =
          if site == :claim, do: %{claim | key_hash: :crypto.hash(:sha256, "stale")}, else: claim

        assert {:error, %Result{reason: :store_invariant}} =
                 Repo.transaction(fn ->
                   sql!(c.runtime_repo, "SET LOCAL ash_onetime.tenant = 'global'")
                   sql!(c.runtime_repo, "SET LOCAL lock_timeout = '7s'")
                   backend = scalar(c.runtime_repo, "SELECT pg_backend_pid()")

                   try do
                     Postgres.complete_external(
                       Postgres.for_repo(Repo, c.schema),
                       claim,
                       "test",
                       :crypto.hash(:sha256, "response"),
                       "response"
                     )
                   catch
                     :throw,
                     {DBConnection, _reference, %Result{reason: :store_invariant}} = rollback ->
                       assert scalar(c.runtime_repo, "SELECT pg_backend_pid()") == backend
                       assert scalar(c.runtime_repo, "SHOW lock_timeout") == "7s"
                       throw(rollback)
                   end
                 end)
      end
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  @tag defects_batch: true
  @tag fact_schema_mutation: true
  test "trust refuses an ORIGIN fact trigger outside the install schema", c do
    install_facts!(c)
    schema = move_fact_table!(c)
    assert trust?(c)

    sql!(
      c.owner_repo,
      "ALTER TABLE #{q(schema)}.audit_facts ENABLE TRIGGER audit_facts_append_only"
    )

    assert trust_error(c) =~ "fact trigger firing mode"
    assert doctor_refusal(c) =~ "audit_facts_append_only"

    sql!(
      c.owner_repo,
      "ALTER TABLE #{q(schema)}.audit_facts ENABLE ALWAYS TRIGGER audit_facts_append_only"
    )

    assert trust?(c)
  end

  @tag defects_batch: true
  @tag legacy_install: true
  @tag firing_upgrade_mutation: true
  @tag fact_upgrade_schema_mutation: true
  test "operation hold upgrade enables fact triggers outside the install schema", c do
    install_facts!(c)
    schema = move_fact_table!(c)

    sql!(
      c.owner_repo,
      "ALTER TABLE #{q(schema)}.audit_facts ENABLE TRIGGER audit_facts_append_only"
    )

    migrate_source!(c.owner_repo, c.schema, Generator.render_operation_hold_upgrade(Repo, []))

    assert scalar(
             c.owner_repo,
             "SELECT tgenabled::text FROM pg_trigger WHERE tgrelid='#{q(schema)}.audit_facts'::regclass AND tgname='audit_facts_append_only'"
           ) == "A"
  end

  for branch <- [:up, :down], count <- [nil, 4] do
    @branch branch
    @tag defects_batch: true
    @tag legacy_install: true
    @tag firing_upgrade_mutation: true
    @tag replica_lookup_legacy_mutation: true
    @tag hash_partitions: count
    test "legacy #{@branch} claims guard binds replica lookups with #{inspect(count)} partitions",
         c do
      # The downgrade correctly refuses a proof narrowed by forced RLS. This
      # fixture exercises the DELETE guard directly, with RLS disabled throughout.
      sql!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DISABLE ROW LEVEL SECURITY"
      )

      run_migration_roundtrip!(c, Generator.render_operation_hold_upgrade(Repo, []), @branch)
      seed_guard_rows!(c)
      install_shadow_lookups!(c)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               SQL.query(
                 c.runtime_repo,
                 "DELETE FROM #{rel(c, "ash_onetime_idempotency_claims")}",
                 []
               )
    end
  end

  for count <- [nil, 4] do
    @tag defects_batch: true
    @tag legacy_install: true
    @tag firing_down_mutation: true
    @tag hash_partitions: count
    test "maintenance down restores ALWAYS guards with #{inspect(count)} partitions", c do
      run_migration_roundtrip!(
        c,
        Generator.render_maintenance_upgrade(Repo,
          prefix: c.schema,
          maintenance_role: c.maintainer
        ),
        :down
      )

      assert Enum.all?(package_triggers(c), fn [_, _, enabled] -> enabled == "A" end)
    end
  end

  defp move_fact_table!(c) do
    schema = c.schema <> "_facts"
    on_exit(fn -> sql!(Repo, "DROP SCHEMA IF EXISTS #{q(schema)} CASCADE") end)
    sql!(c.owner_repo, "CREATE SCHEMA #{q(schema)}")
    sql!(c.owner_repo, "ALTER TABLE #{rel(c, "audit_facts")} SET SCHEMA #{q(schema)}")
    schema
  end

  defp install_shadow_lookups!(c) do
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{q(c.schema)}.current_setting(text) RETURNS text LANGUAGE sql AS 'SELECT ''replica''::text'"
    )

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{q(c.schema)}.pg_has_role(name,oid,text) RETURNS boolean LANGUAGE sql AS 'SELECT true'"
    )

    sql!(c.runtime_repo, "SET search_path=#{q(c.schema)},pg_catalog")

    assert scalar(c.runtime_repo, "SELECT pg_catalog.current_setting('session_replication_role')") ==
             "origin"

    refute scalar(
             c.runtime_repo,
             "SELECT pg_catalog.pg_has_role(current_user,#{literal(c.owner)},'SET')"
           )
  end

  defp run_migration_roundtrip!(c, source, direction) do
    module = Module.concat(__MODULE__, "Roundtrip#{System.unique_integer([:positive])}")

    source =
      Regex.replace(~r/defmodule \S+ do/, source, "defmodule #{inspect(module)} do",
        global: false
      )

    Code.compile_string(source)
    previous = Repo.put_dynamic_repo(c.owner_repo)
    version = 20_261_113_100_000 + System.unique_integer([:positive, :monotonic])

    try do
      assert :ok = Ecto.Migrator.up(Repo, version, module, prefix: c.schema, log: false)

      if direction == :down do
        # This roundtrip proves function restoration. FORCE RLS refusal is
        # exercised separately by the rollback boundary tests.
        sql!(
          c.owner_repo,
          "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} NO FORCE ROW LEVEL SECURITY"
        )

        assert :ok = Ecto.Migrator.down(Repo, version, module, prefix: c.schema, log: false)

        sql!(
          c.owner_repo,
          "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} FORCE ROW LEVEL SECURITY"
        )
      end
    after
      Repo.put_dynamic_repo(previous)
      :code.purge(module)
      :code.delete(module)
    end
  end

  for direction <- [:forward, :backward] do
    @direction direction
    @tag defects_batch: true
    @tag d_dst: true
    @tag dst_complete_mutation: true
    test "external completion restarts exact elapsed retention across the next #{@direction} DST change",
         c do
      {zone, seconds} = dst_window!(c, @direction)
      install_dst_observer!(c)

      claim =
        dst_transaction(c, zone, fn target ->
          assert %Result{status: :admitted, claim: claim} =
                   Postgres.claim(target, dst_request("external", seconds))

          claim
        end)

      dst_transaction(c, zone, fn target ->
        assert %Result{status: :complete} =
                 Postgres.complete_external(
                   target,
                   claim,
                   "test",
                   :crypto.hash(:sha256, "response"),
                   "response"
                 )

        assert_dst_restart(c, claim.id, zone, seconds)
      end)
    end

    @tag defects_batch: true
    @tag d_dst: true
    @tag dst_release_mutation: true
    test "hold release restarts exact elapsed retention across the next #{@direction} DST change",
         c do
      {zone, seconds} = dst_window!(c, @direction)
      install_dst_observer!(c)
      claim = dst_held_claim!(c, zone, seconds, "restart")

      StoreCase.restore_fixture!(
        Repo,
        """
        UPDATE #{rel(c, "ash_onetime_idempotency_claims")}
        SET admitted_at = admitted_at - interval '7200 seconds',
            inserted_at = inserted_at - interval '7200 seconds',
            retain_until = retain_until - interval '7200 seconds'
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(claim.id)]
      )

      dst_transaction(c, zone, fn target ->
        assert {:ok, 1} = Postgres.release(target, "restart")
        assert_dst_restart(c, claim.id, zone, seconds)
      end)

      later = dst_held_claim!(c, zone, seconds, "later")

      StoreCase.restore_fixture!(
        Repo,
        """
        UPDATE #{rel(c, "ash_onetime_idempotency_claims")}
        SET admitted_at = admitted_at + interval '7200 seconds',
            inserted_at = inserted_at + interval '7200 seconds',
            retain_until = retain_until + interval '7200 seconds'
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(later.id)]
      )

      dst_transaction(c, zone, fn target ->
        assert {:ok, 1} = Postgres.release(target, "later")

        assert SQL.query!(
                 c.runtime_repo,
                 """
                 SELECT old_deadline = new_deadline, zone, writer
                 FROM #{q(c.schema)}.dst_observations
                 WHERE claim_id = $1::uuid AND old_hold = 'later' AND new_hold IS NULL
                 """,
                 [Ecto.UUID.dump!(later.id)]
               ).rows == [[true, zone, c.runtime]]
      end)
    end
  end

  defp dst_window!(c, direction) do
    today = scalar(c.runtime_repo, "SELECT (statement_timestamp() AT TIME ZONE 'UTC')::date")
    {zone, seconds} = DSTWindow.build(today, direction)

    rows =
      SQL.query!(
        c.runtime_repo,
        """
        WITH samples AS (
          SELECT hour,
            EXTRACT(EPOCH FROM (
              (instant AT TIME ZONE $1) - (instant AT TIME ZONE 'UTC')
            ))::integer AS utc_offset
          FROM generate_series(0, 14 * 24) AS hours(hour)
          CROSS JOIN LATERAL (
            SELECT statement_timestamp() + hour * interval '3600 seconds' AS instant
          ) AS instants
        ), offsets AS (
          SELECT *, utc_offset - lag(utc_offset) OVER (ORDER BY hour) AS change
          FROM samples
        )
        SELECT hour * 3600, change FROM offsets WHERE change <> 0 ORDER BY hour
        """,
        [zone]
      ).rows

    change = if direction == :forward, do: 3600, else: -3600

    assert [[first, ^change], [second, opposite]] = rows,
           "PostgreSQL supplied no matching POSIX transitions for #{zone}: #{inspect(rows)}"

    assert opposite == -change
    assert first < seconds and seconds < second
    {zone, seconds}
  end

  defp install_dst_observer!(c) do
    sql!(c.owner_repo, """
    CREATE POLICY dst_owner_fixture ON #{rel(c, "ash_onetime_idempotency_claims")}
    TO #{q(c.owner)} USING (true) WITH CHECK (true)
    """)

    sql!(c.owner_repo, """
    CREATE TABLE #{q(c.schema)}.dst_observations (
      claim_id uuid, old_deadline timestamptz, new_deadline timestamptz,
      statement_time timestamptz, old_hold text, new_hold text, zone text, writer name
    )
    """)

    # Observe the actual UPDATE's statement time without changing its SQL or its
    # result. This invoker trigger neither supplies nor overrides a clock.
    sql!(c.owner_repo, """
    CREATE FUNCTION #{q(c.schema)}.observe_dst_update() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO #{q(c.schema)}.dst_observations VALUES (
        NEW.id, OLD.retain_until, NEW.retain_until, statement_timestamp(),
        OLD.hold_reference, NEW.hold_reference, current_setting('TimeZone'), current_user
      );
      RETURN NEW;
    END
    $$
    """)

    sql!(c.owner_repo, """
    CREATE TRIGGER observe_dst_update AFTER UPDATE
    ON #{rel(c, "ash_onetime_idempotency_claims")}
    FOR EACH ROW EXECUTE FUNCTION #{q(c.schema)}.observe_dst_update()
    """)
  end

  defp dst_transaction(c, zone, callback) do
    previous = Repo.put_dynamic_repo(c.runtime_repo)

    try do
      assert {:ok, result} =
               Repo.transaction(fn ->
                 SQL.query!(c.runtime_repo, "SELECT set_config('TimeZone', $1, true)", [zone])
                 sql!(c.runtime_repo, "SET LOCAL ash_onetime.tenant = 'global'")
                 callback.(Postgres.for_repo(Repo, c.schema))
               end)

      result
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp dst_request(label, seconds),
    do: StoreCase.idempotency_request("dst-" <> label, retention_seconds: seconds)

  defp dst_held_claim!(c, zone, seconds, reference) do
    dst_transaction(c, zone, fn target ->
      assert %Result{status: :admitted, claim: claim} =
               Postgres.claim(target, dst_request(reference, seconds))

      assert %Result{status: :complete} =
               Postgres.complete(
                 target,
                 claim,
                 "test",
                 :crypto.hash(:sha256, "response"),
                 "response",
                 reference
               )

      claim
    end)
  end

  defp assert_dst_restart(c, id, zone, seconds) do
    assert SQL.query!(
             c.runtime_repo,
             """
             SELECT (EXTRACT(EPOCH FROM (new_deadline - statement_time)) * 1000000)::bigint,
                    new_deadline >= old_deadline, zone, writer
             FROM #{q(c.schema)}.dst_observations
             WHERE claim_id = $1::uuid AND writer = current_user
               AND new_hold IS NULL
             """,
             [Ecto.UUID.dump!(id)]
           ).rows == [[seconds * 1_000_000, true, zone, c.runtime]]
  end

  for count <- [nil, 4] do
    @tag defects_batch: true
    @tag firing_fresh: true
    @tag hash_partitions: count
    test "fresh package triggers fire ALWAYS with #{inspect(count)} hash partitions", c do
      install_facts!(c)
      rows = package_triggers(c)
      assert length(rows) == if(unquote(count), do: 11, else: 3)
      assert Enum.all?(rows, fn [_table, _trigger, mode] -> mode == "A" end)
    end
  end

  for {kind, table} <- [
        {:claims, "ash_onetime_idempotency_claims"},
        {:nonce, "ash_onetime_nonce_claims"},
        {:fact, "audit_facts"}
      ] do
    @kind kind
    @table table
    @tag defects_batch: true
    @tag [{String.to_atom("firing_#{kind}_mutation"), true}]
    test "replica mode refuses untrusted #{@kind} DELETE through its own guard", c do
      install_facts!(c)
      seed_guard_rows!(c)
      grant_guard_dependencies!(c)
      sql!(Repo, "GRANT SET ON PARAMETER session_replication_role TO #{q(c.outsider)}")
      sql!(c.owner_repo, "GRANT SELECT, DELETE ON #{rel(c, @table)} TO #{q(c.outsider)}")
      sql!(c.owner_repo, "ALTER TABLE #{rel(c, @table)} DISABLE ROW LEVEL SECURITY")
      {:ok, cold} = subject(c.outsider)
      sql!(cold, "SET session_replication_role=replica")

      try do
        assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
                 SQL.query(cold, "DELETE FROM #{rel(c, @table)}", [])

        assert scalar(Repo, "SELECT count(*) FROM #{rel(c, @table)}") == 1
      after
        sql!(cold, "SET session_replication_role=origin")
        sql!(Repo, "REVOKE SET ON PARAMETER session_replication_role FROM #{q(c.outsider)}")
      end
    end
  end

  @tag defects_batch: true
  @tag replica_admit_mutation: true
  test "replica admission is restricted and trusted DELETE leaves payload mirroring to apply",
       c do
    seed_guard_rows!(c)
    grant_guard_dependencies!(c)

    sql!(
      Repo,
      "GRANT SET ON PARAMETER session_replication_role TO #{q(c.outsider)}, #{q(c.migrator)}"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DISABLE ROW LEVEL SECURITY"
    )

    sql!(
      c.owner_repo,
      "GRANT SELECT, DELETE ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.outsider)}"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_nonce_claims")} DISABLE ROW LEVEL SECURITY"
    )

    {:ok, cold} = subject(c.outsider)
    {:ok, trusted} = subject(c.migrator)

    try do
      sql!(cold, "SET session_replication_role=replica")

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               SQL.query(cold, "DELETE FROM #{rel(c, "ash_onetime_idempotency_claims")}", [])

      sql!(trusted, "SET session_replication_role=replica")

      assert sql!(trusted, "DELETE FROM #{rel(c, "ash_onetime_idempotency_claims")}").num_rows ==
               1

      assert scalar(Repo, "SELECT count(*) FROM #{rel(c, "ash_onetime_response_payloads")}") == 1
      assert sql!(trusted, "DELETE FROM #{rel(c, "ash_onetime_nonce_claims")}").num_rows == 1
    after
      sql!(cold, "SET session_replication_role=origin")
      sql!(trusted, "SET session_replication_role=origin")

      sql!(
        Repo,
        "REVOKE SET ON PARAMETER session_replication_role FROM #{q(c.outsider)}, #{q(c.migrator)}"
      )
    end
  end

  @tag defects_batch: true
  test "trust refuses ORIGIN guards and doctor names every non-ALWAYS package trigger", c do
    install_facts!(c)

    for [table, trigger, _mode] <- package_triggers(c) do
      sql!(c.owner_repo, "ALTER TABLE #{q(c.schema)}.#{q(table)} ENABLE TRIGGER #{q(trigger)}")
    end

    refute trust?(c)
    output = doctor_refusal(c)

    for [table, trigger, _mode] <- package_triggers(c) do
      assert output =~ table
      assert output =~ trigger
    end
  end

  for count <- [nil, 4] do
    @tag defects_batch: true
    @tag firing_upgrade_mutation: true
    @tag legacy_install: true
    @tag hash_partitions: count
    test "operation hold upgrade enables every trigger by function with #{inspect(count)} partitions",
         c do
      install_facts!(c)
      # The upgrade must discover fact triggers by tgfoid, including renamed triggers.
      sql!(
        c.owner_repo,
        "ALTER TRIGGER audit_facts_append_only ON #{rel(c, "audit_facts")} RENAME TO renamed_guard"
      )

      for [table, trigger, _] <- package_triggers(c) do
        sql!(c.owner_repo, "ALTER TABLE #{q(c.schema)}.#{q(table)} ENABLE TRIGGER #{q(trigger)}")
      end

      migrate_source!(c.owner_repo, c.schema, Generator.render_operation_hold_upgrade(Repo, []))
      rows = package_triggers(c)
      assert Enum.all?(rows, fn [_table, _trigger, mode] -> mode == "A" end)
      assert Enum.any?(rows, fn [_, trigger, _] -> trigger == "renamed_guard" end)

      seed_guard_rows!(c)

      # Legacy invoker functions inherit the writer's search_path. Their new
      # replica admission must resolve the server's authority checks exactly.
      sql!(c.runtime_repo, """
      CREATE FUNCTION #{q(c.schema)}.current_setting(text) RETURNS text
      LANGUAGE sql AS 'SELECT ''replica''::text'
      """)

      sql!(c.runtime_repo, """
      CREATE FUNCTION #{q(c.schema)}.pg_has_role(name,oid,text) RETURNS boolean
      LANGUAGE sql AS 'SELECT true'
      """)

      sql!(c.runtime_repo, "SET search_path=#{q(c.schema)},pg_catalog")

      assert scalar(
               c.runtime_repo,
               "SELECT pg_catalog.current_setting('session_replication_role')"
             ) == "origin"

      refute scalar(
               c.runtime_repo,
               "SELECT pg_catalog.pg_has_role(current_user,#{literal(c.owner)},'SET')"
             )

      for table <- ["ash_onetime_idempotency_claims", "ash_onetime_nonce_claims"] do
        sql!(c.owner_repo, "ALTER TABLE #{rel(c, table)} DISABLE ROW LEVEL SECURITY")

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
                 SQL.query(c.runtime_repo, "DELETE FROM #{rel(c, table)}", [])
      end
    end
  end

  @tag defects_batch: true
  @tag contain_mutation: true
  test "containment refuses an untrusted table schema owner with a real cascade control", c do
    seed_guard_rows!(c)
    sql!(Repo, "ALTER SCHEMA #{q(c.schema)} OWNER TO #{q(c.outsider)}")
    sql!(Repo, "GRANT USAGE, CREATE ON SCHEMA #{q(c.schema)} TO #{q(c.owner)}")
    error = trust_error(c)
    assert error =~ "containment"
    assert error =~ c.schema
    assert error =~ c.outsider

    rollback_control(
      c.outsider_repo,
      "DROP SCHEMA #{q(c.schema)} CASCADE",
      rel(c, "ash_onetime_idempotency_claims")
    )

    sql!(Repo, "ALTER SCHEMA #{q(c.schema)} OWNER TO #{q(c.owner)}")
    assert trust?(c)
  end

  for membership <- [:inherit, :admin] do
    @membership membership
    @tag defects_batch: true
    @tag holder_mutation: true
    test "containment refuses a superuser schema owner's #{@membership} holder", c do
      owner = "ao_structural_#{System.unique_integer([:positive])}"
      sql!(Repo, "CREATE ROLE #{q(owner)} SUPERUSER NOLOGIN")

      try do
        sql!(Repo, "ALTER SCHEMA #{q(c.schema)} OWNER TO #{q(owner)}")
        sql!(Repo, "GRANT USAGE, CREATE ON SCHEMA #{q(c.schema)} TO #{q(c.owner)}")

        options =
          if @membership == :inherit,
            do: "INHERIT TRUE, SET FALSE, ADMIN FALSE",
            else: "INHERIT FALSE, SET FALSE, ADMIN TRUE"

        sql!(Repo, "GRANT #{q(owner)} TO #{q(c.outsider)} WITH #{options}")
        {:ok, cold} = subject(c.outsider)
        refute scalar(cold, "SELECT rolsuper FROM pg_roles WHERE rolname=current_user")
        error = trust_error(c)
        assert error =~ "holder"
        assert error =~ owner
        assert error =~ c.outsider
        assert error =~ c.schema

        if @membership == :inherit do
          rollback_control(
            cold,
            "DROP TABLE #{rel(c, "ash_onetime_idempotency_claims")} CASCADE",
            rel(c, "ash_onetime_idempotency_claims")
          )
        end

        sql!(Repo, "REVOKE #{q(owner)} FROM #{q(c.outsider)}")
        assert trust?(c)
      after
        sql!(Repo, "ALTER SCHEMA #{q(c.schema)} OWNER TO #{q(c.owner)}")
        sql!(Repo, "DROP ROLE #{q(owner)}")
      end
    end
  end

  @tag defects_batch: true
  @tag internal_mutation: true
  test "containment follows internal row types into extension membership", c do
    seed_guard_rows!(c)
    database = scalar(Repo, "SELECT current_database()")
    sql!(Repo, "GRANT CREATE ON DATABASE #{q(database)} TO #{q(c.outsider)}")
    sql!(Repo, "GRANT CREATE ON SCHEMA #{q(c.schema)} TO #{q(c.outsider)}")

    try do
      sql!(c.outsider_repo, "CREATE EXTENSION citext SCHEMA #{q(c.schema)}")
      sql!(Repo, "REVOKE CREATE ON DATABASE #{q(database)} FROM #{q(c.outsider)}")
      sql!(Repo, "ALTER EXTENSION citext ADD TYPE #{rel(c, "ash_onetime_idempotency_claims")}")
      error = trust_error(c)
      assert error =~ "containment"
      assert error =~ "citext"
      assert error =~ c.outsider

      rollback_control(
        c.outsider_repo,
        "DROP EXTENSION citext CASCADE",
        rel(c, "ash_onetime_idempotency_claims")
      )

      sql!(Repo, "ALTER EXTENSION citext DROP TYPE #{rel(c, "ash_onetime_idempotency_claims")}")
      assert trust?(c)
      signature = rel(c, "ash_onetime_cleanup_eligible") <> "(timestamptz)"
      sql!(c.owner_repo, "ALTER FUNCTION #{signature} DEPENDS ON EXTENSION citext")
      assert trust_error(c) =~ "citext"
      sql!(c.owner_repo, "ALTER FUNCTION #{signature} NO DEPENDS ON EXTENSION citext")
      assert trust?(c)
    after
      sql!(Repo, "DROP EXTENSION IF EXISTS citext CASCADE")
      sql!(Repo, "REVOKE CREATE ON DATABASE #{q(database)} FROM #{q(c.outsider)}")
    end
  end

  @tag defects_batch: true
  @tag extmember_mutation: true
  test "containment follows extension members into their untrusted schema", c do
    schema = "ao_member_#{System.unique_integer([:positive])}"
    guard = rel(c, "ash_onetime_guard_idempotency_delete") <> "()"
    member = q(schema) <> ".f()"
    claims = rel(c, "ash_onetime_idempotency_claims")

    sql!(
      c.owner_repo,
      "GRANT USAGE ON SCHEMA #{q(Postgres.routine_schema(c.schema))} TO #{q(c.outsider)}"
    )

    sql!(Repo, "CREATE SCHEMA #{q(schema)} AUTHORIZATION #{q(c.outsider)}")
    sql!(Repo, "CREATE EXTENSION citext SCHEMA #{q(c.schema)}")

    try do
      sql!(Repo, "CREATE FUNCTION #{member} RETURNS integer LANGUAGE sql AS 'SELECT 1'")
      sql!(Repo, "ALTER FUNCTION #{member} OWNER TO #{q(c.owner)}")
      sql!(Repo, "ALTER EXTENSION citext ADD FUNCTION #{member}")
      sql!(c.owner_repo, "ALTER FUNCTION #{guard} DEPENDS ON EXTENSION citext")

      sql!(
        Repo,
        "INSERT INTO #{claims} (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,retain_until,inserted_at) VALUES (gen_random_uuid(),'unresolved',sha256('operation'),sha256('scope'),sha256('key'),sha256('body'),'processing',now(),now()+interval '1 day',now())"
      )

      sql!(c.owner_repo, "ALTER TABLE #{claims} DISABLE ROW LEVEL SECURITY")
      sql!(c.owner_repo, "GRANT DELETE, SELECT ON #{claims} TO #{q(c.outsider)}")
      error = trust_error(c)
      assert error =~ "containment"
      assert error =~ schema
      assert error =~ c.outsider
      sql!(c.outsider_repo, "BEGIN")

      try do
        sql!(c.outsider_repo, "DROP SCHEMA #{q(schema)} CASCADE")
        refute scalar(c.outsider_repo, "SELECT to_regprocedure(#{literal(guard)}) IS NOT NULL")

        assert sql!(c.outsider_repo, "DELETE FROM #{claims} WHERE logical_partition='unresolved'").num_rows ==
                 1
      after
        sql!(c.outsider_repo, "ROLLBACK")
      end

      assert scalar(Repo, "SELECT count(*) FROM #{claims}") == 1
      sql!(Repo, "ALTER EXTENSION citext DROP FUNCTION #{member}")
      assert trust?(c)
    after
      sql!(c.owner_repo, "ALTER FUNCTION #{guard} NO DEPENDS ON EXTENSION citext")
      sql!(Repo, "DROP EXTENSION IF EXISTS citext CASCADE")
      sql!(Repo, "DROP SCHEMA IF EXISTS #{q(schema)} CASCADE")
    end
  end

  @tag defects_batch: true
  @tag oid_mutation: true
  test "containment follows low-OID plpgsql extension members into their schema", c do
    schema = "ao_language_#{System.unique_integer([:positive])}"
    member = q(schema) <> ".f()"
    guard = rel(c, "ash_onetime_guard_idempotency_delete") <> "()"
    claims = rel(c, "ash_onetime_idempotency_claims")

    sql!(
      c.owner_repo,
      "GRANT USAGE ON SCHEMA #{q(Postgres.routine_schema(c.schema))} TO #{q(c.outsider)}"
    )

    sql!(Repo, "CREATE SCHEMA #{q(schema)} AUTHORIZATION #{q(c.outsider)}")

    try do
      sql!(Repo, "CREATE FUNCTION #{member} RETURNS integer LANGUAGE sql AS 'SELECT 1'")
      sql!(Repo, "ALTER FUNCTION #{member} OWNER TO #{q(c.owner)}")
      sql!(Repo, "ALTER EXTENSION plpgsql ADD FUNCTION #{member}")

      sql!(Repo, """
      INSERT INTO #{claims}
      (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,retain_until,inserted_at)
      VALUES (gen_random_uuid(),'unresolved',sha256('operation'),sha256('scope'),sha256('key'),sha256('body'),'processing',now(),now()+interval '1 day',now())
      """)

      sql!(c.owner_repo, "ALTER TABLE #{claims} DISABLE ROW LEVEL SECURITY")
      sql!(c.owner_repo, "GRANT DELETE, SELECT ON #{claims} TO #{q(c.outsider)}")
      error = trust_error(c)
      assert error =~ "containment"
      assert error =~ schema
      assert error =~ c.outsider
      sql!(c.outsider_repo, "BEGIN")

      try do
        sql!(c.outsider_repo, "DROP SCHEMA #{q(schema)} CASCADE")
        refute scalar(c.outsider_repo, "SELECT to_regprocedure(#{literal(guard)}) IS NOT NULL")

        assert sql!(c.outsider_repo, "DELETE FROM #{claims} WHERE logical_partition='unresolved'").num_rows ==
                 1
      after
        sql!(c.outsider_repo, "ROLLBACK")
      end

      assert scalar(Repo, "SELECT count(*) FROM #{claims}") == 1
      sql!(Repo, "ALTER EXTENSION plpgsql DROP FUNCTION #{member}")
      assert trust?(c)
    after
      # DROP SCHEMA while it remains an extension member would remove plpgsql.
      if scalar(
           Repo,
           "SELECT EXISTS (SELECT 1 FROM pg_depend WHERE classid='pg_proc'::regclass AND objid=to_regprocedure(#{literal(member)}) AND refclassid='pg_extension'::regclass AND deptype='e')"
         ) do
        sql!(Repo, "ALTER EXTENSION plpgsql DROP FUNCTION #{member}")
      end

      sql!(Repo, "DROP SCHEMA IF EXISTS #{q(schema)} CASCADE")
    end
  end

  @tag defects_batch: true
  test "public containment checks database ownership and every database owner holder", c do
    with_public_install(c, fn public ->
      sql!(Repo, "ALTER DATABASE #{q(public.database)} OWNER TO #{q(c.outsider)}")
      error = trust_error(public)
      assert error =~ "pg_database_owner"
      assert error =~ c.outsider
      sql!(Repo, "ALTER DATABASE #{q(public.database)} OWNER TO #{q(c.owner)}")
      assert trust?(public)
      structural = "ao_database_#{System.unique_integer([:positive])}"
      sql!(Repo, "CREATE ROLE #{q(structural)} SUPERUSER NOLOGIN")

      try do
        sql!(Repo, "ALTER DATABASE #{q(public.database)} OWNER TO #{q(structural)}")
        sql!(Repo, "GRANT #{q(structural)} TO #{q(c.outsider)} WITH INHERIT TRUE, SET FALSE")
        error = trust_error(public)
        assert error =~ "holder"
        assert error =~ "pg_database_owner"
        assert error =~ structural
        assert error =~ c.outsider
        sql!(Repo, "REVOKE #{q(structural)} FROM #{q(c.outsider)}")
        assert trust?(public)
      after
        sql!(Repo, "ALTER DATABASE #{q(public.database)} OWNER TO #{q(c.owner)}")
        sql!(Repo, "DROP ROLE #{q(structural)}")
      end
    end)
  end

  for event <- ["ddl_command_start", "login"] do
    @event event
    @tag defects_batch: true
    @tag evt_trust_mutation: true
    @tag evt_doctor_mutation: true
    test "trust and doctor audit #{@event} event code and its execution identity", c do
      event = "ao_event_#{System.unique_integer([:positive])}"
      function = rel(c, "event_code")
      sql!(Repo, "GRANT CREATE ON SCHEMA #{q(c.schema)} TO #{q(c.outsider)}")

      sql!(
        Repo,
        "CREATE FUNCTION #{function}() RETURNS event_trigger LANGUAGE plpgsql AS 'BEGIN END'"
      )

      sql!(Repo, "ALTER FUNCTION #{function}() OWNER TO #{q(c.outsider)}")
      sql!(Repo, "CREATE EVENT TRIGGER #{q(event)} ON #{@event} EXECUTE FUNCTION #{function}()")

      try do
        for mode <- ["ENABLE", "DISABLE"] do
          sql!(Repo, "ALTER EVENT TRIGGER #{q(event)} #{mode}")
          error = trust_error(c)
          assert error =~ event
          assert error =~ "event_code"
          assert error =~ c.outsider
          output = doctor_refusal(c)
          assert output =~ event
          assert output =~ "event_code"
          assert output =~ c.outsider
        end

        sql!(
          c.outsider_repo,
          "CREATE OR REPLACE FUNCTION #{function}() RETURNS event_trigger LANGUAGE plpgsql AS 'BEGIN RAISE NOTICE ''event identity %'', current_user; END'"
        )

        sql!(Repo, "ALTER EVENT TRIGGER #{q(event)} ENABLE")
        notices = event_notices(c, @event)
        expected = if @event == "login", do: c.runtime, else: c.migrator
        assert notices =~ "event identity #{expected}"
        superuser = scalar(Repo, "SELECT current_user")
        sql!(Repo, "ALTER FUNCTION #{function}() OWNER TO #{q(superuser)}")
        assert trust?(c)
        assert doctor_ok?(c)
      after
        sql!(Repo, "DROP EVENT TRIGGER IF EXISTS #{q(event)}")
        sql!(Repo, "DROP FUNCTION IF EXISTS #{function}()")
      end
    end
  end

  for membership <- [
        "INHERIT FALSE, SET TRUE, ADMIN FALSE",
        "INHERIT FALSE, SET FALSE, ADMIN TRUE"
      ] do
    @membership membership
    @tag defects_batch: true
    test "maintenance owner equivalence refuses #{membership}", c do
      sql!(Repo, "GRANT #{q(c.owner)} TO #{q(c.maintainer)} WITH #{@membership}")

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: runtime or maintenance owner membership"
      )
    end
  end

  @tag defects_batch: true
  @tag doctor_runtime_mutation: true
  test "live doctor refuses its cold runtime role's owner equivalence", c do
    # Outside the maintainer tree: trust cannot identify this role as a runtime.
    sql!(Repo, "GRANT #{q(c.owner)} TO #{q(c.outsider)} WITH INHERIT TRUE, SET TRUE")
    {:ok, cold} = subject(c.outsider)
    assert trust?(c)
    output = doctor_refusal(%{c | runtime_repo: cold})
    assert output =~ c.outsider
    assert output =~ "owner-equivalent"
  end

  defp grant_guard_dependencies!(c) do
    routines = Postgres.routine_schema(c.schema)
    sql!(c.owner_repo, "GRANT USAGE ON SCHEMA #{q(routines)} TO #{q(c.outsider)}")

    sql!(
      c.owner_repo,
      "GRANT EXECUTE ON FUNCTION #{q(routines)}.ash_onetime_cleanup_eligible(timestamptz) TO #{q(c.outsider)}"
    )
  end

  defp install_facts!(c) do
    migrate_source!(
      c.owner_repo,
      c.schema,
      Generator.render_fact_tables(Repo, fact_tables: ["audit_facts"])
    )
  end

  defp package_triggers(c) do
    SQL.query!(
      Repo,
      """
      SELECT r.relname,t.tgname,t.tgenabled::text FROM pg_trigger t
      JOIN pg_class r ON r.oid=t.tgrelid JOIN pg_proc p ON p.oid=t.tgfoid
      WHERE r.relnamespace=to_regnamespace($1::text) AND p.proname IN
        ('ash_onetime_guard_idempotency_delete','ash_onetime_guard_nonce_delete','ash_onetime_fact_append_only')
      ORDER BY r.relname,t.tgname
      """,
      [c.schema]
    ).rows
  end

  defp seed_guard_rows!(c) do
    StoreCase.restore_fixture!(Repo, """
    WITH claim AS (
      INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")}
      (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at)
      VALUES (gen_random_uuid(),'guard',sha256('operation'),sha256('scope'),sha256('key'),sha256('body'),'complete',current_date,'test',sha256('response'),now(),now()+interval '1 day',now()) RETURNING id
    ) INSERT INTO #{rel(c, "ash_onetime_response_payloads")} VALUES ('guard',current_date,(SELECT id FROM claim),decode('beef','hex'))
    """)

    sql!(
      Repo,
      "INSERT INTO #{rel(c, "ash_onetime_nonce_claims")} (id,logical_partition,operation_hash,scope_hash,key_hash,issued_at,verifier_id,admitted_at,retain_until,inserted_at) VALUES (gen_random_uuid(),'guard',sha256('operation'),sha256('scope'),sha256('key'),now(),'test',now(),now()+interval '1 day',now())"
    )

    if scalar(Repo, "SELECT to_regclass(#{literal(q(c.schema) <> ".audit_facts")}) IS NOT NULL") do
      sql!(
        c.owner_repo,
        "INSERT INTO #{rel(c, "audit_facts")} (tenant,type,tags) VALUES ('guard','test',ARRAY['test'])"
      )
    end
  end

  defp trust?(c),
    do:
      scalar(
        c.runtime_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
      )

  defp trust_error(c),
    do:
      scalar(
        c.runtime_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->>'trust_error'"
      ) || "accepted"

  defp rollback_control(repo, ddl, table) do
    sql!(repo, "BEGIN")

    try do
      sql!(repo, ddl)
      refute scalar(repo, "SELECT to_regclass(#{literal(table)}) IS NOT NULL")
    after
      sql!(repo, "ROLLBACK")
    end

    assert scalar(repo, "SELECT to_regclass(#{literal(table)}) IS NOT NULL")
  end

  defp doctor_refusal(c) do
    previous = Repo.put_dynamic_repo(c.runtime_repo)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/check\(s\) failed/, fn ->
          Doctor.run([
            "--repo",
            inspect(Repo),
            "--prefix",
            c.schema,
            "--live"
          ])
        end
      end)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp doctor_ok?(c) do
    previous = Repo.put_dynamic_repo(c.runtime_repo)

    try do
      Doctor.run(["--repo", inspect(Repo), "--prefix", c.schema, "--live"]) ==
        :ok
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp event_notices(c, event) do
    {login, password} =
      Process.get(
        {__MODULE__, :credential, if(event == "login", do: c.runtime, else: c.migrator)}
      )

    options = ExternalPeer.database_options()

    ddl =
      if event == "login",
        do: "SELECT 1",
        else: "CREATE TABLE #{rel(c, "event_control")}(id integer)"

    {output, 0} =
      System.cmd(postgres_tool!("psql"), ["-X", "-w", "-v", "ON_ERROR_STOP=1", "-c", ddl],
        env: [
          {"PGHOST", options[:hostname]},
          {"PGPORT", to_string(options[:port])},
          {"PGDATABASE", options[:database]},
          {"PGUSER", login},
          {"PGPASSWORD", password}
        ],
        stderr_to_stdout: true
      )

    output
  end

  defp with_public_install(c, callback) do
    database = "ash_onetime_containment_#{System.unique_integer([:positive])}"
    sql!(Repo, "CREATE DATABASE #{q(database)}")
    repos = []
    Process.put({__MODULE__, :public_repos}, repos)

    try do
      for {key, role} <- [owner_repo: c.owner, runtime_repo: c.runtime] do
        {login, password} = Process.get({__MODULE__, :credential, role})

        url =
          System.fetch_env!("DATABASE_URL")
          |> URI.parse()
          |> Map.put(:path, "/" <> database)
          |> Map.put(:userinfo, login <> ":" <> password)
          |> URI.to_string()

        {:ok, repo} =
          Repo.start_link(
            name: nil,
            url: url,
            pool: DBConnection.ConnectionPool,
            pool_size: 2,
            after_connect: fn conn -> Postgrex.query!(conn, "SET ROLE #{q(role)}", []) end
          )

        Process.unlink(repo)

        Process.put({__MODULE__, :public_repos}, [
          {key, repo} | Process.get({__MODULE__, :public_repos})
        ])
      end

      public =
        Map.merge(c, Map.new(Process.get({__MODULE__, :public_repos})))
        |> Map.merge(%{schema: "public", database: database})

      sql!(Repo, "ALTER DATABASE #{q(database)} OWNER TO #{q(c.owner)}")

      migrate_source!(
        public.owner_repo,
        "public",
        Generator.render(Repo, maintenance_role: c.maintainer)
      )

      callback.(public)
    after
      for {_key, repo} <- Process.delete({__MODULE__, :public_repos}), do: GenServer.stop(repo)
      sql!(Repo, "DROP DATABASE IF EXISTS #{q(database)} WITH (FORCE)")
    end
  end

  for grant <- [:outsider, :grant_option, :table_schema_name] do
    @grant grant
    @tag review_acl: true
    test "routine ACL audit distinguishes #{@grant}", c do
      assert scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'acl'"
             )

      case @grant do
        :outsider ->
          sql!(
            c.owner_repo,
            "GRANT EXECUTE ON FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(integer) TO #{q(c.outsider)}"
          )

        :grant_option ->
          sql!(
            c.owner_repo,
            "GRANT EXECUTE ON FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(integer) TO #{q(c.maintainer)} WITH GRANT OPTION"
          )

        :table_schema_name ->
          sql!(
            c.runtime_repo,
            "CREATE FUNCTION #{q(c.schema)}.ash_onetime_cleanup_nonce(integer) RETURNS bigint LANGUAGE sql AS 'SELECT 0::bigint'"
          )
      end

      assert scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'acl'"
             ) == (@grant == :table_schema_name)
    end
  end

  @tag effective_authority_clean: true
  test "a clean install passes the effective authority audit", c do
    assert scalar(
             c.runtime_repo,
             "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
           )

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0
  end

  for {predefined, privilege, membership} <- [
        {"pg_write_all_data", "UPDATE", :inherit},
        {"pg_read_all_data", "SELECT", :inherit},
        {"pg_write_all_data", "UPDATE", :set},
        {"pg_read_all_data", "SELECT", :set},
        {"pg_write_all_data", "UPDATE", :group}
      ] do
    @predefined predefined
    @privilege privilege
    @membership membership
    @tag effective_relation_authority_mutation: true
    test "effective owner-only authority refuses #{@predefined} via #{@membership}", c do
      group = "ao_authority_#{System.unique_integer([:positive])}"
      holder = if @membership == :group, do: group, else: @predefined

      options =
        if @membership == :inherit, do: "INHERIT TRUE, SET TRUE", else: "INHERIT FALSE, SET TRUE"

      if @membership == :group do
        sql!(Repo, "CREATE ROLE #{q(group)} NOLOGIN NOSUPERUSER NOBYPASSRLS")
      end

      try do
        if @membership == :group do
          sql!(Repo, "GRANT #{@predefined} TO #{q(group)} WITH INHERIT FALSE, SET TRUE")
        end

        sql!(Repo, "GRANT #{q(holder)} TO #{q(c.outsider)} WITH #{options}")
        {:ok, cold} = subject(c.outsider)
        assert scalar(cold, "SELECT pg_has_role(current_user,#{literal(@predefined)},'SET')")

        try do
          # SET-only paths do not inherit the privilege. Verify the reachable holder
          # really has it on a cold connection, then return to the login subject.
          sql!(cold, "SET ROLE #{@predefined}")

          assert scalar(
                   cold,
                   "SELECT has_table_privilege(current_user,'#{rel(c, "ash_onetime_maintenance_runs")}',#{literal(@privilege)})"
                 )
        after
          sql!(cold, "RESET ROLE")
        end

        refute scalar(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
               )

        assert_refusal(
          c,
          "ash_onetime_cleanup_nonce",
          "1",
          "untrusted_dependency: effective relation privilege"
        )
      after
        sql!(Repo, "REVOKE #{q(holder)} FROM #{q(c.outsider)}")

        if @membership == :group do
          sql!(Repo, "REVOKE #{@predefined} FROM #{q(group)}")
          sql!(Repo, "DROP ROLE #{q(group)}")
        end
      end
    end
  end

  for membership <- [:direct, :group] do
    @membership membership
    @tag effective_replication_authority_mutation: true
    test "effective replication parameter authority refuses #{@membership} SET grant", c do
      group = "ao_replica_#{System.unique_integer([:positive])}"
      holder = if @membership == :group, do: group, else: c.outsider

      if @membership == :group do
        sql!(Repo, "CREATE ROLE #{q(group)} NOLOGIN NOSUPERUSER NOBYPASSRLS")
      end

      try do
        sql!(Repo, "GRANT SET ON PARAMETER session_replication_role TO #{q(holder)}")

        if @membership == :group do
          sql!(Repo, "GRANT #{q(group)} TO #{q(c.outsider)} WITH INHERIT FALSE, SET TRUE")
        end

        {:ok, cold} = subject(c.outsider)

        try do
          sql!(cold, "SET ROLE #{q(holder)}")

          assert scalar(
                   cold,
                   "SELECT has_parameter_privilege(current_user,'session_replication_role','SET')"
                 )

          sql!(cold, "SET session_replication_role = replica")
          assert scalar(cold, "SHOW session_replication_role") == "replica"
        after
          sql!(cold, "SET session_replication_role = origin")
          sql!(cold, "RESET ROLE")
        end

        refute scalar(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
               )

        assert_refusal(
          c,
          "ash_onetime_cleanup_nonce",
          "1",
          "untrusted_dependency: effective session_replication_role privilege"
        )
      after
        sql!(Repo, "REVOKE SET ON PARAMETER session_replication_role FROM #{q(holder)}")

        if @membership == :group do
          sql!(Repo, "REVOKE #{q(group)} FROM #{q(c.outsider)}")
          sql!(Repo, "DROP ROLE #{q(group)}")
        end
      end
    end
  end

  @tag effective_review: true
  @tag effective_cluster_isolation_mutation: true
  test "cluster grant isolation refuses an unproven server", _c do
    variables = [
      "ASH_ONETIME_TEST_SERVER",
      "GITHUB_ACTIONS",
      "GITHUB_RUN_ID",
      "GITHUB_RUN_ATTEMPT"
    ]

    previous = Map.new(variables, &{&1, System.get_env(&1)})
    [[hostname]] = SQL.query!(Repo, "SELECT pg_read_file('/etc/hostname')", []).rows
    server = String.trim(hostname)

    try do
      Enum.each(variables, &System.delete_env/1)

      assert_raise RuntimeError, ~r/cluster-wide grants require a proven per-run/, fn ->
        ClusterIsolation.assert_per_run_server!()
      end

      System.put_env("ASH_ONETIME_TEST_SERVER", "ao-not-this-server")

      assert_raise RuntimeError, ~r/cluster-wide grants require a proven per-run/, fn ->
        ClusterIsolation.assert_per_run_server!()
      end

      System.put_env("ASH_ONETIME_TEST_SERVER", server)
      System.put_env("GITHUB_ACTIONS", "true")
      System.put_env("GITHUB_RUN_ID", "0")
      System.put_env("GITHUB_RUN_ATTEMPT", "0")

      assert_raise RuntimeError, ~r/cluster-wide grants require a proven per-run/, fn ->
        ClusterIsolation.assert_per_run_server!()
      end
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  @tag effective_review: true
  test "ADMIN-only membership can grant itself SET on PG18", c do
    try do
      sql!(
        Repo,
        "GRANT pg_write_all_data TO #{q(c.outsider)} WITH ADMIN TRUE, INHERIT FALSE, SET FALSE"
      )

      {:ok, cold} = subject(c.outsider)
      assert scalar(cold, "SELECT pg_has_role(current_user,'pg_write_all_data','MEMBER')")
      refute scalar(cold, "SELECT pg_has_role(current_user,'pg_write_all_data','USAGE')")
      refute scalar(cold, "SELECT pg_has_role(current_user,'pg_write_all_data','SET')")
      sql!(cold, "GRANT pg_write_all_data TO #{q(c.outsider)} WITH SET TRUE")
      assert scalar(cold, "SELECT pg_has_role(current_user,'pg_write_all_data','SET')")
      IO.puts("PG18 ADMIN_SELF_GRANT set_before=false set_after=true")
    after
      sql!(Repo, "REVOKE pg_write_all_data FROM #{q(c.outsider)} CASCADE")
    end
  end

  for holder <- [:predefined, :group] do
    @holder holder
    @tag effective_review: true
    @tag effective_admin_authority_mutation: true
    test "effective authority refuses ADMIN-only #{@holder} membership", c do
      with_authority_group(fn group ->
        holder = if @holder == :predefined, do: "pg_write_all_data", else: group

        if @holder == :group do
          sql!(
            c.owner_repo,
            "GRANT TRUNCATE ON #{rel(c, "ash_onetime_nonce_claims")} TO #{q(group)}"
          )
        end

        try do
          sql!(
            Repo,
            "GRANT #{q(holder)} TO #{q(c.outsider)} WITH ADMIN TRUE, INHERIT FALSE, SET FALSE"
          )

          {:ok, cold} = subject(c.outsider)
          assert scalar(cold, "SELECT pg_has_role(current_user,#{literal(holder)},'MEMBER')")
          refute scalar(cold, "SELECT pg_has_role(current_user,#{literal(holder)},'USAGE')")
          refute scalar(cold, "SELECT pg_has_role(current_user,#{literal(holder)},'SET')")

          refute scalar(
                   c.runtime_repo,
                   "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
                 )

          assert_refusal(
            c,
            "ash_onetime_cleanup_nonce",
            "1",
            "untrusted_dependency: effective relation privilege"
          )
        after
          sql!(Repo, "REVOKE #{q(holder)} FROM #{q(c.outsider)} CASCADE")
        end
      end)
    end
  end

  @tag effective_review: true
  @tag effective_unreachable_authority_mutation: true
  test "effective authority refuses an unreachable group holder", c do
    with_authority_group(fn group ->
      sql!(c.owner_repo, "GRANT TRUNCATE ON #{rel(c, "ash_onetime_nonce_claims")} TO #{q(group)}")
      {:ok, cold} = subject(c.outsider)
      refute scalar(cold, "SELECT pg_has_role(current_user,#{literal(group)},'MEMBER')")

      assert scalar(
               Repo,
               "SELECT has_table_privilege(#{literal(group)},'#{rel(c, "ash_onetime_nonce_claims")}','TRUNCATE')"
             )

      refute scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
             )

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: effective relation privilege"
      )
    end)
  end

  @tag effective_review: true
  @tag effective_proxy_authority_mutation: true
  test "effective authority refuses an unreachable holder exposed through a PUBLIC view", c do
    with_authority_group(fn group ->
      sql!(
        c.owner_repo,
        "GRANT SELECT ON #{rel(c, "ash_onetime_maintenance_runs")} TO #{q(group)}"
      )

      sql!(Repo, "GRANT USAGE ON SCHEMA #{q(c.schema)} TO #{q(group)}")

      sql!(
        Repo,
        "CREATE VIEW #{q(c.schema)}.authority_proxy WITH (security_invoker=false) AS SELECT step FROM #{rel(c, "ash_onetime_maintenance_runs")}"
      )

      sql!(Repo, "ALTER VIEW #{q(c.schema)}.authority_proxy OWNER TO #{q(group)}")

      try do
        sql!(Repo, "GRANT SELECT ON #{q(c.schema)}.authority_proxy TO PUBLIC")
        {:ok, cold} = subject(c.outsider)
        refute scalar(cold, "SELECT pg_has_role(current_user,#{literal(group)},'MEMBER')")

        refute scalar(
                 cold,
                 "SELECT has_table_privilege(current_user,'#{rel(c, "ash_onetime_maintenance_runs")}','SELECT')"
               )

        assert scalar(cold, "SELECT count(*) FROM #{q(c.schema)}.authority_proxy") == 5

        refute scalar(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
               )

        assert_refusal(
          c,
          "ash_onetime_cleanup_nonce",
          "1",
          "untrusted_dependency: effective relation privilege"
        )
      after
        sql!(Repo, "DROP VIEW #{q(c.schema)}.authority_proxy")
      end
    end)
  end

  for membership <- [:inherit, :admin] do
    @membership membership
    @tag effective_review: true
    @tag effective_subscription_role_mutation: true
    test "effective authority refuses pg_create_subscription via #{@membership}", c do
      options =
        if @membership == :admin,
          do: "ADMIN TRUE, INHERIT FALSE, SET FALSE",
          else: "INHERIT TRUE, SET TRUE"

      try do
        sql!(Repo, "GRANT pg_create_subscription TO #{q(c.outsider)} WITH #{options}")
        {:ok, cold} = subject(c.outsider)
        assert scalar(cold, "SELECT pg_has_role(current_user,'pg_create_subscription','MEMBER')")

        refute scalar(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
               )

        assert_refusal(
          c,
          "ash_onetime_cleanup_nonce",
          "1",
          "untrusted_dependency: effective replication privilege for role #{c.outsider}"
        )
      after
        sql!(Repo, "REVOKE pg_create_subscription FROM #{q(c.outsider)} CASCADE")
      end
    end
  end

  @tag effective_review: true
  @tag effective_subscription_owner_mutation: true
  test "effective authority refuses an existing untrusted subscription owner", c do
    subscription = "ao_subscription_#{System.unique_integer([:positive])}"
    database = scalar(Repo, "SELECT current_database()")

    try do
      sql!(Repo, "GRANT pg_create_subscription TO #{q(c.outsider)}")
      sql!(Repo, "GRANT CREATE ON DATABASE #{q(database)} TO #{q(c.outsider)}")
      {:ok, cold} = subject(c.outsider)

      sql!(
        cold,
        "CREATE SUBSCRIPTION #{q(subscription)} CONNECTION 'host=127.0.0.1 dbname=unused password=unused' PUBLICATION unused WITH (connect=false, enabled=false, create_slot=false, slot_name=NONE)"
      )

      sql!(Repo, "REVOKE pg_create_subscription FROM #{q(c.outsider)}")
      sql!(Repo, "REVOKE CREATE ON DATABASE #{q(database)} FROM #{q(c.outsider)}")

      assert scalar(
               Repo,
               "SELECT subowner=#{literal(c.outsider)}::regrole AND NOT subenabled AND subslotname IS NULL FROM pg_subscription WHERE subname=#{literal(subscription)}"
             )

      refute scalar(cold, "SELECT pg_has_role(current_user,'pg_create_subscription','MEMBER')")

      refute scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
             )

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: effective subscription privilege for role #{c.outsider}"
      )
    after
      sql!(Repo, "DROP SUBSCRIPTION IF EXISTS #{q(subscription)}")
      sql!(Repo, "REVOKE pg_create_subscription FROM #{q(c.outsider)}")
      sql!(Repo, "REVOKE CREATE ON DATABASE #{q(database)} FROM #{q(c.outsider)}")
    end
  end

  @tag effective_review: true
  @tag effective_alter_system_mutation: true
  test "effective parameter authority refuses ALTER SYSTEM without SET", c do
    try do
      sql!(Repo, "GRANT ALTER SYSTEM ON PARAMETER session_replication_role TO #{q(c.outsider)}")
      {:ok, cold} = subject(c.outsider)

      refute scalar(
               cold,
               "SELECT has_parameter_privilege(current_user,'session_replication_role','SET')"
             )

      assert scalar(
               cold,
               "SELECT has_parameter_privilege(current_user,'session_replication_role','ALTER SYSTEM')"
             )

      assert scalar(
               cold,
               "SELECT has_parameter_privilege(current_user,'session_replication_role','SET, ALTER SYSTEM')"
             )

      IO.puts("PG18 PARAMETER_PRIVILEGES set=false alter_system=true combined=true")

      refute scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
             )

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: effective session_replication_role privilege"
      )
    after
      sql!(
        Repo,
        "REVOKE ALTER SYSTEM ON PARAMETER session_replication_role FROM #{q(c.outsider)}"
      )
    end
  end

  for {table, column} <- [
        {"ash_onetime_idempotency_claims", "id"},
        {"ash_onetime_nonce_claims", "id"},
        {"ash_onetime_response_payloads", "claim_id"}
      ],
      privilege <- ["TRIGGER", "TRUNCATE", "REFERENCES", "REFERENCES (#{column})"] do
    @table table
    @column column
    @privilege privilege
    @tag effective_review: true
    @tag effective_root_authority_mutation: true
    test "effective root authority refuses #{@privilege} on #{@table}", c do
      with_authority_group(fn group ->
        sql!(c.owner_repo, "GRANT USAGE ON SCHEMA #{q(c.schema)} TO #{q(group)}")

        sql!(
          c.owner_repo,
          "GRANT #{@privilege} ON #{rel(c, @table)} TO #{q(group)}"
        )

        sql!(Repo, "GRANT #{q(group)} TO #{q(c.outsider)} WITH INHERIT FALSE, SET TRUE")
        {:ok, cold} = subject(c.outsider)

        try do
          sql!(cold, "SET ROLE #{q(group)}")

          check =
            if @privilege == "REFERENCES (#{@column})",
              do:
                "has_column_privilege(current_user,'#{rel(c, @table)}','#{@column}','REFERENCES')",
              else: "has_table_privilege(current_user,'#{rel(c, @table)}',#{literal(@privilege)})"

          assert scalar(cold, "SELECT #{check}")
        after
          sql!(cold, "RESET ROLE")
        end

        refute scalar(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
               )

        assert_refusal(
          c,
          "ash_onetime_cleanup_nonce",
          "1",
          "untrusted_dependency: effective relation privilege"
        )
      end)
    end
  end

  @tag hash_partitions: 4
  @tag effective_review: true
  @tag effective_select_safety_mutation: true
  test "SELECT stays refused because existing children do not share root RLS and policies", c do
    root = rel(c, "ash_onetime_nonce_claims")

    [[child]] =
      SQL.query!(
        Repo,
        "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent=$1::text::regclass LIMIT 1",
        [root]
      ).rows

    assert SQL.query!(
             Repo,
             "SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid=$1::text::regclass",
             [root]
           ).rows == [[true, true]]

    assert SQL.query!(
             Repo,
             "SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid=$1::text::regclass",
             [child]
           ).rows == [[false, false]]

    assert scalar(
             Repo,
             "SELECT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid='#{root}'::regclass AND polname='runtime_tenant')"
           )

    refute scalar(
             Repo,
             "SELECT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid='#{child}'::regclass AND polname='runtime_tenant')"
           )

    IO.puts(
      "PG18 CHILD_POLICY_PARITY existing_hash_child_rls=false root_rls=true runtime_policy_copied=false"
    )

    try do
      sql!(Repo, "GRANT pg_read_all_data TO #{q(c.outsider)}")
      {:ok, cold} = subject(c.outsider)
      assert scalar(cold, "SELECT has_table_privilege(current_user,'#{child}','SELECT')")

      refute scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->'trust'"
             )

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: effective relation privilege"
      )
    after
      sql!(Repo, "REVOKE pg_read_all_data FROM #{q(c.outsider)}")
    end
  end

  @tag review_set_maintain: true
  @tag review_inactive_runtime: true
  test "inactive NOLOGIN runtime member with SET only MAINTAIN refuses maintenance", c do
    sql!(Repo, "GRANT pg_maintain TO #{q(c.runtime)} WITH INHERIT FALSE, SET TRUE")
    sql!(Repo, "ALTER ROLE #{q(c.runtime)} NOLOGIN")

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} =
             SQL.query(c.owner_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)", [])

    assert message =~ maintain_diagnostic(c, "pg_maintain")
  end

  for holder <- [:pg_maintain, :nologin] do
    @holder holder
    @tag review_set_maintain: true
    test "SET only MAINTAIN through #{@holder} refuses maintenance", c do
      holder = if @holder == :pg_maintain, do: "pg_maintain", else: c.outsider

      if @holder == :nologin do
        sql!(Repo, "ALTER ROLE #{q(holder)} NOLOGIN")

        sql!(
          c.owner_repo,
          "GRANT MAINTAIN ON #{rel(c, "ash_onetime_nonce_claims")} TO #{q(holder)}"
        )
      end

      sql!(c.owner_repo, "GRANT USAGE ON SCHEMA #{q(c.schema)} TO #{q(holder)}")
      sql!(Repo, "GRANT #{q(holder)} TO #{q(c.runtime)} WITH INHERIT FALSE, SET TRUE")

      refute scalar(
               c.runtime_repo,
               "SELECT has_table_privilege(current_user,'#{rel(c, "ash_onetime_nonce_claims")}','MAINTAIN')"
             )

      assert scalar(c.runtime_repo, "SELECT pg_has_role(current_user,#{literal(holder)},'SET')")
      sql!(c.runtime_repo, "SET ROLE #{q(holder)}")

      try do
        assert %Postgrex.Result{messages: []} =
                 sql!(c.runtime_repo, "ANALYZE #{rel(c, "ash_onetime_nonce_claims")}")
      after
        sql!(c.runtime_repo, "RESET ROLE")
      end

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        maintain_diagnostic(c, holder)
      )
    end
  end

  @tag legacy_install: true
  @tag review_install_mode: true
  test "upgrade with missing old routines refuses an existing hostile trigger", c do
    sql!(
      c.owner_repo,
      "CREATE TABLE #{rel(c, "ash_onetime_response_payloads_" <> (month_start(0) |> String.slice(0, 7) |> String.replace("-", "_")))} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{month_start(0)}') TO ('#{month_start(1)}')"
    )

    for [signature] <-
          SQL.query!(
            c.owner_repo,
            "SELECT p.oid::regprocedure::text FROM pg_proc p WHERE p.pronamespace=$1::text::regnamespace AND p.proname LIKE 'ash_onetime_%'",
            [c.schema]
          ).rows do
      sql!(c.owner_repo, "DROP FUNCTION IF EXISTS #{signature} CASCADE")
    end

    sql!(
      c.owner_repo,
      "CREATE FUNCTION #{rel(c, "hostile_trigger")}() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN OLD; END'"
    )

    sql!(
      c.owner_repo,
      "CREATE TRIGGER extra BEFORE DELETE ON #{rel(c, "ash_onetime_nonce_claims")} FOR EACH ROW EXECUTE FUNCTION #{rel(c, "hostile_trigger")}()"
    )

    error = assert_raise Postgrex.Error, fn -> with_upgrade(c, fn -> :ok end) end

    assert error.postgres.message ==
             "untrusted_dependency: upgrade relation shape ash_onetime_nonce_claims"
  end

  @tag maintenance_functions_mutation: true
  test "all maintenance entry points are owner definers with a fixed search path", c do
    rows =
      SQL.query!(
        c.owner_repo,
        """
        SELECT p.proname, p.prosecdef, p.proconfig, r.rolname
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE n.nspname = $1 AND p.proname = ANY($2) ORDER BY p.proname
        """,
        [routine_schema(c.schema), entry_points()]
      ).rows

    assert length(rows) == length(entry_points())

    for [_name, definer, config, owner] <- rows do
      assert definer

      assert config == [
               "search_path=pg_catalog, pg_temp",
               "DateStyle=ISO, YMD",
               "row_security=on",
               "lock_timeout=5s"
             ]

      assert owner == c.owner
    end
  end

  @tag routine_lock_catalog_mutation: true
  test "top-level routines pin lock_timeout and statement helpers inherit it", c do
    inside =
      ~w(ash_onetime_cleanup_eligible ash_onetime_guard_idempotency_delete ash_onetime_guard_nonce_delete ash_onetime_guard_idempotency_update ash_onetime_bound_effect_outcome ash_onetime_claim_visible ash_onetime_maintenance_active ash_onetime_guard_effect_outcome)

    rows =
      SQL.query!(
        c.owner_repo,
        "SELECT p.proname,p.proconfig FROM pg_proc p WHERE p.pronamespace=$1::text::regnamespace ORDER BY p.proname",
        [routine_schema(c.schema)]
      ).rows

    assert rows != []
    assert Enum.sort(for [name, _] <- rows, name in inside, do: name) == Enum.sort(inside)

    for [name, settings] <- rows do
      assert "search_path=pg_catalog, pg_temp" in settings
      assert "DateStyle=ISO, YMD" in settings

      if name in inside do
        refute Enum.any?(settings, &String.starts_with?(&1, "lock_timeout="))
      else
        assert "lock_timeout=5s" in settings
      end
    end
  end

  @tag quoted_schema: true
  test "schema quotes and dollar delimiters stay data during function creation and rolling", c do
    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(24)") >
             0

    assert scalar(
             c.runtime_repo,
             "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->>'trust'"
           ) == "true"
  end

  @tag legacy_install: true
  @tag revision7: true
  test "maintenance upgrade restores the captured definitions and grants", c do
    sql!(
      c.owner_repo,
      "GRANT EXECUTE ON FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(integer) TO #{q(c.owner)}, #{q(c.runtime)}, #{q(c.maintainer)}, #{q(c.outsider)}"
    )

    sql!(
      c.owner_repo,
      "GRANT SELECT (encoded_response) ON #{rel(c, "ash_onetime_response_payloads_default")} TO #{q(c.runtime)} WITH GRANT OPTION"
    )

    sql!(
      c.owner_repo,
      "GRANT SELECT ON #{rel(c, "ash_onetime_nonce_claims")} TO #{q(c.runtime)} WITH GRANT OPTION"
    )

    sql!(
      c.runtime_repo,
      "GRANT SELECT ON #{rel(c, "ash_onetime_nonce_claims")} TO #{q(c.outsider)} WITH GRANT OPTION"
    )

    sql!(
      c.outsider_repo,
      "GRANT SELECT ON #{rel(c, "ash_onetime_nonce_claims")} TO #{q(c.maintainer)}"
    )

    original_acls = catalog_acls(c)

    original_definition =
      scalar(
        c.owner_repo,
        "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_cleanup_nonce")}(integer)'::regprocedure)"
      )

    source =
      Generator.render_maintenance_upgrade(Repo, prefix: c.schema, maintenance_role: c.maintainer)

    [{module, _}] = Code.compile_string(source)
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      assert :ok =
               Ecto.Migrator.up(Repo, 20_261_114_000_000, module, prefix: c.schema, log: false)

      assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               SQL.query(c.outsider_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)", [])

      refusal =
        assert_raise Postgrex.Error, fn ->
          Ecto.Migrator.down(Repo, 20_261_114_000_000, module, prefix: c.schema, log: false)
        end

      assert refusal.postgres.pg_code == "42501"
      IO.puts("DOWN_GRANTOR_WITHOUT_SET=42501; migration rolled back")

      assert scalar(
               c.owner_repo,
               "SELECT prosecdef FROM pg_proc WHERE oid='#{rel(c, "ash_onetime_cleanup_nonce")}(integer)'::regprocedure"
             )

      for grantor <- [c.runtime, c.outsider] do
        sql!(Repo, "GRANT #{q(grantor)} TO #{q(c.migrator)} WITH INHERIT FALSE, SET TRUE")
      end

      sql!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} NO FORCE ROW LEVEL SECURITY"
      )

      assert :ok =
               Ecto.Migrator.down(Repo, 20_261_114_000_000, module, prefix: c.schema, log: false)

      sql!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} FORCE ROW LEVEL SECURITY"
      )

      assert scalar(
               Repo,
               "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_cleanup_nonce")}(integer)'::regprocedure)"
             ) == original_definition

      assert catalog_acls(c) == original_acls
    after
      Repo.put_dynamic_repo(previous)
      :code.purge(module)
      :code.delete(module)
    end
  end

  @tag legacy_install: true
  test "upgrade refuses and names every policy that applies to the owner", c do
    for name <- ["first_policy", "second_policy"] do
      sql!(
        c.owner_repo,
        "CREATE POLICY #{name} ON #{rel(c, "ash_onetime_nonce_claims")} USING (true)"
      )
    end

    source =
      Generator.render_maintenance_upgrade(Repo, prefix: c.schema, maintenance_role: c.maintainer)

    [{module, _}] = Code.compile_string(source)
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      assert_raise Postgrex.Error, ~r/maintenance_blinded:.*first_policy.*second_policy/, fn ->
        Ecto.Migrator.up(Repo, 20_261_114_000_000, module, prefix: c.schema, log: false)
      end
    after
      Repo.put_dynamic_repo(previous)
      :code.purge(module)
      :code.delete(module)
    end
  end

  @tag legacy_install: true
  @tag transfer: true
  @tag revision7: true
  test "a migrator with SET but no INHERIT transfers functions to a NOLOGIN owner", c do
    sql!(Repo, "GRANT #{q(c.owner)} TO #{q(c.migrator)} WITH INHERIT FALSE, SET TRUE")
    sql!(Repo, "GRANT USAGE, CREATE ON SCHEMA #{q(c.schema)} TO #{q(c.migrator)}")
    sql!(Repo, "GRANT ALL ON TABLE #{rel(c, "schema_migrations")} TO #{q(c.migrator)}")

    for [signature] <-
          SQL.query!(
            Repo,
            "SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=$1",
            [c.schema]
          ).rows do
      sql!(Repo, "ALTER FUNCTION #{signature} OWNER TO #{q(c.migrator)}")
    end

    {:ok, migrator_repo} = subject(c.migrator, 2)

    source =
      Generator.render_maintenance_upgrade(Repo, prefix: c.schema, maintenance_role: c.maintainer)

    [{module, _}] = Code.compile_string(source)
    previous = Repo.put_dynamic_repo(migrator_repo)

    try do
      assert :ok =
               Ecto.Migrator.up(Repo, 20_261_114_000_000, module, prefix: c.schema, log: false)

      assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

      sql!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} NO FORCE ROW LEVEL SECURITY"
      )

      assert :ok =
               Ecto.Migrator.down(Repo, 20_261_114_000_000, module, prefix: c.schema, log: false)

      sql!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} FORCE ROW LEVEL SECURITY"
      )

      assert scalar(
               migrator_repo,
               "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid='#{rel(c, "ash_onetime_cleanup_nonce")}(integer)'::regprocedure"
             ) == c.migrator
    after
      Repo.put_dynamic_repo(previous)
      :code.purge(module)
      :code.delete(module)
    end
  end

  test "runtime without a tenant cleans every tenant under FORCE RLS", c do
    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_nonce_claims")} ENABLE ROW LEVEL SECURITY"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_nonce_claims")} FORCE ROW LEVEL SECURITY"
    )

    sql!(
      c.owner_repo,
      "CREATE POLICY tenant ON #{rel(c, "ash_onetime_nonce_claims")} TO #{q(c.runtime)} USING (logical_partition = current_setting('ash_onetime.tenant', true))"
    )

    for tenant <- ["first", "second"] do
      sql!(Repo, """
      INSERT INTO #{rel(c, "ash_onetime_nonce_claims")}
        (id, logical_partition, operation_hash, scope_hash, key_hash, issued_at,
         verifier_id, admitted_at, retain_until, inserted_at)
      VALUES (gen_random_uuid(), '#{tenant}', decode(repeat('01',32),'hex'),
        decode(repeat('02',32),'hex'), decode(repeat('03',32),'hex'),
        now()-interval '3 days', 'test', now()-interval '3 days',
        now()-interval '2 days', now()-interval '3 days')
      """)

      sql!(
        Repo,
        "INSERT INTO #{rel(c, "ash_onetime_nonce_claims")} SELECT gen_random_uuid(),logical_partition,operation_hash,scope_hash,decode(repeat('04',32),'hex'),issued_at,expires_at,verifier_id,admitted_at,now()+interval '1 day',inserted_at FROM #{rel(c, "ash_onetime_nonce_claims")} WHERE logical_partition='#{tenant}'"
      )

      for {label, hold, retention} <- [
            {"expired", "NULL", "now()-interval '2 days'"},
            {"held", "'operation'", "now()-interval '2 days'"},
            {"retained", "NULL", "now()+interval '365 days'"}
          ] do
        StoreCase.restore_fixture!(Repo, """
        WITH claim AS (
          INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")}
          (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,hold_reference,admitted_at,retain_until,inserted_at)
          VALUES (gen_random_uuid(),'#{tenant}',sha256(convert_to('#{label}','UTF8')),decode(repeat('02',32),'hex'),decode(repeat('03',32),'hex'),decode(repeat('04',32),'hex'),'complete',current_date,'test',decode(repeat('05',32),'hex'),#{hold},now()-interval '3 days',#{retention},now()-interval '3 days') RETURNING id
        ) INSERT INTO #{rel(c, "ash_onetime_response_payloads")} SELECT '#{tenant}',current_date,id,decode('beef','hex') FROM claim
        """)
      end

      sql!(c.runtime_repo, "SET ash_onetime.tenant='#{tenant}'")

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             ) == 3

      assert scalar(c.runtime_repo, "SELECT count(*) FROM #{rel(c, "ash_onetime_nonce_claims")}") ==
               2
    end

    sql!(c.runtime_repo, "RESET ash_onetime.tenant")
    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_idempotency")}(100)") == 2
    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(100)") == 2
    assert scalar(Repo, "SELECT count(*) FROM #{rel(c, "ash_onetime_nonce_claims")}") == 2

    for tenant <- ["first", "second"] do
      sql!(c.runtime_repo, "SET ash_onetime.tenant='#{tenant}'")

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             ) == 2

      assert scalar(c.runtime_repo, "SELECT count(*) FROM #{rel(c, "ash_onetime_nonce_claims")}") ==
               1
    end
  end

  test "outside role is denied all maintenance functions and runs writes", c do
    for {name, args} <- calls() do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               SQL.query(c.outsider_repo, "SELECT #{rel(c, name)}(#{args})", [])
    end

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
             SQL.query(
               c.runtime_repo,
               "INSERT INTO #{rel(c, "ash_onetime_maintenance_runs")}(step) VALUES ('forged')",
               []
             )
  end

  test "Store maps definer EXECUTE refusal to maintenance_not_permitted", c do
    previous = Repo.put_dynamic_repo(c.outsider_repo)
    target = Postgres.for_repo(Repo, c.schema)
    Repo.put_dynamic_repo(previous)

    assert %Result{reason: :maintenance_not_permitted} =
             Postgres.roll_partitions(target, 24)
  end

  @tag prune_blocked: true
  test "Store surfaces a permanent prune refusal and retains its committed record", c do
    sql!(
      c.owner_repo,
      "CREATE TABLE #{rel(c, "old_other_owner")} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{month_start(-3)}') TO ('#{month_start(-2)}')"
    )

    sql!(
      c.owner_repo,
      "SELECT #{rel(c, "ash_onetime_maintenance_copy_policy")}('#{rel(c, "old_other_owner")}'::regclass)"
    )

    sql!(
      c.owner_repo,
      "SELECT #{rel(c, "ash_onetime_maintenance_reset_acl")}('#{rel(c, "old_other_owner")}'::regclass,true)"
    )

    event = "ao_reforce_" <> String.replace(c.schema, "ao_maintenance_", "")

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "reforce")}() RETURNS event_trigger LANGUAGE plpgsql AS #{literal("BEGIN IF current_setting('ash_onetime.reforce',true) IS DISTINCT FROM 'on' AND EXISTS(SELECT 1 FROM pg_event_trigger_ddl_commands() WHERE objid='" <> rel(c, "old_other_owner") <> "'::regclass) THEN PERFORM set_config('ash_onetime.reforce','on',true); ALTER TABLE " <> rel(c, "old_other_owner") <> " FORCE ROW LEVEL SECURITY; PERFORM set_config('ash_onetime.reforce','off',true); END IF; END")}"
    )

    sql!(
      Repo,
      "CREATE EVENT TRIGGER #{q(event)} ON ddl_command_end WHEN TAG IN ('ALTER TABLE') EXECUTE FUNCTION #{rel(c, "reforce")}()"
    )

    on_exit(fn -> sql!(Repo, "DROP EVENT TRIGGER #{q(event)}") end)
    previous = Repo.put_dynamic_repo(c.runtime_repo)

    try do
      assert %Result{reason: :prune_blocked, transaction: :committed} =
               Postgres.cleanup(
                 Postgres.for_repo(Repo, c.schema),
                 100,
                 8
               )
    after
      Repo.put_dynamic_repo(previous)
    end

    assert scalar(
             Repo,
             "SELECT last_refusals->>'force_reapplied' FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE step='prune'"
           ) == "1"
  end

  for {row, ddl} <- [
        {4, "CREATE RULE hostile AS ON DELETE TO @claims@ DO NOTHING"},
        {5, "CREATE POLICY hostile ON @claims@ USING (true)"},
        {6, "ALTER TABLE @claims@ ALTER COLUMN verifier_id SET DEFAULT 'hostile'"},
        {7, "ALTER TABLE @claims@ ADD COLUMN hostile integer GENERATED ALWAYS AS (1) STORED"},
        {8, "ALTER TABLE @claims@ ADD CHECK (true)"},
        {9, "CREATE TABLE @schema@.hostile (id uuid REFERENCES @claims@(id))"},
        {10, "ALTER TABLE @claims@ ADD UNIQUE (id,verifier_id)"},
        {11, "CREATE INDEX hostile ON @claims@ ((lower(verifier_id)))"},
        {12, "ALTER TABLE @claims@ ADD CHECK (1=1)"},
        {14, "CREATE CAST (integer AS bigint) WITHOUT FUNCTION"},
        {15, "CREATE TYPE @schema@.hostile (INPUT=int4in,OUTPUT=int4out)"},
        {16, "ALTER TABLE @claims@ ADD COLUMN hostile integer[]"},
        {17, "ALTER TABLE @claims@ ADD COLUMN hostile int4range"},
        {18, "ALTER TABLE @claims@ ADD COLUMN hostile text COLLATE \"C\""},
        {20,
         "ALTER FUNCTION @routines@.ash_onetime_guard_nonce_delete() SUPPORT varchar_support"},
        {21, "ALTER TABLE @claims@ ADD CHECK (length(verifier_id)>0)"},
        {22, "CREATE ACCESS METHOD ao_hostile TYPE INDEX HANDLER bthandler"},
        {23, "CREATE FOREIGN DATA WRAPPER ao_hostile"},
        {24,
         "CREATE EVENT TRIGGER ao_hostile ON ddl_command_end EXECUTE FUNCTION @schema@.ash_onetime_guard_nonce_delete()"},
        {25, "ALTER EXTENSION plpgsql ADD TABLE @claims@"},
        {26, "CREATE STATISTICS @schema@.hostile ON logical_partition,verifier_id FROM @claims@"},
        {27, "CREATE PUBLICATION ao_hostile FOR TABLE @claims@"},
        {28,
         "ALTER TABLE @schema@.ash_onetime_response_payloads ATTACH PARTITION @claims@ DEFAULT"},
        {29, "ALTER TABLE @claims@ ADD COLUMN hostile bigint GENERATED ALWAYS AS IDENTITY"},
        {30,
         "CREATE TRANSFORM FOR integer LANGUAGE plpgsql (FROM SQL WITH FUNCTION int4in(cstring))"},
        {31,
         "CREATE TEXT SEARCH TEMPLATE @schema@.hostile (INIT=dsimple_init,LEXIZE=dsimple_lexize)"}
      ] do
    @row row
    @ddl ddl
    @tag catalog_i: true
    test "Table 1 row #{@row}: runtime DDL refuses with 42501 and runs no owner code", c do
      ddl =
        @ddl
        |> String.replace("@claims@", rel(c, "ash_onetime_nonce_claims"))
        |> String.replace("@schema@", q(c.schema))
        |> String.replace("@routines@", q(routine_schema(c.schema)))

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               SQL.query(c.runtime_repo, ddl, [])

      assert scalar(
               Repo,
               "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
             ) == 0
    end
  end

  for {applicability, restrictive} <- [
        {"direct", false},
        {"public", false},
        {"member", false},
        {"direct", true}
      ] do
    @applicability applicability
    @restrictive restrictive
    @tag maintenance_policy_mutation: true
    test "owner policy contract refuses #{@applicability}, restrictive=#{@restrictive}", c do
      role =
        case @applicability do
          "direct" ->
            q(c.owner)

          "public" ->
            "PUBLIC"

          "member" ->
            sql!(Repo, "GRANT #{q(c.maintainer)} TO #{q(c.owner)}")
            q(c.maintainer)
        end

      sql!(
        c.owner_repo,
        "CREATE POLICY foreign_policy ON #{rel(c, "ash_onetime_nonce_claims")} AS #{if @restrictive, do: "RESTRICTIVE", else: "PERMISSIVE"} TO #{role} USING (true)"
      )

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "100",
        "maintenance_blinded: #{c.schema}.ash_onetime_nonce_claims.foreign_policy"
      )

      assert_refusal(
        c,
        "ash_onetime_cleanup_idempotency",
        "100",
        "maintenance_blinded: #{c.schema}.ash_onetime_nonce_claims.foreign_policy"
      )

      assert_refusal(
        c,
        "ash_onetime_reap_idempotency",
        "100,86400",
        "maintenance_blinded: #{c.schema}.ash_onetime_nonce_claims.foreign_policy"
      )

      assert scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->>'policy'"
             ) == "false"
    end
  end

  for defect <- [:missing, :select_only, :wrong_role, :wrong_using, :restrictive] do
    @defect defect
    @tag maintenance_policy_mutation: true
    test "maintenance policy contract refuses #{@defect}", c do
      table = rel(c, "ash_onetime_nonce_claims")
      sql!(c.owner_repo, "DROP POLICY ash_onetime_maintenance ON #{table}")

      unless @defect == :missing do
        command = if @defect == :select_only, do: "SELECT", else: "ALL"
        permissive = if @defect == :restrictive, do: "RESTRICTIVE", else: "PERMISSIVE"
        role = if @defect == :wrong_role, do: c.runtime, else: c.owner

        using =
          if @defect == :wrong_using,
            do: "false AND #{rel(c, "ash_onetime_maintenance_active")}()",
            else: "#{rel(c, "ash_onetime_maintenance_active")}()"

        check =
          if command == "ALL",
            do: " WITH CHECK (#{rel(c, "ash_onetime_maintenance_active")}())",
            else: ""

        sql!(
          c.owner_repo,
          "CREATE POLICY ash_onetime_maintenance ON #{table} AS #{permissive} FOR #{command} TO #{q(role)} USING (#{using})#{check}"
        )
      end

      reason =
        if @defect == :missing,
          do:
            "maintenance_blinded: #{c.schema}.ash_onetime_nonce_claims: missing ash_onetime_maintenance",
          else:
            "maintenance_blinded: #{c.schema}.ash_onetime_nonce_claims.ash_onetime_maintenance"

      assert_refusal(c, "ash_onetime_cleanup_nonce", "1", reason)
      assert_refusal(c, "ash_onetime_reap_idempotency", "1,86400", reason)

      refute scalar(
               Repo,
               "SELECT EXISTS(SELECT 1 FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE last_success_at IS NOT NULL)"
             )
    end
  end

  @tag maintenance_policy_mutation: true
  test "Table 1 row 5: an owner-applicable policy cannot execute runtime-owned code", c do
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "policy_probe")}() RETURNS boolean LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN true; END'"
    )

    sql!(
      c.owner_repo,
      "CREATE POLICY hostile_policy ON #{rel(c, "ash_onetime_nonce_claims")} AS RESTRICTIVE TO #{q(c.owner)} USING (#{rel(c, "policy_probe")}())"
    )

    assert_refusal(
      c,
      "ash_onetime_cleanup_nonce",
      "1",
      "maintenance_blinded: #{c.schema}.ash_onetime_nonce_claims.hostile_policy"
    )

    assert scalar(
             Repo,
             "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
           ) == 0
  end

  @tag builtin_dispatch: true
  @tag revision7: true
  @tag maintenance_shape_mutation: true
  test "a builtin SQL dispatcher cannot hide a runtime routine in a default", c do
    inner = rel(c, "dispatched")
    sql!(c.runtime_repo, "CREATE FUNCTION #{inner}() RETURNS integer LANGUAGE sql AS 'SELECT 0'")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_maintenance_runs")} ADD COLUMN extra_xml text DEFAULT pg_catalog.query_to_xml(#{literal("SELECT " <> inner <> "()")},false,true,'')::text"
    )

    sql!(
      c.runtime_repo,
      "CREATE OR REPLACE FUNCTION #{inner}() RETURNS integer LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); PERFORM set_config(''ash_onetime.probe_role'',current_user,false); RETURN 1; END'"
    )

    result = SQL.query(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)", [])
    observed = scalar(c.runtime_repo, "SELECT current_setting('ash_onetime.probe_role',true)")

    IO.puts(
      "BUILTIN_DISPATCH owner_executed=#{observed == c.owner} marker_locks=#{scalar(Repo, "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted")}"
    )

    assert match?({:error, %Postgrex.Error{postgres: %{pg_code: "P0001"}}}, result),
           "expected untrusted_dependency; owner executed through builtin SQL dispatcher: #{observed == c.owner}"

    {:error, %Postgrex.Error{postgres: %{message: message}}} = result
    assert message == "untrusted_dependency: relation shape ash_onetime_maintenance_runs"

    assert scalar(
             Repo,
             "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
           ) == 0
  end

  @tag status_readonly: true
  test "status reports facts in a read-only transaction", c do
    sql!(c.runtime_repo, "BEGIN READ ONLY")

    try do
      assert scalar(c.runtime_repo, "SHOW transaction_read_only") == "on"

      assert %{"checks" => %{"trust" => true, "policy" => true, "acl" => true}} =
               scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_maintenance_status")}()")
    after
      sql!(c.runtime_repo, "ROLLBACK")
    end
  end

  test "two installs record and report independently", c do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    second = "ao_second_#{suffix}"
    sql!(Repo, "CREATE SCHEMA #{q(second)} AUTHORIZATION #{q(c.owner)}")
    sql!(Repo, "GRANT USAGE ON SCHEMA #{q(second)} TO #{q(c.maintainer)}")

    source =
      Generator.render(Repo, maintenance_role: c.maintainer, prefix: second)
      |> String.replace(
        "AshOnetime.Test.Repo.Migrations.InstallAshOnetime",
        "AshOnetime.Test.SecondInstall#{suffix}"
      )

    [{module, _}] = Code.compile_string(source)

    on_exit(fn ->
      SQL.query!(Repo, "DROP SCHEMA #{q(second)} CASCADE", [])
      :code.purge(module)
      :code.delete(module)
      assert SQL.query!(Repo, "SELECT 1 FROM pg_namespace WHERE nspname=$1", [second]).rows == []
    end)

    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      assert :ok = Ecto.Migrator.up(Repo, 20_261_113_000_003, module, prefix: second, log: false)
    after
      Repo.put_dynamic_repo(previous)
    end

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

    assert scalar(
             c.runtime_repo,
             "SELECT #{q(routine_schema(second))}.ash_onetime_roll_payload_partitions(24::integer)"
           ) >
             0

    first_status = scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_maintenance_status")}()")

    second_status =
      scalar(
        c.runtime_repo,
        "SELECT #{q(routine_schema(second))}.ash_onetime_maintenance_status()"
      )

    assert first_status["steps"]["cleanup"]["last_success_at"]
    refute second_status["steps"]["cleanup"]["last_success_at"]
    refute first_status["steps"]["roll"]["last_success_at"]
    assert second_status["steps"]["roll"]["last_success_at"]
    assert first_status["installed_at"] != second_status["installed_at"]
  end

  test "maintenance helper checks current_user and restores its call setting", c do
    sql!(c.runtime_repo, "SET ash_onetime.maintenance = 'on'")
    refute scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_maintenance_active")}()")
    sql!(c.runtime_repo, "SET ash_onetime.maintenance = 'prior'")
    scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)")
    assert scalar(c.runtime_repo, "SELECT current_setting('ash_onetime.maintenance')") == "prior"
  end

  test "caller savepoints and nested failure restore the maintenance setting", c do
    sql!(c.runtime_repo, "BEGIN")

    try do
      sql!(c.runtime_repo, "SELECT set_config('ash_onetime.maintenance','caller',true)")
      sql!(c.runtime_repo, "SAVEPOINT caller_boundary")
      assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

      assert scalar(c.runtime_repo, "SELECT current_setting('ash_onetime.maintenance')") ==
               "caller"

      sql!(c.runtime_repo, "ROLLBACK TO caller_boundary")

      assert scalar(c.runtime_repo, "SELECT current_setting('ash_onetime.maintenance')") ==
               "caller"
    after
      sql!(c.runtime_repo, "ROLLBACK")
    end

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_maintenance_runs")} ADD CONSTRAINT fail_record CHECK (step <> 'cleanup') NOT VALID"
    )

    sql!(c.runtime_repo, """
    CREATE FUNCTION #{rel(c, "nested_call")}() RETURNS text LANGUAGE plpgsql AS $nested$
    BEGIN
      BEGIN
        PERFORM #{rel(c, "ash_onetime_cleanup_nonce")}(1);
        RAISE EXCEPTION 'missing injected failure' USING ERRCODE='AOC01';
      EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'untrusted_dependency:%' THEN RAISE; END IF;
      END;
      RETURN current_setting('ash_onetime.maintenance',true);
    END $nested$
    """)

    sql!(c.runtime_repo, "SET ash_onetime.maintenance='nested-caller'")
    assert scalar(c.runtime_repo, "SELECT #{rel(c, "nested_call")}()") == "nested-caller"

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_maintenance_runs")} DROP CONSTRAINT fail_record"
    )

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

    assert scalar(c.runtime_repo, "SELECT current_setting('ash_onetime.maintenance')") ==
             "nested-caller"
  end

  @tag rls_child_policy_copy_mutation: true
  @tag effective_column_authority_mutation: true
  test "forward roll copies policies and flags and resets table and column ACLs", c do
    parent = rel(c, "ash_onetime_response_payloads")
    sql!(c.owner_repo, "ALTER TABLE #{parent} ENABLE ROW LEVEL SECURITY")
    sql!(c.owner_repo, "ALTER TABLE #{parent} FORCE ROW LEVEL SECURITY")

    sql!(
      c.owner_repo,
      "CREATE POLICY tenant ON #{parent} TO #{q(c.runtime)} USING (logical_partition = current_setting('ash_onetime.tenant', true))"
    )

    month =
      scalar(Repo, "SELECT date_trunc('month', now())::date + interval '18 months'")
      |> NaiveDateTime.to_date()

    name =
      "ash_onetime_response_payloads_#{month.year}_#{String.pad_leading(to_string(month.month), 2, "0")}"

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(24)") >
             0

    assert SQL.query!(
             Repo,
             "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = $1::text::regclass",
             [rel(c, name)]
           ).rows == [[true, true]]

    policy_sql =
      "SELECT polname,polcmd,polpermissive,polroles,pg_get_expr(polqual,polrelid),pg_get_expr(polwithcheck,polrelid) FROM pg_policy WHERE polrelid=$1::text::regclass ORDER BY polname"

    assert SQL.query!(Repo, policy_sql, [rel(c, name)]).rows ==
             SQL.query!(Repo, policy_sql, [parent]).rows

    for privilege <- ["SELECT", "TRUNCATE", "TRIGGER", "REFERENCES"] do
      refute SQL.query!(Repo, "SELECT has_table_privilege($1,$2,$3)", [
               c.runtime,
               rel(c, name),
               privilege
             ]).rows == [[true]]
    end

    sql!(c.owner_repo, "GRANT SELECT (claim_id) ON #{rel(c, name)} TO #{q(c.runtime)}")

    try do
      assert scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->>'acl'"
             ) == "false"

      assert_refusal(
        c,
        "ash_onetime_roll_payload_partitions",
        "24",
        "untrusted_dependency: effective relation privilege"
      )
    after
      sql!(c.owner_repo, "REVOKE SELECT (claim_id) ON #{rel(c, name)} FROM #{q(c.runtime)}")
    end

    scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(24)")

    assert scalar(
             c.runtime_repo,
             "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->>'acl'"
           ) == "true"
  end

  test "fresh partitions are relative to migration execution", c do
    assert scalar(
             Repo,
             "SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent='#{rel(c, "ash_onetime_response_payloads")}'::regclass AND pg_get_expr(c.relpartbound,c.oid) LIKE '%' || to_char(date_trunc('month',now()),'YYYY-MM-DD') || '%'"
           ) >= 1
  end

  @tag :roll_relocation_mutation
  test "roll recovers past and forward DEFAULT months atomically and restores FORCE", c do
    table = rel(c, "ash_onetime_response_payloads_default")
    sql!(c.owner_repo, "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")
    sql!(c.owner_repo, "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")

    for offset <- [-3, 18] do
      sql!(
        Repo,
        "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} VALUES ('tenant', (date_trunc('month',now()) + interval '#{offset} months')::date, gen_random_uuid(), decode('cafe','hex'))"
      )
    end

    before_rows =
      sql!(
        Repo,
        "SELECT * FROM #{rel(c, "ash_onetime_response_payloads")} ORDER BY partition_date,claim_id"
      ).rows

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(24)") >
             0

    assert scalar(Repo, "SELECT count(*) FROM #{table}") == 0

    assert scalar(
             Repo,
             "SELECT count(*) FROM #{rel(c, "ash_onetime_response_payloads")} WHERE encoded_response=decode('cafe','hex')"
           ) == 2

    assert scalar(Repo, "SELECT relforcerowsecurity FROM pg_class WHERE oid='#{table}'::regclass")

    assert sql!(
             Repo,
             "SELECT * FROM #{rel(c, "ash_onetime_response_payloads")} ORDER BY partition_date,claim_id"
           ).rows == before_rows

    for [child] <-
          sql!(
            Repo,
            "SELECT DISTINCT tableoid::regclass::text FROM #{rel(c, "ash_onetime_response_payloads")}"
          ).rows do
      for sql <- [
            "SELECT * FROM #{child}",
            "TRUNCATE #{child}",
            "CREATE TRIGGER denied BEFORE INSERT ON #{child} FOR EACH ROW EXECUTE FUNCTION #{rel(c, "ash_onetime_guard_nonce_delete")}()"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
                 SQL.query(c.runtime_repo, sql, [])
      end
    end
  end

  test "prune drops empty expired partitions and keeps occupied ones with FORCE restored", c do
    for offset <- [-3, -2] do
      sql!(
        c.owner_repo,
        "CREATE TABLE #{rel(c, "past#{-offset}")} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{month_start(offset)}') TO ('#{month_start(offset + 1)}')"
      )

      sql!(
        c.owner_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_reset_acl")}('#{rel(c, "past#{-offset}")}'::regclass,true)"
      )

      sql!(c.owner_repo, "ALTER TABLE #{rel(c, "past#{-offset}")} ENABLE ROW LEVEL SECURITY")
      sql!(c.owner_repo, "ALTER TABLE #{rel(c, "past#{-offset}")} FORCE ROW LEVEL SECURITY")

      sql!(
        c.owner_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_copy_policy")}('#{rel(c, "past#{-offset}")}'::regclass)"
      )
    end

    StoreCase.restore_fixture!(
      Repo,
      """
      WITH claim AS (
        INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")}
        (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at)
        VALUES (gen_random_uuid(),'tenant',sha256('operation'),sha256('scope'),sha256('key'),sha256('fingerprint'),'complete','#{month_start(-2)}','test',sha256('response'),now()-interval '90 days',now()-interval '90 days'+interval '365 days',now()-interval '90 days') RETURNING id
      ) INSERT INTO #{rel(c, "ash_onetime_response_payloads")} SELECT 'tenant','#{month_start(-2)}',id,decode('cafe','hex') FROM claim
      """
    )

    report =
      scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_prune_payload_partitions")}(8,2000)")

    assert report["dropped"] == 1
    assert report["kept"] == 1
    assert scalar(Repo, "SELECT to_regclass('#{rel(c, "past3")}') IS NULL")

    assert scalar(
             Repo,
             "SELECT relforcerowsecurity FROM pg_class WHERE oid='#{rel(c, "past2")}'::regclass"
           )

    StoreCase.restore_fixture!(
      Repo,
      "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET retain_until=now()-interval '1 second',response_retain_until=now()-interval '1 second' WHERE logical_partition='tenant'"
    )

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_idempotency")}(100)") == 1

    assert scalar(
             c.runtime_repo,
             "SELECT #{rel(c, "ash_onetime_prune_payload_partitions")}(8,2000)->>'dropped'"
           ) == "1"

    assert scalar(Repo, "SELECT to_regclass('#{rel(c, "past2")}') IS NULL")
  end

  @tag revision7: true
  @tag maintenance_timeout_mutation: true
  test "Store bounds real server work and rolls it back at the caller timeout", c do
    trust_definition =
      scalar(
        c.owner_repo,
        "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_maintenance_trust")}()'::regprocedure)"
      )

    definition =
      scalar(
        c.owner_repo,
        "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_roll_payload_partitions")}(integer)'::regprocedure)"
      )

    body =
      String.replace(
        definition,
        "BEGIN\n",
        "BEGIN\n  UPDATE #{rel(c, "ash_onetime_maintenance_runs")} SET last_counts='{\"probe\":true}' WHERE step='cleanup';\n  PERFORM pg_sleep(1.5);\n",
        global: false
      )

    sql!(c.owner_repo, body)
    reseal_fixture_routine(c, "ash_onetime_roll_payload_partitions(integer)")
    previous = Application.get_env(:ash_onetime, :maintenance_statement_timeout_ms)
    Application.put_env(:ash_onetime, :maintenance_statement_timeout_ms, 200)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ash_onetime, :maintenance_statement_timeout_ms),
        else: Application.put_env(:ash_onetime, :maintenance_statement_timeout_ms, previous)
    end)

    previous_repo = Repo.put_dynamic_repo(c.runtime_repo)
    target = Postgres.for_repo(Repo, c.schema)
    started = System.monotonic_time(:millisecond)

    result =
      try do
        Postgres.roll_partitions(target, 1)
      after
        Repo.put_dynamic_repo(previous_repo)
        sql!(c.owner_repo, definition)
        sql!(c.owner_repo, trust_definition)
      end

    elapsed = System.monotonic_time(:millisecond) - started

    marker_present =
      scalar(
        Repo,
        "SELECT last_counts ? 'probe' FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE step='cleanup'"
      )

    IO.puts(
      "CALLER_TIMEOUT elapsed_ms=#{elapsed} bound_ms=200 marker_present=#{marker_present} result=#{inspect(result)}"
    )

    assert %Result{
             reason: :maintenance_timeout,
             transaction: :rolled_back,
             error: %AshOnetime.Error{message: "maintenance statement timed out", details: %{}}
           } = result

    assert result.error.details == %{}
    assert elapsed >= 150 and elapsed < 1_000

    refute marker_present

    assert scalar(c.runtime_repo, "SHOW statement_timeout") == "0"
  end

  @tag revision7: true
  @tag maintenance_transaction_mutation: true
  test "Store maintenance refuses caller transactions before SQL and preserves their settings",
       c do
    previous = Repo.put_dynamic_repo(c.runtime_repo)
    target = Postgres.for_repo(Repo, c.schema)

    try do
      assert {:ok, :unchanged} =
               Repo.transaction(fn ->
                 sql!(c.runtime_repo, "SET LOCAL statement_timeout='8s'")

                 for result <- [
                       Postgres.cleanup(target, 1, 0),
                       Postgres.reap(target, 1, 86_400),
                       Postgres.roll_partitions(target, 1)
                     ] do
                   assert %Result{
                            reason: :in_transaction,
                            admission_dispatch: :not_started,
                            transaction: :open
                          } = result
                 end

                 assert scalar(c.runtime_repo, "SHOW statement_timeout") == "8s"
                 :unchanged
               end)
    after
      Repo.put_dynamic_repo(previous)
    end

    assert scalar(c.runtime_repo, "SHOW statement_timeout") == "0"

    assert scalar(
             c.owner_repo,
             "SELECT count(*) FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE last_success_at IS NOT NULL"
           ) == 0
  end

  @tag revision7: true
  @tag maintenance_shape_mutation: true
  test "a builtin array input cannot dispatch a runtime domain check", c do
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "domain_probe")}() RETURNS boolean LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN true; END'"
    )

    sql!(
      c.runtime_repo,
      "CREATE DOMAIN #{rel(c, "runtime_domain")} AS text CHECK (#{rel(c, "domain_probe")}())"
    )

    domain = scalar(c.runtime_repo, "SELECT '#{rel(c, "runtime_domain")}'::regtype::oid")
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      Repo.checkout(fn ->
        sql!(
          c.owner_repo,
          "ALTER TABLE #{rel(c, "ash_onetime_maintenance_runs")} ADD COLUMN domain_input text DEFAULT array_in('{x}',#{domain}::oid,-1)::text"
        )

        sql!(c.owner_repo, "SELECT pg_advisory_unlock_all()")
      end)
    after
      Repo.put_dynamic_repo(previous)
    end

    assert_refusal(
      c,
      "ash_onetime_cleanup_nonce",
      "1",
      "untrusted_dependency: relation shape ash_onetime_maintenance_runs"
    )

    assert scalar(
             Repo,
             "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
           ) == 0
  end

  for defect <- [:when, :disabled] do
    @defect defect
    @tag revision7: true
    @tag maintenance_shape_mutation: true
    test "whole guard trigger row rejects #{@defect}", c do
      claims = rel(c, "ash_onetime_nonce_claims")

      if @defect == :when do
        sql!(
          c.runtime_repo,
          "CREATE FUNCTION #{rel(c, "when_probe")}() RETURNS integer LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN 1; END'"
        )

        sql!(c.owner_repo, "DROP TRIGGER ash_onetime_nonce_delete_guard ON #{claims}")

        sql!(
          c.owner_repo,
          "CREATE TRIGGER ash_onetime_nonce_delete_guard BEFORE DELETE ON #{claims} FOR EACH ROW WHEN (query_to_xml(#{literal("SELECT " <> rel(c, "when_probe") <> "()")},false,true,'')::text <> '') EXECUTE FUNCTION #{rel(c, "ash_onetime_guard_nonce_delete")}()"
        )
      else
        sql!(c.owner_repo, "ALTER TABLE #{claims} DISABLE TRIGGER ash_onetime_nonce_delete_guard")
      end

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: relation shape ash_onetime_nonce_claims"
      )

      assert scalar(
               Repo,
               "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
             ) == 0
    end
  end

  for root <- ["ash_onetime_nonce_claims", "ash_onetime_maintenance_runs"] do
    @root root
    @tag revision7: true
    @tag maintenance_shape_mutation: true
    test "exact relation set rejects inheritance from #{@root}", c do
      sql!(
        c.owner_repo,
        "CREATE TABLE #{rel(c, "unexpected_child")} () INHERITS (#{rel(c, @root)})"
      )

      sql!(
        c.owner_repo,
        "CREATE POLICY ash_onetime_maintenance ON #{rel(c, "unexpected_child")} TO #{q(c.owner)} USING (#{rel(c, "ash_onetime_maintenance_active")}()) WITH CHECK (#{rel(c, "ash_onetime_maintenance_active")}())"
      )

      sql!(
        c.owner_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_reset_acl")}('#{rel(c, "unexpected_child")}'::regclass,true)"
      )

      assert_refusal(c, "ash_onetime_cleanup_nonce", "1", "untrusted_dependency: relation set")
    end
  end

  @tag revision7: true
  @tag maintenance_maintain_mutation: true
  test "effective MAINTAIN audit covers pg_maintain and install revokes direct ANALYZE", c do
    assert %Postgrex.Result{messages: [%{code: "01000", message: message}]} =
             sql!(c.runtime_repo, "ANALYZE #{rel(c, "ash_onetime_nonce_claims")}")

    assert message =~ "permission denied to analyze"

    refute scalar(
             c.runtime_repo,
             "SELECT has_table_privilege(current_user,'#{rel(c, "ash_onetime_nonce_claims")}','MAINTAIN')"
           )

    sql!(Repo, "GRANT pg_maintain TO #{q(c.runtime)}")

    assert_refusal(
      c,
      "ash_onetime_cleanup_nonce",
      "1",
      maintain_diagnostic(c, "pg_maintain")
    )
  end

  @tag revision7: true
  @tag routine_lock_scope_mutation: true
  test "routines pin DateStyle, row security and lock_timeout and restore the caller's settings",
       c do
    for {{setting, value}, index} <-
          Enum.with_index([
            {"DateStyle", "SQL, DMY"},
            {"row_security", "off"},
            {"lock_timeout", "7s"}
          ]) do
      child = rel(c, "session_past_#{index}")

      sql!(
        c.owner_repo,
        "CREATE TABLE #{child} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{month_start(-4 - index)}') TO ('#{month_start(-3 - index)}') USING heap"
      )

      sql!(
        c.owner_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_reset_acl")}('#{child}'::regclass::oid,true::boolean)"
      )

      sql!(
        c.owner_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_copy_policy")}('#{child}'::regclass::oid)"
      )

      sql!(c.runtime_repo, "SET #{setting}=#{literal(value)}")
      previous = Repo.put_dynamic_repo(c.runtime_repo)

      # A transaction-local set_config inside a routine lasts until the caller's
      # transaction ends, so the caller's value is checked before that end.
      try do
        assert {:ok, :restored} =
                 Repo.transaction(fn ->
                   assert scalar(
                            c.runtime_repo,
                            "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(1)"
                          ) >= 0

                   assert scalar(
                            c.runtime_repo,
                            "SELECT #{rel(c, "ash_onetime_prune_payload_partitions")}(1::integer,2000::integer)->>'dropped'"
                          ) == "1"

                   assert scalar(c.runtime_repo, "SHOW #{setting}") == value
                   :restored
                 end)
      after
        Repo.put_dynamic_repo(previous)
      end

      sql!(c.runtime_repo, "RESET #{setting}")
    end
  end

  @tag revision7: true
  test "explicit internal argument types ignore runtime overloads", c do
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{q(c.schema)}.ash_onetime_maintenance_lock(boolean,bigint) RETURNS void LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''overload ran''; END'"
    )

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{q(c.schema)}.ash_onetime_cleanup_eligible(timestamp) RETURNS boolean LANGUAGE sql AS 'SELECT false'"
    )

    for {name, args, result} <- [
          {"ash_onetime_cleanup_nonce", "bigint", "bigint"},
          {"ash_onetime_roll_payload_partitions", "bigint", "bigint"},
          {"ash_onetime_reap_idempotency", "bigint,bigint", "bigint"},
          {"ash_onetime_prune_payload_partitions", "bigint,bigint", "jsonb"}
        ] do
      sql!(
        c.runtime_repo,
        "CREATE FUNCTION #{q(c.schema)}.#{q(name)}(#{args}) RETURNS #{result} LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''overload ran''; END'"
      )
    end

    previous = Repo.put_dynamic_repo(c.runtime_repo)

    try do
      target = Postgres.for_repo(Repo, c.schema)
      assert {:ok, %{}} = Postgres.cleanup(target, 1, 1)
      assert {:ok, %{partitions_created: 0}} = Postgres.roll_partitions(target, 1)
      assert {:ok, 0} = Postgres.reap(target, 1, 86_400)
    after
      Repo.put_dynamic_repo(previous)
    end

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

    assert %{"acl" => true, "definers" => true, "trust" => true, "policy" => true} =
             scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'"
             )
  end

  @tag revision7: true
  @tag maintenance_heap_mutation: true
  test "recovery and forward children use heap despite caller access method", c do
    am = ("ao_am_" <> String.replace(c.schema, ~r/[^a-z0-9]/, "")) |> String.slice(0, 63)
    sql!(Repo, "CREATE ACCESS METHOD #{q(am)} TYPE TABLE HANDLER heap_tableam_handler")
    on_exit(fn -> sql!(Repo, "DROP ACCESS METHOD #{q(am)}") end)
    sql!(c.runtime_repo, "SET default_table_access_method=#{literal(am)}")

    sql!(
      Repo,
      "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} VALUES ('global','#{month_start(-6)}',gen_random_uuid(),'x')"
    )

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(24)") >
             0

    assert SQL.query!(
             Repo,
             "SELECT DISTINCT a.amname FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid JOIN pg_am a ON a.oid=c.relam WHERE i.inhparent=$1::text::regclass",
             [rel(c, "ash_onetime_response_payloads")]
           ).rows == [["heap"]]

    for [oid, name] <-
          SQL.query!(
            c.owner_repo,
            "SELECT c.oid,c.relname FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent=$1::text::regclass",
            [rel(c, "ash_onetime_response_payloads")]
          ).rows do
      actual =
        SQL.query!(c.owner_repo, "SELECT #{rel(c, "ash_onetime_maintenance_shape")}($1::oid)", [
          oid
        ]).rows
        |> hd()
        |> hd()

      expected =
        scalar(
          c.owner_repo,
          "SELECT #{rel(c, "ash_onetime_maintenance_shapes")}()->'ash_onetime_response_payloads_child'"
        )

      differences =
        for {key, value} <- actual,
            value != expected[key],
            into: %{},
            do: {key, %{actual: value, expected: expected[key]}}

      assert differences == %{}, "#{name}: #{inspect(differences, limit: :infinity)}"
    end

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0
  end

  @tag revision7: true
  test "concurrent compound Store cleanup completes without a deadlock", c do
    {:ok, second_repo} = subject(c.runtime)

    child = rel(c, "concurrent_past")

    sql!(
      c.owner_repo,
      "CREATE TABLE #{child} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{month_start(-3)}') TO ('#{month_start(-2)}') USING heap"
    )

    sql!(
      c.owner_repo,
      "SELECT #{rel(c, "ash_onetime_maintenance_reset_acl")}('#{child}'::regclass,true)"
    )

    sql!(c.owner_repo, "ALTER TABLE #{child} ENABLE ROW LEVEL SECURITY")
    sql!(c.owner_repo, "ALTER TABLE #{child} FORCE ROW LEVEL SECURITY")

    sql!(
      c.owner_repo,
      "SELECT #{rel(c, "ash_onetime_maintenance_copy_policy")}('#{child}'::regclass)"
    )

    definition =
      scalar(
        c.owner_repo,
        "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_cleanup_idempotency")}(integer)'::regprocedure)"
      )

    [trust_line] = Regex.run(~r/PERFORM [^;]+\.ash_onetime_maintenance_trust\(\);/, definition)

    sql!(
      c.owner_repo,
      String.replace(
        definition,
        trust_line,
        "PERFORM pg_advisory_xact_lock(19285,77); " <> trust_line,
        global: false
      )
    )

    reseal_fixture_routine(c, "ash_onetime_cleanup_idempotency(integer)")

    Repo.checkout(fn ->
      sql!(Repo, "SELECT pg_advisory_lock(19285,77)")

      tasks =
        for repo <- [c.runtime_repo, second_repo] do
          Task.async(fn ->
            previous = Repo.put_dynamic_repo(repo)
            target = Postgres.for_repo(Repo, c.schema)

            try do
              Postgres.cleanup(target, 100, 8)
            after
              Repo.put_dynamic_repo(previous)
            end
          end)
        end

      try do
        eventually(fn ->
          scalar(
            Repo,
            "SELECT count(DISTINCT pid) FROM pg_locks WHERE NOT granted AND ((locktype='advisory' AND classid=19285 AND objid=77) OR (locktype='relation' AND relation='#{rel(c, "ash_onetime_idempotency_claims")}'::regclass))"
          ) == 2
        end)
      after
        sql!(Repo, "SELECT pg_advisory_unlock(19285,77)")
      end

      for task <- tasks do
        result = Task.await(task, 30_000)
        IO.puts("COMPOUND_CLEANUP #{inspect(result)}")
        assert match?({:ok, %{}}, result) or match?(%Result{reason: :lock_unavailable}, result)
      end
    end)
  end

  @tag revision7: true
  @tag maintenance_lock_mutation: true
  test "recursive locks exclude concurrent inheritance before the check", c do
    {:ok, ddl_repo} = subject(c.owner)

    definition =
      scalar(
        c.owner_repo,
        "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_cleanup_nonce")}(integer)'::regprocedure)"
      )

    body =
      String.replace(
        definition,
        "ash_onetime_maintenance_trust();",
        "ash_onetime_maintenance_trust(); PERFORM pg_advisory_xact_lock(19284,99);",
        global: false
      )

    sql!(c.owner_repo, body)
    reseal_fixture_routine(c, "ash_onetime_cleanup_nonce(integer)")

    Repo.checkout(fn ->
      sql!(Repo, "SELECT pg_advisory_lock(19284,99)")

      worker =
        Task.async(fn ->
          SQL.query(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)", [])
        end)

      try do
        eventually(fn ->
          scalar(
            Repo,
            "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=19284 AND objid=99 AND NOT granted)"
          )
        end)

        sql!(ddl_repo, "SET lock_timeout='100ms'")

        for root <- ["ash_onetime_nonce_claims", "ash_onetime_maintenance_runs"] do
          assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                   SQL.query(
                     ddl_repo,
                     "CREATE TABLE #{rel(c, "concurrent_child")} () INHERITS (#{rel(c, root)})",
                     []
                   )
        end
      after
        sql!(Repo, "SELECT pg_advisory_unlock(19284,99)")
      end

      assert {:ok, _} = Task.await(worker, 15_000)
    end)
  end

  @tag revision7: true
  @tag legacy_install: true
  @tag normalize_attnum_mutation: true
  test "ADD COLUMN upgrade uses a same-server reference and maps attribute numbers", c do
    claims = rel(c, "ash_onetime_idempotency_claims")
    sql!(c.owner_repo, "DROP INDEX #{rel(c, "ash_onetime_idempotency_claims_cleanup_index")}")
    sql!(c.owner_repo, "DROP INDEX #{rel(c, "ash_onetime_idempotency_claims_hold_index")}")
    sql!(c.owner_repo, "ALTER TABLE #{claims} DROP COLUMN hold_reference")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD COLUMN hold_reference text CONSTRAINT ash_onetime_idempotency_claims_hold_check CHECK (hold_reference IS NULL OR (octet_length(hold_reference) >= 1 AND octet_length(hold_reference) <= 255 AND state='complete'))"
    )

    sql!(
      c.owner_repo,
      "CREATE INDEX ash_onetime_idempotency_claims_cleanup_index ON #{claims} (retain_until) WHERE state='complete' AND hold_reference IS NULL"
    )

    sql!(
      c.owner_repo,
      "CREATE INDEX ash_onetime_idempotency_claims_hold_index ON #{claims} (logical_partition,hold_reference) WHERE hold_reference IS NOT NULL"
    )

    with_upgrade(c, fn ->
      assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

      assert scalar(
               c.owner_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_shapes")}()->>'server_version_num'"
             ) == scalar(c.owner_repo, "SHOW server_version_num")

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM pg_class WHERE relnamespace=#{literal(c.schema)}::regnamespace AND relname LIKE 'aor_%'"
             ) == 0

      sql!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_nonce_claims")} ALTER COLUMN verifier_id SET DEFAULT upper('changed')"
      )

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: relation shape ash_onetime_nonce_claims"
      )
    end)
  end

  test "historical migration fixtures retain their exact shipped source bytes" do
    directory = "test/support/fixtures/shipped"
    sources = directory |> Path.join("sources.json") |> File.read!() |> Jason.decode!()

    for {path, metadata} <- sources do
      assert :crypto.hash(:sha256, File.read!(Path.join(directory, path)))
             |> Base.encode16(case: :lower) == metadata["sha256"],
             path
    end
  end

  # Shapes collapse across releases whose only changes are replaced invoker
  # bodies. Exercise those sources too, plus every supported hash modulus.
  for {release, count} <-
        for(
          release <- ["v0.1.0", "v0.2.0", "v0.6.0", "v1.1.0", "v1.10.0"],
          count <- [nil, 2, 64],
          do: {release, count}
        ) ++
          for(count <- [4, 8, 16, 32], do: {"v1.1.0", count}) do
    if release == "v0.1.0" and count == 2 do
      @tag shipped_primary_mutation: true
    end

    @tag timeout: 300_000
    @tag shipped_upgrade: true
    @tag legacy_install: true
    @tag shipped_release: release
    @tag hash_partitions: count
    @tag partition_start: ~D[2000-01-01]
    test "shipped schema upgrades and restores: #{release}, claims #{count || :plain}", c do
      assert scalar(
               c.runtime_repo,
               "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname=current_user"
             ) == false

      assert_shipped_payload(c)
      before = shipped_data(c)

      with_upgrade(c, fn ->
        assert_reference_shapes(c)
        assert_shipped_payload(c)
        assert shipped_data(c) == before

        restore_fixpoint(c, fn ->
          assert_shipped_payload(c)
          assert shipped_data(c) == before
        end)
      end)
    end
  end

  @tag shipped_upgrade: true
  @tag legacy_install: true
  @tag shipped_release: "v1.10.0"
  @tag quoted_schema: true
  @tag hash_partitions: 4
  test "shipped schema upgrades and restores in a quoted tenant schema", c do
    before = shipped_data(c)

    with_upgrade(c, fn ->
      assert_reference_shapes(c)

      restore_fixpoint(c, fn ->
        assert_shipped_payload(c)
        assert shipped_data(c) == before
      end)
    end)
  end

  @tag shipped_check_names: true
  @tag legacy_install: true
  @tag shipped_release: "v0.6.0"
  @tag hash_partitions: 2
  test "historical upgrade replaces validated CHECKs by their actual catalog names", c do
    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} RENAME CONSTRAINT ash_onetime_idempotency_claims_check2 TO renamed_response_check"
    )

    with_upgrade(c, fn ->
      assert_reference_shapes(c)
      assert_shipped_payload(c)
    end)
  end

  for defect <- [
        :check,
        :missing_check,
        :duplicate_check,
        :extra_duplicate_check,
        :child_check,
        :default,
        :index,
        :primary_key,
        :trigger
      ] do
    @defect defect
    @tag shipped_upgrade_tamper: true
    @tag legacy_install: true
    @tag shipped_release: "v0.6.0"
    @tag hash_partitions: 2
    test "historical upgrade refuses changed #{@defect} without adopting it", c do
      table = rel(c, "ash_onetime_response_payloads")

      case @defect do
        :check ->
          sql!(
            c.owner_repo,
            "ALTER TABLE #{table} ADD CHECK (octet_length(encoded_response) > 0)"
          )

        :missing_check ->
          sql!(
            c.owner_repo,
            "ALTER TABLE #{table} DROP CONSTRAINT ash_onetime_response_payloads_encoded_response_check"
          )

        :duplicate_check ->
          sql!(
            c.owner_repo,
            "ALTER TABLE #{table} DROP CONSTRAINT ash_onetime_response_payloads_encoded_response_check"
          )

          sql!(
            c.owner_repo,
            "ALTER TABLE #{table} ADD CHECK (octet_length(logical_partition) BETWEEN 1 AND 255)"
          )

        :extra_duplicate_check ->
          sql!(
            c.owner_repo,
            "ALTER TABLE #{table} ADD CHECK (octet_length(logical_partition) BETWEEN 1 AND 255)"
          )

        :child_check ->
          sql!(
            c.owner_repo,
            "ALTER TABLE #{rel(c, "ash_onetime_response_payloads_default")} ADD CHECK (octet_length(encoded_response) > 0)"
          )

        :default ->
          sql!(
            c.owner_repo,
            "ALTER TABLE #{table} ALTER COLUMN logical_partition SET DEFAULT 'changed'"
          )

        :index ->
          sql!(c.owner_repo, "CREATE INDEX extra_index ON #{table} (claim_id)")

        :primary_key ->
          sql!(
            c.owner_repo,
            "ALTER TABLE #{table} DROP CONSTRAINT ash_onetime_response_payloads_pkey"
          )

          sql!(
            c.owner_repo,
            "ALTER TABLE #{table} ADD PRIMARY KEY (partition_date,claim_id,encoded_response)"
          )

        :trigger ->
          sql!(
            c.owner_repo,
            "CREATE FUNCTION #{q(c.schema)}.unexpected() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN OLD; END'"
          )

          sql!(
            c.owner_repo,
            "CREATE TRIGGER unexpected BEFORE DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION #{q(c.schema)}.unexpected()"
          )
      end

      error = assert_raise Postgrex.Error, fn -> with_upgrade(c, fn -> :ok end) end
      assert error.postgres.message =~ "untrusted_dependency: upgrade relation shape"

      assert scalar(
               c.owner_repo,
               "SELECT to_regnamespace(#{literal(routine_schema(c.schema))}) IS NULL"
             )

      assert_shipped_payload(c)
    end
  end

  for variant <- [:default, :hash, :facts, :logical_partitions, :prefix] do
    @variant variant
    @tag restore_fixpoint: true
    @tag hash_partitions: if(variant == :hash, do: 2, else: nil)
    @tag quoted_schema: variant == :prefix
    test "every package expression is a PostgreSQL 18 dump restore fixpoint, #{@variant}", c do
      if @variant == :facts do
        source = Generator.render_fact_tables(Repo, fact_tables: ["maintenance_facts"])
        module = Module.concat(__MODULE__, "Facts#{System.unique_integer([:positive])}")

        source =
          String.replace(
            source,
            inspect(Repo) <> ".Migrations.AddAshOnetimeBoundaryFacts",
            inspect(module)
          )

        [{^module, _}] = Code.compile_string(source)
        previous = Repo.put_dynamic_repo(c.owner_repo)

        try do
          assert :ok =
                   Ecto.Migrator.up(Repo, 20_261_113_000_003, module,
                     prefix: c.schema,
                     log: false
                   )
        after
          Repo.put_dynamic_repo(previous)
          :code.purge(module)
          :code.delete(module)
        end
      end

      if @variant == :logical_partitions do
        for partition <- ["partition-a", "partition-b"] do
          sql!(
            Repo,
            "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} VALUES (#{literal(partition)},current_date,gen_random_uuid(),'payload')"
          )
        end
      end

      restore_fixpoint(c, fn ->
        if @variant == :logical_partitions do
          assert SQL.query!(
                   Repo,
                   "SELECT DISTINCT logical_partition FROM #{rel(c, "ash_onetime_response_payloads")} ORDER BY 1",
                   []
                 ).rows == [["partition-a"], ["partition-b"]]
        end
      end)
    end
  end

  defp restore_fixpoint(c, check) do
    dump = postgres_tool!("pg_dump")
    restore = postgres_tool!("pg_restore")
    {login, password} = Process.get({__MODULE__, :credential, c.owner})
    uri = URI.parse(System.fetch_env!("DATABASE_URL"))

    connection = [
      "--host",
      uri.host,
      "--port",
      to_string(uri.port),
      "--username",
      login,
      "--dbname",
      String.trim_leading(uri.path, "/")
    ]

    environment = [{"PGPASSWORD", password}]

    sql!(
      Repo,
      "GRANT CREATE ON DATABASE #{q(String.trim_leading(uri.path, "/"))} TO #{q(c.owner)}"
    )

    archive = Path.join(System.tmp_dir!(), "ao_dump_#{Ecto.UUID.generate()}.dump")
    before = expression_catalog(c)
    shapes = relation_shapes(c)
    policies = normalized_policies(c)
    [backup_login, backup_password] = String.split(uri.userinfo, ":", parts: 2)
    backup_connection = List.replace_at(connection, 5, URI.decode_www_form(backup_login))

    try do
      {output, status} =
        System.cmd(
          dump,
          backup_connection ++
            [
              "--schema",
              q(c.schema),
              "--schema",
              q(routine_schema(c.schema)),
              "--format=custom",
              "--file",
              archive
            ],
          env: [{"PGPASSWORD", URI.decode_www_form(backup_password)}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      sql!(c.owner_repo, "DROP SCHEMA #{q(c.schema)} CASCADE")
      sql!(c.owner_repo, "DROP SCHEMA #{q(routine_schema(c.schema))} CASCADE")

      {output, status} =
        System.cmd(
          restore,
          connection ++
            ["--no-owner", "--exit-on-error", "--role", c.owner, archive],
          env: environment,
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert expression_catalog(c) == before

      assert relation_shapes(c) == shapes
      assert normalized_policies(c) == policies
      assert_reference_shapes(c)

      prune =
        scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_prune_payload_partitions")}(8,2000)")

      assert prune["dropped"] in 0..8
      refute prune["blocked"]
      assert_reference_shapes(c)

      assert scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_reap_idempotency")}(100,86400)"
             ) == 0

      assert scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(24)"
             ) > 0

      assert_reference_shapes(c)

      check.()
    after
      File.rm!(archive)
      refute File.exists?(archive)
    end
  end

  @tag restore_fixpoint: true
  @tag maintenance_shape_mutation: true
  test "noinherit is omitted only for index backed constraints on leaf partitions", c do
    leaf = rel(c, "ash_onetime_response_payloads_default")

    constraints =
      scalar(
        c.owner_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_shape")}('#{leaf}'::regclass::oid)->'constraints'"
      )

    refute Enum.find(constraints, &(&1["type"] == "p")) |> Map.has_key?("noinherit")

    assert Enum.filter(constraints, &(&1["type"] in ["n", "c"]))
           |> Enum.all?(&Map.has_key?(&1, "noinherit"))

    # Trusted fixture provisioning changes exactly one real catalog field, as
    # the executable-metadata Table 1 fixtures do; every subject is runtime.
    for {table, type} <- [
          {"ash_onetime_nonce_claims", "p"},
          {"ash_onetime_nonce_claims", "u"},
          {"ash_onetime_nonce_claims", "n"},
          {"ash_onetime_nonce_claims", "c"},
          {"ash_onetime_response_payloads", "p"},
          {"ash_onetime_response_payloads", "n"},
          {"ash_onetime_response_payloads", "c"},
          {"ash_onetime_response_payloads_default", "n"},
          {"ash_onetime_response_payloads_default", "c"}
        ] do
      [oid, original] =
        SQL.query!(
          Repo,
          "SELECT oid,connoinherit FROM pg_constraint WHERE conrelid=$1::text::regclass AND contype=$2::\"char\" ORDER BY oid LIMIT 1",
          [rel(c, table), type]
        ).rows
        |> hd()

      try do
        SQL.query!(Repo, "UPDATE pg_constraint SET connoinherit=NOT connoinherit WHERE oid=$1", [
          oid
        ])

        assert_refusal(
          c,
          "ash_onetime_cleanup_nonce",
          "1",
          "untrusted_dependency: relation shape #{table}"
        )
      after
        SQL.query!(Repo, "UPDATE pg_constraint SET connoinherit=$2 WHERE oid=$1", [oid, original])
      end

      assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0
    end

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "42809", message: message}}} =
             SQL.query(
               c.owner_repo,
               "CREATE TABLE #{rel(c, "cannot_inherit")} () INHERITS (#{leaf})",
               []
             )

    assert message =~ "cannot inherit from partition"
  end

  defp migrate_source!(owner_repo, schema, source) do
    module = Module.concat(__MODULE__, "Shipped#{System.unique_integer([:positive])}")

    source =
      Regex.replace(~r/defmodule \S+ do/, source, "defmodule #{inspect(module)} do",
        global: false
      )

    Code.compile_string(source)
    previous = Repo.put_dynamic_repo(owner_repo)

    try do
      assert :ok =
               Ecto.Migrator.up(
                 Repo,
                 20_261_113_100_000 + System.unique_integer([:positive, :monotonic]),
                 module,
                 prefix: schema,
                 log: false
               )
    after
      Repo.put_dynamic_repo(previous)
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp seed_shipped_payload!(repo, schema) do
    payload = q(schema) <> ".ash_onetime_response_payloads"
    claims = q(schema) <> ".ash_onetime_idempotency_claims"
    # Named columns work both before and after logical_partition was shipped.
    sql!(
      repo,
      "INSERT INTO #{claims} (id,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at) VALUES ('00000000-0000-0000-0000-000000000001',sha256('op'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('fingerprint'::bytea),'complete','2000-01-01','fixture',sha256('payload'::bytea),now(),now()+interval '10 years',now())"
    )

    sql!(
      repo,
      "INSERT INTO #{payload} (partition_date,claim_id,encoded_response) VALUES ('2000-01-01','00000000-0000-0000-0000-000000000001','payload')"
    )

    sql!(
      repo,
      "INSERT INTO #{claims} (id,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at) VALUES ('00000000-0000-0000-0000-000000000002',sha256('op'::bytea),sha256('scope'::bytea),sha256('second-key'::bytea),sha256('second-fingerprint'::bytea),'complete',current_date,'fixture',sha256('default-payload'::bytea),now(),now()+interval '10 years',now())"
    )

    # A second payload in DEFAULT must survive roll's drain into a new month.
    sql!(
      repo,
      "INSERT INTO #{payload} (partition_date,claim_id,encoded_response) VALUES (current_date,'00000000-0000-0000-0000-000000000002','default-payload')"
    )
  end

  defp shipped_data(c) do
    for table <- [
          "ash_onetime_idempotency_claims",
          "ash_onetime_nonce_claims",
          "ash_onetime_response_payloads"
        ] do
      SQL.query!(
        Repo,
        "SELECT to_jsonb(t) - ARRAY['effect_local','effect_attempt','response_retain_until','response_expired_at'] FROM #{rel(c, table)} t ORDER BY to_jsonb(t)::text",
        []
      ).rows
    end
  end

  defp assert_shipped_payload(c) do
    assert SQL.query!(
             Repo,
             "SELECT logical_partition,claim_id::text,encoded_response FROM #{rel(c, "ash_onetime_response_payloads")} ORDER BY claim_id",
             []
           ).rows == [
             ["global", "00000000-0000-0000-0000-000000000001", "payload"],
             ["global", "00000000-0000-0000-0000-000000000002", "default-payload"]
           ]

    if scalar(
         Repo,
         "SELECT to_regclass(#{literal(q(c.schema) <> ".maintenance_facts")}) IS NOT NULL"
       ) do
      assert SQL.query!(Repo, "SELECT tenant,type,tags FROM #{q(c.schema)}.maintenance_facts", []).rows ==
               [["partition-a", "retained", ["fact"]]]
    end
  end

  defp normalized_policies(c) do
    SQL.query!(
      c.owner_repo,
      "SELECT c.relname,p.polname,#{rel(c, "ash_onetime_maintenance_normalize")}(p.polqual::text,p.polrelid::oid),#{rel(c, "ash_onetime_maintenance_normalize")}(p.polwithcheck::text,p.polrelid::oid) FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid WHERE c.relnamespace=$1::text::regnamespace ORDER BY c.relname,p.polname",
      [c.schema]
    ).rows
  end

  defp relation_shapes(c) do
    SQL.query!(
      c.owner_repo,
      "SELECT relname,#{rel(c, "ash_onetime_maintenance_shape")}(oid) FROM pg_class WHERE relnamespace=$1::text::regnamespace AND relkind IN ('r','p') AND relname LIKE 'ash_onetime_%' ORDER BY relname",
      [c.schema]
    ).rows
  end

  defp assert_reference_shapes(c) do
    expected = scalar(c.owner_repo, "SELECT #{rel(c, "ash_onetime_maintenance_shapes")}()")

    rows =
      SQL.query!(
        c.owner_repo,
        "SELECT t.relname,p.relname,regexp_replace(t.relpartbound::text,':location [-0-9]+',':location -1','g'),#{rel(c, "ash_onetime_maintenance_shape")}(t.oid) FROM pg_class t LEFT JOIN pg_inherits i ON i.inhrelid=t.oid LEFT JOIN pg_class p ON p.oid=i.inhparent WHERE t.relnamespace=$1::text::regnamespace AND t.relkind IN ('r','p') AND (t.relname=ANY($2) OR p.relname=ANY($2)) ORDER BY t.relname",
        [
          c.schema,
          [
            "ash_onetime_idempotency_claims",
            "ash_onetime_nonce_claims",
            "ash_onetime_response_payloads",
            "ash_onetime_maintenance_runs",
            "ash_onetime_effect_outcomes"
          ]
        ]
      ).rows

    assert scalar(
             c.owner_repo,
             "SELECT count(*) FROM pg_class WHERE relnamespace=#{literal(c.schema)}::regnamespace AND relname LIKE 'aor_%'"
           ) == 0

    assert length(rows) > 4

    for [name, parent, bound, shape] <- rows do
      reference =
        if parent,
          do: get_in(expected, [parent <> "_children", bound]) || expected[parent <> "_child"],
          else: expected[name]

      assert shape == reference, "fresh-install reference differs for #{name}"
    end
  end

  defp postgres_tool!(tool) do
    path = System.find_executable(tool) || "/usr/lib/postgresql/18/bin/#{tool}"
    {version, 0} = System.cmd(path, ["--version"])
    assert version =~ ~r/\(PostgreSQL\) 18\./
    IO.puts("PG_CLIENT #{String.trim(version)}")
    path
  end

  defp expression_catalog(c) do
    rows =
      SQL.query!(
        c.owner_repo,
        """
        WITH relations AS (SELECT oid,relname FROM pg_class WHERE relnamespace=$1::text::regnamespace AND (relname LIKE 'ash_onetime_%' OR relname='maintenance_facts')), expressions AS (
          SELECT r.relname || ':default:' || a.attname AS name,d.adbin::text AS tree FROM relations r JOIN pg_attrdef d ON d.adrelid=r.oid JOIN pg_attribute a ON a.attrelid=r.oid AND a.attnum=d.adnum
          UNION ALL SELECT r.relname || ':constraint:' || x.conname,x.conbin::text FROM relations r JOIN pg_constraint x ON x.conrelid=r.oid WHERE x.conbin IS NOT NULL
          UNION ALL SELECT r.relname || ':index_expression',i.indexprs::text FROM relations r JOIN pg_index i ON i.indexrelid=r.oid WHERE i.indexprs IS NOT NULL
          UNION ALL SELECT r.relname || ':index_predicate',i.indpred::text FROM relations r JOIN pg_index i ON i.indexrelid=r.oid WHERE i.indpred IS NOT NULL
          UNION ALL SELECT r.relname || ':partition_key',p.partexprs::text FROM relations r JOIN pg_partitioned_table p ON p.partrelid=r.oid WHERE p.partexprs IS NOT NULL
          UNION ALL SELECT r.relname || ':bound',c.relpartbound::text FROM relations r JOIN pg_class c USING(oid) WHERE c.relpartbound IS NOT NULL
          UNION ALL SELECT r.relname || ':trigger:' || t.tgname,t.tgqual::text FROM relations r JOIN pg_trigger t ON t.tgrelid=r.oid WHERE t.tgqual IS NOT NULL
          UNION ALL SELECT r.relname || ':policy_using:' || p.polname,p.polqual::text FROM relations r JOIN pg_policy p ON p.polrelid=r.oid
          UNION ALL SELECT r.relname || ':policy_check:' || p.polname,p.polwithcheck::text FROM relations r JOIN pg_policy p ON p.polrelid=r.oid
        ) SELECT name,regexp_replace(tree,':location [-0-9]+',':location -1','g') FROM expressions ORDER BY name
        """,
        [c.schema]
      ).rows

    identities =
      SQL.query!(
        c.owner_repo,
        "SELECT oid::text,proname || '(' || proargtypes::text || ')' FROM pg_proc WHERE pronamespace IN ($1::text::regnamespace,to_regnamespace($2))",
        [c.schema, routine_schema(c.schema)]
      ).rows

    for [name, tree] <- rows, do: [name, normalize_expression(tree, identities)]
  end

  defp normalize_expression(nil, _identities), do: nil

  defp normalize_expression(tree, identities) do
    Enum.reduce(identities, tree, fn [oid, identity], acc ->
      Regex.replace(~r/(:[a-z]+) #{oid}( |})/, acc, "\\1 #{identity}\\2")
    end)
  end

  defp with_upgrade(c, callback) do
    unless scalar(
             c.owner_repo,
             "SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=#{literal(rel(c, "ash_onetime_idempotency_claims"))}::regclass AND attname='effect_local' AND NOT attisdropped)"
           ) do
      migrate_source!(c.owner_repo, c.schema, Generator.render_external_state_upgrade(Repo, []))
    end

    [{module, _}] =
      Code.compile_string(
        Generator.render_maintenance_upgrade(Repo,
          prefix: c.schema,
          maintenance_role: c.maintainer
        )
      )

    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      :ok = Ecto.Migrator.up(Repo, 20_261_114_000_002, module, prefix: c.schema, log: false)
      callback.()
    after
      Repo.put_dynamic_repo(previous)
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp reseal_fixture_routine(c, signature) do
    name = signature |> String.split("(") |> hd()

    [old, new] =
      SQL.query!(
        c.owner_repo,
        "SELECT m->>'digest',encode(sha256(convert_to(p.prosrc,'UTF8')),'hex') FROM #{rel(c, "ash_onetime_maintenance_runs")} r CROSS JOIN LATERAL jsonb_array_elements(r.last_counts->'routines') m JOIN pg_proc p ON p.oid=$1::text::regprocedure WHERE r.step='install' AND m->>'name'=$2",
        [rel(c, name) <> String.replace_prefix(signature, name, ""), name]
      ).rows
      |> hd()

    definition =
      scalar(
        c.owner_repo,
        "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_maintenance_trust")}()'::regprocedure)"
      )

    sql!(c.owner_repo, String.replace(definition, old, new))
  end

  @tag revision7: true
  @tag maintenance_digest_mutation: true
  test "package routine identity also requires its exact source digest", c do
    definition =
      scalar(
        c.owner_repo,
        "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_guard_nonce_delete")}()'::regprocedure)"
      )

    sql!(
      c.owner_repo,
      String.replace(definition, "BEGIN", "BEGIN -- owner changed routine", global: false)
    )

    assert_refusal(
      c,
      "ash_onetime_cleanup_nonce",
      "1",
      "untrusted_dependency: package routine digest"
    )
  end

  @tag revision7: true
  test "a server-version change rebuilds and removes the same-server reference", c do
    definition =
      scalar(
        c.owner_repo,
        "SELECT pg_get_functiondef('#{rel(c, "ash_onetime_maintenance_shapes")}()'::regprocedure)"
      )

    version = scalar(c.owner_repo, "SHOW server_version_num")
    sql!(c.owner_repo, String.replace(definition, version, "0"))
    reseal_fixture_routine(c, "ash_onetime_maintenance_shapes()")
    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

    assert scalar(
             c.owner_repo,
             "SELECT count(*) FROM pg_class WHERE relnamespace=#{literal(c.schema)}::regnamespace AND relname LIKE 'aor_%'"
           ) == 0
  end

  @tag revision7: true
  @tag maintenance_shape_mutation: true
  test "partition bound trees must contain finite DATE constants", c do
    sql!(
      c.owner_repo,
      "CREATE TABLE #{rel(c, "nonmonthly")} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM (MINVALUE) TO ('#{month_start(-4)}') USING heap"
    )

    sql!(
      c.owner_repo,
      "SELECT #{rel(c, "ash_onetime_maintenance_copy_policy")}('#{rel(c, "nonmonthly")}'::regclass)"
    )

    sql!(
      c.owner_repo,
      "SELECT #{rel(c, "ash_onetime_maintenance_reset_acl")}('#{rel(c, "nonmonthly")}'::regclass,true)"
    )

    assert_refusal(
      c,
      "ash_onetime_cleanup_nonce",
      "1",
      "untrusted_dependency: partition bound nonmonthly"
    )
  end

  @tag revision7: true
  test "routine identity fixes planner and language properties too", c do
    sql!(
      c.owner_repo,
      "ALTER FUNCTION #{rel(c, "ash_onetime_cleanup_eligible")}(timestamptz) IMMUTABLE"
    )

    assert_refusal(
      c,
      "ash_onetime_cleanup_nonce",
      "1",
      "untrusted_dependency: package routine digest"
    )
  end

  @tag revision7: true
  @tag routine_schema_mutation: true
  test "effective routine schema CREATE refuses an untrusted runtime grant", c do
    routine_schema = routine_schema(c.schema)

    assert scalar(
             c.owner_repo,
             "SELECT last_counts->>'routine_schema' FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE step='install'"
           ) == routine_schema

    assert scalar(
             Repo,
             "SELECT has_schema_privilege(current_user,#{literal(routine_schema)},'CREATE')"
           )

    assert scalar(
             Repo,
             "SELECT has_schema_privilege(#{literal(c.migrator)},#{literal(routine_schema)},'CREATE')"
           )

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1::integer)") ==
             0

    assert scalar(Repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1::integer)") == 0
    {:ok, inherited_owner_repo} = subject(c.migrator)

    assert scalar(
             inherited_owner_repo,
             "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1::integer)"
           ) == 0

    sql!(c.owner_repo, "GRANT CREATE ON SCHEMA #{q(routine_schema)} TO #{q(c.runtime)}")

    assert_refusal(
      c,
      "ash_onetime_cleanup_nonce",
      "1",
      "untrusted_dependency: routine schema CREATE"
    )
  end

  for {role, inherit} <- [
        {:runtime, false},
        {:runtime, true},
        {:maintainer, false},
        {:maintainer, true}
      ] do
    @role role
    @inherit inherit
    @tag revision7: true
    @tag routine_owner_membership_mutation: true
    test "maintenance refuses owner membership for #{@role}, INHERIT=#{@inherit}", c do
      sql!(
        Repo,
        "GRANT #{q(c.owner)} TO #{q(Map.fetch!(c, @role))} WITH INHERIT #{if @inherit, do: "TRUE", else: "FALSE"}, SET #{if @inherit, do: "FALSE", else: "TRUE"}"
      )

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: runtime or maintenance owner membership"
      )
    end
  end

  for defect <- [:support, :argument_default] do
    @defect defect
    @tag revision7: true
    @tag routine_executable_mutation: true
    test "executable pg_proc metadata rejects #{@defect}", c do
      signature = rel(c, "ash_onetime_cleanup_eligible") <> "(timestamptz)"

      if @defect == :support do
        sql!(Repo, "ALTER FUNCTION #{signature} SUPPORT pg_catalog.varchar_support")
      else
        definition =
          scalar(c.owner_repo, "SELECT pg_get_functiondef(#{literal(signature)}::regprocedure)")

        modified =
          String.replace(
            definition,
            "retain_until timestamp with time zone)",
            "retain_until timestamp with time zone DEFAULT now())"
          )

        assert modified != definition
        sql!(c.owner_repo, modified)
      end

      assert_refusal(
        c,
        "ash_onetime_cleanup_nonce",
        "1",
        "untrusted_dependency: #{if @defect == :support, do: "routine support", else: "routine executable trees"}"
      )
    end
  end

  @tag revision7: true
  @tag publication_filter_mutation: true
  test "publication membership permits no filter and refuses a row filter", c do
    publication = "ao_publication_" <> String.replace(Ecto.UUID.generate(), "-", "")
    on_exit(fn -> sql!(Repo, "DROP PUBLICATION IF EXISTS #{q(publication)}") end)

    sql!(
      c.owner_repo,
      "CREATE PUBLICATION #{q(publication)} FOR TABLE #{rel(c, "ash_onetime_nonce_claims")}"
    )

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1::integer)") ==
             0

    sql!(
      c.owner_repo,
      "ALTER PUBLICATION #{q(publication)} SET TABLE #{rel(c, "ash_onetime_nonce_claims")} WHERE (logical_partition='tenant')"
    )

    assert_refusal(
      c,
      "ash_onetime_cleanup_nonce",
      "1",
      "untrusted_dependency: publication row filter"
    )
  end

  @tag revision7: true
  @tag default_overload: true
  test "runtime cannot create a defaulted overload in the dedicated routine schema", c do
    assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
             SQL.query(
               c.runtime_repo,
               "CREATE FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(batch_size integer,extra integer DEFAULT 0) RETURNS bigint LANGUAGE sql AS 'SELECT 0::bigint'",
               []
             )

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1::integer)") ==
             0
  end

  @tag revision7: true
  @tag legacy_install: true
  test "upgrade ignores unrelated preexisting routine overloads", c do
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(bigint) RETURNS bigint LANGUAGE sql AS 'SELECT 0::bigint'"
    )

    with_upgrade(c, fn ->
      assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1::integer)") ==
               0

      assert %{"acl" => true, "definers" => true, "trust" => true} =
               scalar(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'"
               )
    end)
  end

  defp month_start(offset) do
    today = Date.utc_today()
    index = today.year * 12 + today.month - 1 + offset
    Date.new!(div(index, 12), rem(index, 12) + 1, 1) |> Date.to_iso8601()
  end

  for stage <- [:move, :attach, :policy] do
    @stage stage
    @tag recovery_failure: true
    test "DEFAULT recovery failure at #{@stage} changes no rows, partitions, flags, ACLs, or records",
         c do
      default = rel(c, "ash_onetime_response_payloads_default")
      sql!(c.owner_repo, "ALTER TABLE #{default} ENABLE ROW LEVEL SECURITY")
      sql!(c.owner_repo, "ALTER TABLE #{default} FORCE ROW LEVEL SECURITY")

      for offset <- [-3, 18] do
        sql!(
          Repo,
          "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} VALUES ('tenant','#{month_start(offset)}',gen_random_uuid(),decode('beef','hex'))"
        )
      end

      month = month_start(-3) |> Date.from_iso8601!()

      name =
        "ash_onetime_response_payloads_#{month.year}_#{String.pad_leading(to_string(month.month), 2, "0")}"

      event = "ao_inject_" <> String.replace(c.schema, "ao_maintenance_", "")

      sql!(
        Repo,
        "CREATE FUNCTION #{rel(c, "fail_move")}() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''injected move''; END'"
      )

      operation =
        case @stage do
          :move ->
            "IF cmd.command_tag='CREATE TABLE' AND cmd.objid=to_regclass(#{literal(rel(c, name))}) THEN EXECUTE format('CREATE TRIGGER injected BEFORE INSERT ON %s FOR EACH ROW EXECUTE FUNCTION %I.fail_move()',cmd.objid::regclass,#{literal(c.schema)}); END IF;"

          :attach ->
            "IF cmd.command_tag='ALTER TABLE' AND EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid=to_regclass(#{literal(rel(c, name))}) AND inhparent='#{rel(c, "ash_onetime_response_payloads")}'::regclass) THEN RAISE EXCEPTION 'injected attach'; END IF;"

          :policy ->
            "IF cmd.command_tag='CREATE POLICY' AND EXISTS(SELECT 1 FROM pg_policy WHERE oid=cmd.objid AND polrelid=to_regclass(#{literal(rel(c, name))})) THEN RAISE EXCEPTION 'injected policy'; END IF;"
        end

      body =
        "DECLARE cmd record; BEGIN FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP IF cmd.schema_name=#{literal(c.schema)} OR cmd.classid='pg_policy'::regclass THEN #{operation} END IF; END LOOP; END"

      sql!(
        Repo,
        "CREATE FUNCTION #{rel(c, "inject")}() RETURNS event_trigger LANGUAGE plpgsql AS #{literal(body)}"
      )

      sql!(
        Repo,
        "CREATE EVENT TRIGGER #{q(event)} ON ddl_command_end EXECUTE FUNCTION #{rel(c, "inject")}()"
      )

      on_exit(fn -> SQL.query!(Repo, "DROP EVENT TRIGGER #{q(event)}", []) end)

      before_rows =
        SQL.query!(
          Repo,
          "SELECT * FROM #{rel(c, "ash_onetime_response_payloads")} ORDER BY partition_date,claim_id",
          []
        ).rows

      before_parts =
        SQL.query!(
          Repo,
          "SELECT c.oid,c.relacl::text,c.relforcerowsecurity FROM pg_class c JOIN pg_inherits i ON i.inhrelid=c.oid WHERE i.inhparent='#{rel(c, "ash_onetime_response_payloads")}'::regclass ORDER BY c.oid",
          []
        ).rows

      assert {:error, %Postgrex.Error{postgres: %{code: :raise_exception, message: message}}} =
               SQL.query(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(24)",
                 []
               )

      assert message =~ "injected"

      assert SQL.query!(
               Repo,
               "SELECT * FROM #{rel(c, "ash_onetime_response_payloads")} ORDER BY partition_date,claim_id",
               []
             ).rows == before_rows

      assert SQL.query!(
               Repo,
               "SELECT c.oid,c.relacl::text,c.relforcerowsecurity FROM pg_class c JOIN pg_inherits i ON i.inhrelid=c.oid WHERE i.inhparent='#{rel(c, "ash_onetime_response_payloads")}'::regclass ORDER BY c.oid",
               []
             ).rows == before_parts

      refute scalar(
               Repo,
               "SELECT EXISTS(SELECT 1 FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE step='roll' AND last_success_at IS NOT NULL)"
             )
    end
  end

  for order <- [:lock_then_check, :check_then_lock] do
    @order order
    @tag lock_order: true
    test "advisory barrier proves #{@order} and runtime DML concurrency", c do
      {:ok, ddl_repo} = subject(c.owner)
      {:ok, dml_repo} = subject(c.runtime)

      sql!(
        c.runtime_repo,
        "CREATE FUNCTION #{rel(c, "race_trigger")}() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); PERFORM set_config(''ash_onetime.probe_role'',current_user,false); RETURN NEW; END'"
      )

      original =
        scalar(
          c.owner_repo,
          "SELECT prosrc FROM pg_proc WHERE oid='#{rel(c, "ash_onetime_cleanup_nonce")}(integer)'::regprocedure"
        )

      [lock_line] =
        Regex.run(
          ~r/PERFORM [^;]+\.ash_onetime_maintenance_lock\(false(?:::boolean)?,\s*5000(?:::integer)?\);/,
          original
        )

      [trust_line] = Regex.run(~r/PERFORM [^;]+\.ash_onetime_maintenance_trust\(\);/, original)
      barrier = "PERFORM pg_catalog.pg_advisory_xact_lock(19284,99);"

      body =
        if @order == :lock_then_check do
          String.replace(original, lock_line, lock_line <> barrier)
        else
          original
          |> String.replace(trust_line, "")
          |> String.replace(lock_line, trust_line <> barrier <> lock_line)
        end

      sql!(
        c.owner_repo,
        "CREATE OR REPLACE FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(batch_size integer) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET DateStyle='ISO, YMD' SET row_security=on SET lock_timeout='5s' AS #{literal(body)}"
      )

      reseal_fixture_routine(c, "ash_onetime_cleanup_nonce(integer)")

      Repo.checkout(fn ->
        sql!(Repo, "SELECT pg_advisory_lock(19284,99)")

        worker =
          Task.async(fn ->
            SQL.query(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(100)", [])
          end)

        try do
          eventually(fn ->
            scalar(
              Repo,
              "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=19284 AND objid=99 AND NOT granted)"
            )
          end)

          sql!(ddl_repo, "SET lock_timeout='100ms'")

          if @order == :lock_then_check do
            for table <- [
                  "ash_onetime_idempotency_claims",
                  "ash_onetime_nonce_claims",
                  "ash_onetime_response_payloads",
                  "ash_onetime_response_payloads_default",
                  "ash_onetime_maintenance_runs"
                ] do
              assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                       SQL.query(
                         ddl_repo,
                         "CREATE TRIGGER race BEFORE INSERT OR UPDATE ON #{rel(c, table)} FOR EACH ROW EXECUTE FUNCTION #{rel(c, "race_trigger")}()",
                         []
                       )
            end

            sql!(dml_repo, "SET ash_onetime.tenant='own'")

            sql!(
              dml_repo,
              "INSERT INTO #{rel(c, "ash_onetime_nonce_claims")} (id,logical_partition,operation_hash,scope_hash,key_hash,issued_at,verifier_id,admitted_at,retain_until,inserted_at) VALUES (gen_random_uuid(),'own',decode(repeat('01',32),'hex'),decode(repeat('02',32),'hex'),decode(repeat('03',32),'hex'),now(),'test',now(),now()+interval '1 day',now())"
            )
          else
            sql!(
              ddl_repo,
              "CREATE TRIGGER race BEFORE INSERT OR UPDATE ON #{rel(c, "ash_onetime_maintenance_runs")} FOR EACH ROW EXECUTE FUNCTION #{rel(c, "race_trigger")}()"
            )
          end
        after
          sql!(Repo, "SELECT pg_advisory_unlock(19284,99)")
        end

        assert {:ok, _} = Task.await(worker, 30_000)

        if @order == :lock_then_check do
          assert scalar(
                   Repo,
                   "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
                 ) == 0
        else
          assert scalar(c.runtime_repo, "SELECT current_setting('ash_onetime.probe_role',true)") ==
                   c.owner

          sql!(c.runtime_repo, "SELECT pg_advisory_unlock_all()")
        end
      end)
    end
  end

  defp eventually(predicate, attempts \\ 500)
  defp eventually(_predicate, 0), do: flunk("database barrier did not arrive")

  defp eventually(predicate, attempts) do
    unless predicate.() do
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp assert_refusal(c, name, args, reason) do
    assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} =
             SQL.query(c.runtime_repo, "SELECT #{rel(c, name)}(#{args})", [])

    case reason do
      %Regex{} -> assert message =~ reason
      _ -> assert message == reason
    end
  end

  defp maintain_diagnostic(c, holder) do
    ~r/\Auntrusted_dependency: effective MAINTAIN privilege on #{Regex.escape(c.schema)}\.ash_onetime_[a-z_0-9]+ for role (?:#{Regex.escape(holder)}|#{Regex.escape(c.runtime)})\z/
  end

  for {row, kind} <- [
        {1, :trigger},
        {2, :child_trigger},
        {3, :constraint_trigger},
        {4, :rule},
        {6, :default},
        {7, :generated},
        {8, :check},
        {11, :index},
        {12, :operator},
        {13, :operator_family},
        {19, :routine},
        {9, :foreign_key},
        {10, :constraint_index},
        {14, :cast},
        {15, :base_type},
        {15, :typmod},
        {16, :domain},
        {17, :range},
        {18, :collation},
        {20, :planner_support},
        {21, :aggregate},
        {22, :access_method},
        {23, :foreign_table},
        {25, :extension_member},
        {26, :statistics},
        {28, :partition_expression},
        {29, :sequence},
        {30, :language},
        {31, :text_search},
        {32, :conversion}
      ] do
    @row row
    @kind kind
    @tag maintenance_shape_mutation: true
    @tag [{String.to_atom("shape_#{kind}_mutation"), true}]
    @tag if(kind == :default, do: [normalize_location_mutation: true], else: [])
    test "Table 1 row #{@row}: #{@kind} refuses before owner code runs", c do
      table =
        case @kind do
          kind when kind in [:base_type, :domain, :range, :typmod] ->
            "ash_onetime_maintenance_runs"

          kind when kind in [:partition_expression, :foreign_table] ->
            "ash_onetime_response_payloads"

          :child_trigger ->
            "ash_onetime_response_payloads_default"

          _ ->
            "ash_onetime_nonce_claims"
        end

      before =
        scalar(
          c.owner_repo,
          "SELECT #{rel(c, "ash_onetime_maintenance_shape")}('#{rel(c, table)}'::regclass::oid)"
        )

      if @kind == :default, do: assert_normalized_locations(c)
      install_dependency(c, @kind)

      if @kind in [
           :base_type,
           :typmod,
           :collation,
           :default,
           :operator_family,
           :access_method,
           :index,
           :check
         ] do
        after_shape =
          scalar(
            c.owner_repo,
            "SELECT #{rel(c, "ash_onetime_maintenance_shape")}('#{rel(c, table)}'::regclass::oid)"
          )

        refute compared_field(before, @kind) == compared_field(after_shape, @kind)
      end

      if @kind != :foreign_table do
        assert_refusal(
          c,
          "ash_onetime_cleanup_nonce",
          "100",
          "untrusted_dependency: relation shape #{table}"
        )
      end

      if @kind in [:trigger, :child_trigger, :constraint_trigger] do
        for {name, args} <- calls(),
            name != "ash_onetime_cleanup_nonce" and name != "ash_onetime_maintenance_status" do
          assert_refusal(c, name, args, "untrusted_dependency: relation shape #{table}")
        end

        assert scalar(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->>'trust'"
               ) == "false"
      end

      assert scalar(
               Repo,
               "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
             ) == 0
    end
  end

  defp assert_normalized_locations(c) do
    table = rel(c, "ash_onetime_nonce_claims")

    tree =
      scalar(
        c.owner_repo,
        "SELECT adbin::text FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid=d.adrelid AND a.attnum=d.adnum WHERE d.adrelid='#{table}'::regclass AND a.attname='logical_partition'"
      )

    # PostgreSQL 17+ serializes locations as -1; vary only that field in a real catalog tree.
    located = String.replace(tree, ":location -1", ":location 42")
    refute located == tree

    normalize = fn value ->
      scalar(
        c.owner_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_normalize")}(#{literal(value)},'#{table}'::regclass::oid)"
      )
    end

    assert normalize.(located) == normalize.(tree)
  end

  defp compared_field(shape, kind) do
    {section, field} =
      case kind do
        :base_type -> {"columns", "type"}
        :typmod -> {"columns", "typmod"}
        :collation -> {"columns", "collation"}
        :default -> {"columns", "default"}
        :operator_family -> {"indexes", "opclasses"}
        :access_method -> {"indexes", "am"}
        :index -> {"indexes", "expressions"}
        :check -> {"constraints", "expression"}
      end

    shape[section] |> Enum.map(&Map.get(&1, field)) |> Enum.sort()
  end

  defp replace_package_check(c, expression) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} DROP CONSTRAINT ash_onetime_nonce_claims_verifier_id_check"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD CONSTRAINT ash_onetime_nonce_claims_verifier_id_check CHECK (octet_length(verifier_id) BETWEEN 1 AND 128 AND (#{expression}))"
    )
  end

  defp install_dependency(c, kind) do
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      Repo.checkout(fn -> install_dependency_ddl(c, kind) end)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp install_dependency_ddl(c, kind) do
    probe = rel(c, "probe")

    sql!(
      c.owner_repo,
      "CREATE FUNCTION #{probe}() RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS 'BEGIN PERFORM pg_catalog.pg_advisory_lock(19283,42); RETURN true; END'"
    )

    dependency_ddl(c, kind)

    sql!(c.owner_repo, "SELECT pg_advisory_unlock_all()")
  end

  defp dependency_ddl(c, :trigger) do
    claims = rel(c, "ash_onetime_nonce_claims")

    trigger(c, claims, false)
  end

  defp dependency_ddl(c, :child_trigger) do
    # Payload children have no existing trigger to replace.
    trigger(c, rel(c, "ash_onetime_response_payloads_default"), false)
  end

  defp dependency_ddl(c, :constraint_trigger) do
    claims = rel(c, "ash_onetime_nonce_claims")

    trigger(c, claims, true)
  end

  defp dependency_ddl(c, :rule) do
    # The package has no rewrite rule to replace.
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(
      c.owner_repo,
      "CREATE RULE hostile AS ON DELETE TO #{claims} DO ALSO SELECT #{probe}()"
    )
  end

  defp dependency_ddl(c, :default) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ALTER COLUMN logical_partition SET DEFAULT CASE WHEN #{probe}() THEN 'global' ELSE 'other' END"
    )
  end

  defp dependency_ddl(c, :generated) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    # PostgreSQL cannot convert an ordinary column to generated; recreate its existing name.
    sql!(c.owner_repo, "ALTER TABLE #{claims} DROP COLUMN verifier_id CASCADE")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD COLUMN verifier_id text NOT NULL GENERATED ALWAYS AS (CASE WHEN #{probe}() THEN 'generated' ELSE 'other' END) STORED"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD CONSTRAINT ash_onetime_nonce_claims_verifier_id_check CHECK (octet_length(verifier_id) BETWEEN 1 AND 128)"
    )
  end

  defp dependency_ddl(c, :check) do
    probe = rel(c, "probe")

    replace_package_check(c, "#{probe}()")
  end

  defp dependency_ddl(c, :index) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(c.owner_repo, "DROP INDEX #{rel(c, "ash_onetime_nonce_claims_retain_until_index")}")

    sql!(
      c.owner_repo,
      "CREATE INDEX ash_onetime_nonce_claims_retain_until_index ON #{claims} ((CASE WHEN #{probe}() THEN retain_until ELSE retain_until END))"
    )
  end

  defp dependency_ddl(c, :routine) do
    probe = rel(c, "probe")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "inner_probe")}() RETURNS boolean LANGUAGE sql AS 'SELECT true'"
    )

    sql!(
      c.owner_repo,
      "CREATE OR REPLACE FUNCTION #{probe}() RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS 'BEGIN RETURN #{rel(c, "inner_probe")}(); END'"
    )

    replace_package_check(c, "#{probe}()")
  end

  defp dependency_ddl(c, :operator) do
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "comparison")}(integer,integer) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS 'BEGIN PERFORM pg_catalog.pg_advisory_lock(19283,42); RETURN true; END'"
    )

    sql!(
      c.runtime_repo,
      "CREATE OPERATOR #{q(c.schema)}.=== (LEFTARG=integer, RIGHTARG=integer, FUNCTION=#{rel(c, "comparison")})"
    )

    replace_package_check(c, "octet_length(verifier_id) OPERATOR(#{q(c.schema)}.===) 1")
  end

  defp dependency_ddl(c, :operator_family) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "comparison")}(timestamptz,timestamptz) RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT CASE WHEN $1 < $2 THEN -1 WHEN $1 > $2 THEN 1 ELSE 0 END'"
    )

    sql!(
      Repo,
      "CREATE OPERATOR CLASS #{q(c.schema)}.hostile_ops FOR TYPE timestamptz USING btree AS OPERATOR 1 < (timestamptz,timestamptz), OPERATOR 2 <= (timestamptz,timestamptz), OPERATOR 3 = (timestamptz,timestamptz), OPERATOR 4 >= (timestamptz,timestamptz), OPERATOR 5 > (timestamptz,timestamptz), FUNCTION 1 #{rel(c, "comparison")}(timestamptz,timestamptz)"
    )

    sql!(c.owner_repo, "DROP INDEX #{rel(c, "ash_onetime_nonce_claims_retain_until_index")}")

    sql!(
      c.owner_repo,
      "CREATE INDEX ash_onetime_nonce_claims_retain_until_index ON #{claims} (retain_until #{q(c.schema)}.hostile_ops)"
    )
  end

  defp dependency_ddl(c, :foreign_key) do
    # The package has no foreign key; exercise an incoming reference to its existing id.
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(
      c.owner_repo,
      "CREATE TABLE #{rel(c, "referencing")} (id uuid REFERENCES #{claims}(id) ON DELETE CASCADE)"
    )
  end

  defp dependency_ddl(c, :constraint_index) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "uuid_compare")}(uuid,uuid) RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT uuid_cmp($1,$2)'"
    )

    sql!(
      Repo,
      "CREATE OPERATOR CLASS #{rel(c, "uuid_ops")} FOR TYPE uuid USING btree AS OPERATOR 1 < (uuid,uuid), OPERATOR 2 <= (uuid,uuid), OPERATOR 3 = (uuid,uuid), OPERATOR 4 >= (uuid,uuid), OPERATOR 5 > (uuid,uuid), FUNCTION 1 #{rel(c, "uuid_compare")}(uuid,uuid)"
    )

    sql!(c.owner_repo, "ALTER TABLE #{claims} DROP CONSTRAINT ash_onetime_nonce_claims_pkey")

    sql!(
      c.owner_repo,
      "CREATE UNIQUE INDEX ash_onetime_nonce_claims_pkey ON #{claims} (id #{rel(c, "uuid_ops")})"
    )

    # PostgreSQL forbids adopting a nondefault-opclass index as a PRIMARY KEY.
    assert {:error, %Postgrex.Error{postgres: %{pg_code: "42809", message: message}}} =
             SQL.query(
               c.owner_repo,
               "ALTER TABLE #{claims} ADD CONSTRAINT ash_onetime_nonce_claims_pkey PRIMARY KEY USING INDEX ash_onetime_nonce_claims_pkey",
               []
             )

    assert message ==
             "index \"ash_onetime_nonce_claims_pkey\" column number 1 does not have default sorting behavior"
  end

  defp dependency_ddl(c, :cast) do
    sql!(c.runtime_repo, "CREATE TYPE #{rel(c, "hostile_type")} AS ENUM ('value')")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "cast_probe")}(#{rel(c, "hostile_type")}) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN true; END'"
    )

    sql!(
      c.runtime_repo,
      "CREATE CAST (#{rel(c, "hostile_type")} AS boolean) WITH FUNCTION #{rel(c, "cast_probe")}(#{rel(c, "hostile_type")})"
    )

    replace_package_check(c, "'value'::#{rel(c, "hostile_type")}::boolean")
  end

  defp dependency_ddl(c, :base_type) do
    claims = rel(c, "ash_onetime_maintenance_runs")

    # Preserve the built-in C input/output strictness when casting the existing nullable column.
    sql!(Repo, "CREATE TYPE #{rel(c, "hostile_type")}")

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "type_input")}(cstring) RETURNS #{rel(c, "hostile_type")} LANGUAGE internal IMMUTABLE STRICT AS 'textin'"
    )

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "type_output")}(#{rel(c, "hostile_type")}) RETURNS cstring LANGUAGE internal IMMUTABLE STRICT AS 'textout'"
    )

    sql!(
      Repo,
      "CREATE TYPE #{rel(c, "hostile_type")} (INPUT=#{rel(c, "type_input")},OUTPUT=#{rel(c, "type_output")},INTERNALLENGTH=variable,ALIGNMENT=int4,STORAGE=extended)"
    )

    sql!(Repo, "ALTER FUNCTION #{rel(c, "type_input")}(cstring) OWNER TO #{q(c.runtime)}")

    sql!(
      Repo,
      "ALTER FUNCTION #{rel(c, "type_output")}(#{rel(c, "hostile_type")}) OWNER TO #{q(c.runtime)}"
    )

    sql!(Repo, "ALTER TYPE #{rel(c, "hostile_type")} OWNER TO #{q(c.runtime)}")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ALTER COLUMN installed_at TYPE #{rel(c, "hostile_type")} USING NULL"
    )
  end

  defp dependency_ddl(c, :domain) do
    claims = rel(c, "ash_onetime_maintenance_runs")
    probe = rel(c, "probe")

    sql!(
      c.owner_repo,
      "CREATE DOMAIN #{rel(c, "hostile_type")} AS timestamptz CHECK (#{probe}())"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ALTER COLUMN installed_at TYPE #{rel(c, "hostile_type")} USING installed_at::#{rel(c, "hostile_type")}"
    )
  end

  defp dependency_ddl(c, :range) do
    claims = rel(c, "ash_onetime_maintenance_runs")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "range_diff")}(integer,integer) RETURNS float8 LANGUAGE sql IMMUTABLE AS 'SELECT ($1::float8-$2::float8)'"
    )

    sql!(
      c.runtime_repo,
      "CREATE TYPE #{rel(c, "hostile_type")} AS RANGE (SUBTYPE=integer,SUBTYPE_DIFF=#{rel(c, "range_diff")})"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ALTER COLUMN installed_at TYPE #{rel(c, "hostile_type")} USING NULL"
    )
  end

  defp dependency_ddl(c, :typmod) do
    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_maintenance_runs")} ALTER COLUMN installed_at TYPE timestamptz(3)"
    )
  end

  defp dependency_ddl(c, :collation) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(c.runtime_repo, "CREATE COLLATION #{rel(c, "hostile_collation")} FROM \"C\"")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ALTER COLUMN verifier_id TYPE text COLLATE #{rel(c, "hostile_collation")}"
    )
  end

  defp dependency_ddl(c, :planner_support) do
    probe = rel(c, "probe")

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "planner")}(internal) RETURNS internal LANGUAGE internal AS 'varchar_support'"
    )

    sql!(Repo, "ALTER FUNCTION #{rel(c, "planner")}(internal) OWNER TO #{q(c.runtime)}")
    sql!(Repo, "ALTER FUNCTION #{probe}() SUPPORT #{rel(c, "planner")}")
    replace_package_check(c, "#{probe}()")
  end

  defp dependency_ddl(c, :aggregate) do
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "transition")}(integer,integer) RETURNS integer LANGUAGE plpgsql IMMUTABLE AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN $1+$2; END'"
    )

    sql!(
      c.owner_repo,
      "CREATE AGGREGATE #{rel(c, "aggregate_probe")}(integer) (SFUNC=#{rel(c, "transition")},STYPE=integer,INITCOND='0')"
    )

    sql!(
      c.owner_repo,
      "CREATE FUNCTION #{rel(c, "aggregate_check")}() RETURNS boolean LANGUAGE sql BEGIN ATOMIC SELECT #{rel(c, "aggregate_probe")}(1)>0; END"
    )

    replace_package_check(c, "#{rel(c, "aggregate_check")}()")
  end

  defp dependency_ddl(c, :access_method) do
    claims = rel(c, "ash_onetime_nonce_claims")

    am = "ao_am_" <> String.replace(c.schema, "ao_maintenance_", "")

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "index_handler")}(internal) RETURNS index_am_handler LANGUAGE internal AS 'bthandler'"
    )

    sql!(Repo, "ALTER FUNCTION #{rel(c, "index_handler")}(internal) OWNER TO #{q(c.runtime)}")
    sql!(Repo, "CREATE ACCESS METHOD #{q(am)} TYPE INDEX HANDLER #{rel(c, "index_handler")}")
    on_exit(fn -> SQL.query!(Repo, "DROP ACCESS METHOD #{q(am)} CASCADE", []) end)

    sql!(
      Repo,
      "CREATE OPERATOR CLASS #{rel(c, "am_ops")} DEFAULT FOR TYPE timestamptz USING #{q(am)} AS OPERATOR 1 < (timestamptz,timestamptz), OPERATOR 2 <= (timestamptz,timestamptz), OPERATOR 3 = (timestamptz,timestamptz), OPERATOR 4 >= (timestamptz,timestamptz), OPERATOR 5 > (timestamptz,timestamptz), FUNCTION 1 timestamptz_cmp(timestamptz,timestamptz)"
    )

    sql!(c.owner_repo, "DROP INDEX #{rel(c, "ash_onetime_nonce_claims_retain_until_index")}")

    sql!(
      c.owner_repo,
      "CREATE INDEX ash_onetime_nonce_claims_retain_until_index ON #{claims} USING #{q(am)}(retain_until)"
    )
  end

  defp dependency_ddl(c, :foreign_table) do
    # PostgreSQL cannot convert a package heap to foreign; foreign partitions also require dropping the parent PK.
    probe = rel(c, "probe")

    fdw = "ao_fdw_" <> String.replace(c.schema, "ao_maintenance_", "")
    sql!(Repo, "CREATE EXTENSION IF NOT EXISTS postgres_fdw")
    on_exit(fn -> SQL.query!(Repo, "DROP EXTENSION IF EXISTS postgres_fdw CASCADE", []) end)

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "fdw_validator")}(text[],oid) RETURNS void LANGUAGE C AS '$libdir/postgres_fdw', 'postgres_fdw_validator'"
    )

    sql!(
      Repo,
      "ALTER FUNCTION #{rel(c, "fdw_validator")}(text[],oid) OWNER TO #{q(c.runtime)}"
    )

    sql!(
      Repo,
      "CREATE FOREIGN DATA WRAPPER #{q(fdw)} HANDLER postgres_fdw_handler VALIDATOR #{rel(c, "fdw_validator")}"
    )

    sql!(Repo, "GRANT USAGE ON FOREIGN DATA WRAPPER #{q(fdw)} TO #{q(c.owner)}")
    on_exit(fn -> SQL.query!(Repo, "DROP FOREIGN DATA WRAPPER #{q(fdw)} CASCADE", []) end)

    sql!(
      c.owner_repo,
      "CREATE SERVER #{q(fdw)} FOREIGN DATA WRAPPER #{q(fdw)} OPTIONS(host '127.0.0.1')"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_response_payloads")} DROP CONSTRAINT ash_onetime_response_payloads_pkey"
    )

    sql!(
      c.owner_repo,
      "CREATE FOREIGN TABLE #{rel(c, "foreign_child")} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{month_start(-6)}') TO ('#{month_start(-5)}') SERVER #{q(fdw)} OPTIONS(table_name 'unreachable')"
    )

    # Cleanup's policy check is separately proven. Prune must inspect the
    # foreign child's handler/validator without contacting its server.
    assert_refusal(
      c,
      "ash_onetime_prune_payload_partitions",
      "8,2000",
      "untrusted_dependency: relation shape ash_onetime_response_payloads"
    )

    replace_package_check(c, "#{probe}()")
  end

  defp dependency_ddl(c, :extension_member) do
    probe = rel(c, "probe")

    sql!(Repo, "ALTER EXTENSION plpgsql ADD FUNCTION #{probe}()")

    on_exit(fn ->
      SQL.query!(Repo, "ALTER EXTENSION plpgsql DROP FUNCTION #{probe}()", [])
    end)

    replace_package_check(c, "#{probe}()")
  end

  defp dependency_ddl(c, :statistics) do
    # The package has no extended statistic to replace.
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(
      c.owner_repo,
      "CREATE STATISTICS #{rel(c, "hostile_stats")} ON (#{probe}()),verifier_id FROM #{claims}"
    )
  end

  defp dependency_ddl(c, :partition_expression) do
    # PostgreSQL cannot ALTER a partition key; a nested partition is the available hostile link.
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "partition_key")}(date) RETURNS date LANGUAGE plpgsql IMMUTABLE AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN $1; END'"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_response_payloads")} DROP CONSTRAINT ash_onetime_response_payloads_pkey"
    )

    sql!(
      c.owner_repo,
      "CREATE TABLE #{rel(c, "nested")} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{month_start(-6)}') TO ('#{month_start(-5)}') PARTITION BY RANGE (#{rel(c, "partition_key")}(partition_date))"
    )

    sql!(
      c.owner_repo,
      "SELECT #{rel(c, "ash_onetime_maintenance_copy_policy")}('#{rel(c, "nested")}'::regclass)"
    )

    sql!(
      c.owner_repo,
      "SELECT #{rel(c, "ash_onetime_maintenance_reset_acl")}('#{rel(c, "nested")}'::regclass,true)"
    )
  end

  defp dependency_ddl(c, :sequence) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(c.runtime_repo, "CREATE SEQUENCE #{rel(c, "hostile_sequence")}")

    sql!(
      c.runtime_repo,
      "GRANT USAGE ON SEQUENCE #{rel(c, "hostile_sequence")} TO #{q(c.owner)}"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ALTER COLUMN logical_partition SET DEFAULT nextval('#{rel(c, "hostile_sequence")}')::text"
    )
  end

  defp dependency_ddl(c, :language) do
    language = "ao_lang_" <> String.replace(c.schema, "ao_maintenance_", "")

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "language_handler")}() RETURNS language_handler LANGUAGE C AS '$libdir/plpgsql', 'plpgsql_call_handler'"
    )

    sql!(Repo, "ALTER FUNCTION #{rel(c, "language_handler")}() OWNER TO #{q(c.runtime)}")

    sql!(
      Repo,
      "CREATE TRUSTED LANGUAGE #{q(language)} HANDLER #{rel(c, "language_handler")} VALIDATOR plpgsql_validator"
    )

    on_exit(fn -> SQL.query!(Repo, "DROP LANGUAGE #{q(language)} CASCADE", []) end)

    sql!(
      c.owner_repo,
      "CREATE FUNCTION #{rel(c, "language_probe")}() RETURNS boolean LANGUAGE #{q(language)} AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN true; END'"
    )

    replace_package_check(c, "#{rel(c, "language_probe")}()")
  end

  defp dependency_ddl(c, :text_search) do
    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "lexize")}(internal,internal,internal,internal) RETURNS internal LANGUAGE internal AS 'dsimple_lexize'"
    )

    sql!(
      Repo,
      "ALTER FUNCTION #{rel(c, "lexize")}(internal,internal,internal,internal) OWNER TO #{q(c.runtime)}"
    )

    sql!(
      Repo,
      "CREATE TEXT SEARCH TEMPLATE #{rel(c, "hostile_template")} (INIT=dsimple_init,LEXIZE=#{rel(c, "lexize")})"
    )

    sql!(
      c.owner_repo,
      "CREATE TEXT SEARCH DICTIONARY #{rel(c, "hostile_dictionary")} (TEMPLATE=#{rel(c, "hostile_template")})"
    )

    sql!(
      c.owner_repo,
      "CREATE TEXT SEARCH CONFIGURATION #{rel(c, "hostile_configuration")} (COPY=pg_catalog.simple)"
    )

    sql!(
      c.owner_repo,
      "ALTER TEXT SEARCH CONFIGURATION #{rel(c, "hostile_configuration")} ALTER MAPPING FOR asciiword WITH #{rel(c, "hostile_dictionary")}"
    )

    replace_package_check(
      c,
      "to_tsvector('#{rel(c, "hostile_configuration")}'::regconfig,verifier_id) IS NOT NULL"
    )
  end

  defp dependency_ddl(c, :conversion) do
    probe = rel(c, "probe")

    definition =
      scalar(
        Repo,
        "SELECT pg_get_functiondef(conproc) FROM pg_conversion WHERE connamespace='pg_catalog'::regnamespace AND conforencoding=pg_char_to_encoding('UTF8') AND contoencoding=pg_char_to_encoding('LATIN1') LIMIT 1"
      )

    definition =
      Regex.replace(
        ~r/CREATE OR REPLACE FUNCTION [^(]+/,
        definition,
        "CREATE FUNCTION #{rel(c, "converter")}"
      )

    sql!(Repo, definition)

    signature =
      scalar(
        Repo,
        "SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=#{literal(c.schema)} AND p.proname='converter'"
      )

    sql!(Repo, "ALTER FUNCTION #{signature} OWNER TO #{q(c.runtime)}")

    sql!(
      c.runtime_repo,
      "CREATE DEFAULT CONVERSION #{rel(c, "hostile_conversion")} FOR 'UTF8' TO 'LATIN1' FROM #{rel(c, "converter")}"
    )

    # A string-body routine can choose a conversion at execution time.
    # The closed allowlist rejects it before its body can run; the
    # typed edge also proves the conversion's conproc is inventoried.
    assert scalar(
             c.owner_repo,
             "SELECT EXISTS(SELECT 1 FROM #{rel(c, "ash_onetime_maintenance_edges")}('pg_conversion'::regclass,(SELECT oid FROM pg_conversion WHERE connamespace=#{literal(c.schema)}::regnamespace AND conname='hostile_conversion')) WHERE classid='pg_proc'::regclass AND objectid='#{signature}'::regprocedure)"
           )

    sql!(
      c.owner_repo,
      "CREATE OR REPLACE FUNCTION #{probe}() RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS #{literal("BEGIN PERFORM pg_advisory_lock(19283,42); PERFORM set_config('search_path'," <> literal(c.schema <> ",pg_catalog") <> ",true); PERFORM convert_to('value','LATIN1'); RETURN true; END")}"
    )

    replace_package_check(c, "#{probe}()")
  end

  @tag collision: true
  @tag revision7: true
  test "Table 1 row 33: roll refuses a colliding standalone table without adopting or executing it",
       c do
    month = month_start(18) |> Date.from_iso8601!()

    name =
      "ash_onetime_response_payloads_#{month.year}_#{String.pad_leading(to_string(month.month), 2, "0")}"

    sql!(
      c.runtime_repo,
      "CREATE TABLE #{rel(c, name)} (LIKE #{rel(c, "ash_onetime_response_payloads")} INCLUDING ALL)"
    )

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "hostile_trigger")}() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN NEW; END'"
    )

    sql!(
      c.runtime_repo,
      "CREATE TRIGGER hostile BEFORE INSERT ON #{rel(c, name)} FOR EACH ROW EXECUTE FUNCTION #{rel(c, "hostile_trigger")}()"
    )

    assert_refusal(
      c,
      "ash_onetime_roll_payload_partitions",
      "24",
      "untrusted_dependency: name collision"
    )

    assert scalar(
             Repo,
             "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
           ) == 0

    refute scalar(
             Repo,
             "SELECT EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid='#{rel(c, name)}'::regclass)"
           )
  end

  defp trigger(c, table, constraint?) do
    sql!(
      c.owner_repo,
      "CREATE FUNCTION #{rel(c, "hostile_trigger")}() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN PERFORM pg_catalog.pg_advisory_lock(19283,42); RETURN OLD; END'"
    )

    name =
      if table == rel(c, "ash_onetime_nonce_claims") do
        sql!(c.owner_repo, "DROP TRIGGER ash_onetime_nonce_delete_guard ON #{table}")
        "ash_onetime_nonce_delete_guard"
      else
        "hostile"
      end

    ddl =
      if constraint?,
        do:
          "CREATE CONSTRAINT TRIGGER #{name} AFTER DELETE ON #{table} DEFERRABLE INITIALLY DEFERRED",
        else: "CREATE TRIGGER #{name} BEFORE DELETE ON #{table}"

    sql!(c.owner_repo, ddl <> " FOR EACH ROW EXECUTE FUNCTION #{rel(c, "hostile_trigger")}()")
  end

  @tag revision7: true
  @tag maintenance_isolation_mutation: true
  test "SQL rejects NULL and out of range bounds and repeatable read", c do
    StoreCase.restore_fixture!(
      Repo,
      "INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,retain_until,inserted_at) VALUES (gen_random_uuid(),'ceiling',sha256('ceiling'),sha256('scope'),sha256('key'),sha256('fingerprint'),'processing','0001-01-01'::timestamptz,'0001-01-02'::timestamptz,'0001-01-01'::timestamptz)"
    )

    StoreCase.restore_fixture!(
      Repo,
      "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET effect_local=true WHERE logical_partition='ceiling'"
    )

    assert scalar(
             c.runtime_repo,
             "SELECT #{rel(c, "ash_onetime_reap_idempotency")}(1::integer,315576000000::bigint)"
           ) == 0

    assert scalar(
             Repo,
             "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE logical_partition='ceiling'"
           ) == 1

    for {name, args} <- [
          {"ash_onetime_cleanup_nonce", "NULL"},
          {"ash_onetime_cleanup_idempotency", "0"},
          {"ash_onetime_reap_idempotency", "1,NULL"},
          {"ash_onetime_cleanup_nonce", "10001"},
          {"ash_onetime_prune_payload_partitions", "NULL,1"},
          {"ash_onetime_prune_payload_partitions", "1,NULL"},
          {"ash_onetime_roll_payload_partitions", "NULL"},
          {"ash_onetime_roll_payload_partitions", "25"}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023"}}} =
               SQL.query(c.runtime_repo, "SELECT #{rel(c, name)}(#{args})", [])
    end

    for {name, args} <- Enum.reject(calls(), &(elem(&1, 0) == "ash_onetime_maintenance_status")) do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "25001"}}} =
               c.runtime_repo
               |> SQL.query("BEGIN ISOLATION LEVEL REPEATABLE READ", [])
               |> then(fn _ ->
                 try do
                   SQL.query(c.runtime_repo, "SELECT #{rel(c, name)}(#{args})", [])
                 after
                   sql!(c.runtime_repo, "ROLLBACK")
                 end
               end)
    end
  end

  defp with_authority_group(callback) do
    group = "ao_authority_#{System.unique_integer([:positive])}"
    sql!(Repo, "CREATE ROLE #{q(group)} NOLOGIN NOSUPERUSER NOBYPASSRLS")

    try do
      callback.(group)
    after
      sql!(Repo, "DROP OWNED BY #{q(group)}")
      sql!(Repo, "DROP ROLE #{q(group)}")
    end
  end

  defp subject(role, pool_size \\ 1) do
    {login, password} = Process.get({__MODULE__, :credential, role})

    url =
      System.fetch_env!("DATABASE_URL")
      |> URI.parse()
      |> Map.put(:userinfo, URI.encode_www_form(login) <> ":" <> URI.encode_www_form(password))
      |> URI.to_string()

    result =
      Repo.start_link(
        name: nil,
        url: url,
        pool: DBConnection.ConnectionPool,
        pool_size: pool_size,
        timeout: 180_000,
        after_connect: fn conn -> Postgrex.query!(conn, "SET ROLE #{q(role)}", []) end
      )

    {:ok, pid} = result
    Process.unlink(pid)
    on_exit(fn -> GenServer.stop(pid) end)

    assert SQL.query!(
             pid,
             "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user",
             []
           ).rows == [[false, false]]

    assert SQL.query!(
             pid,
             "SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname=session_user",
             []
           ).rows == [[false, false]]

    result
  end

  defp catalog_acls(c) do
    SQL.query!(
      Repo,
      """
      SELECT c.relname,coalesce(a.attname,''),x.grantor,x.grantee,x.privilege_type,bool_or(x.is_grantable)
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      LEFT JOIN pg_attribute a ON a.attrelid=c.oid AND a.attacl IS NOT NULL
      CROSS JOIN LATERAL aclexplode(CASE WHEN a.attname IS NULL THEN coalesce(c.relacl,acldefault('r',c.relowner)) ELSE a.attacl END) x
      WHERE n.nspname=$1 AND c.relname LIKE 'ash_onetime_%'
      GROUP BY c.relname,a.attname,x.grantor,x.grantee,x.privilege_type
      UNION ALL
      SELECT p.proname,'',x.grantor,x.grantee,x.privilege_type,bool_or(x.is_grantable)
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x
      WHERE n.nspname IN ($1,$2)
      GROUP BY p.proname,x.grantor,x.grantee,x.privilege_type
      ORDER BY 1,2,3,4,5
      """,
      [c.schema, routine_schema(c.schema)]
    ).rows
  end

  defp entry_points, do: Enum.map(calls(), &elem(&1, 0))

  defp calls,
    do: [
      {"ash_onetime_cleanup_idempotency", "100"},
      {"ash_onetime_cleanup_nonce", "100"},
      {"ash_onetime_reap_idempotency", "100,86400"},
      {"ash_onetime_expire_responses", "100"},
      {"ash_onetime_prune_payload_partitions", "8,2000"},
      {"ash_onetime_roll_payload_partitions", "6"},
      {"ash_onetime_maintenance_status", ""}
    ]

  defp routine_schema(schema),
    do:
      "ash_onetime_" <>
        binary_part(Base.encode16(:crypto.hash(:sha256, schema), case: :lower), 0, 48)

  defp q(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")

  defp rel(c, name) do
    routine? =
      String.starts_with?(name, [
        "ash_onetime_cleanup_",
        "ash_onetime_reap_",
        "ash_onetime_expire_",
        "ash_onetime_roll_",
        "ash_onetime_prune_",
        "ash_onetime_guard_",
        "ash_onetime_maintenance_"
      ]) and name != "ash_onetime_maintenance_runs"

    routine_schema = routine_schema(c.schema)

    schema =
      if routine? and
           scalar(c.owner_repo, "SELECT to_regnamespace(#{literal(routine_schema)}) IS NOT NULL"),
         do: routine_schema,
         else: c.schema

    q(schema) <> "." <> q(name)
  end

  defp sql!(repo, sql), do: SQL.query!(repo, sql, [])
  defp scalar(repo, sql), do: sql!(repo, sql).rows |> hd() |> hd()
end
