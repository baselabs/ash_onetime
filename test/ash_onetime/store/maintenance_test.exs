defmodule AshOnetime.Store.MaintenanceTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Store.Postgres
  alias AshOnetime.Store.Result
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  setup context do
    Sandbox.mode(Repo, :auto)
    suffix = Ecto.UUID.generate() |> String.replace("-", "")

    schema =
      if context[:quoted_schema], do: "ao_'\"$copy$#{suffix}", else: "ao_maintenance_#{suffix}"

    migration_schema = if context[:quoted_schema], do: "ao_ledger_#{suffix}", else: schema
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

    for role <- [owner, runtime, outsider, migrator] do
      login = if role == owner, do: migrator, else: role
      Process.put({__MODULE__, :credential, role}, {login, Map.fetch!(credentials, login)})
    end

    SQL.query!(
      Repo,
      "GRANT SELECT (starelid,staop1,staop2,staop3,staop4,staop5,stacoll1,stacoll2,stacoll3,stacoll4,stacoll5) ON pg_catalog.pg_statistic TO #{q(owner)}",
      []
    )

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
        EEx.eval_file("test/support/fixtures/maintenance_install.exs.eex",
          module: AshOnetime.Test.Repo.Migrations.InstallAshOnetime,
          hash_partitions: nil,
          response_partitions: [],
          collision_constraint:
            "UNIQUE (logical_partition, operation_hash, scope_hash, key_hash)",
          cleanup_comparator: ">",
          cleanup_delete_predicate:
            "claims.logical_partition=candidates.logical_partition AND claims.operation_hash=candidates.operation_hash AND claims.id=candidates.id"
        )
      else
        Generator.render(Repo,
          maintenance_role: maintainer,
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
        [c.schema, entry_points()]
      ).rows

    assert length(rows) == 6

    for [_name, definer, config, owner] <- rows do
      assert definer
      assert config == ["search_path=pg_catalog, pg_temp"]
      assert owner == c.owner
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
  test "maintenance upgrade replaces legacy grants and reverses to the invoker definitions", c do
    sql!(
      c.owner_repo,
      "GRANT EXECUTE ON FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(integer) TO #{q(c.owner)}, #{q(c.runtime)}, #{q(c.maintainer)}, #{q(c.outsider)}"
    )

    sql!(
      c.owner_repo,
      "GRANT SELECT (encoded_response) ON #{rel(c, "ash_onetime_response_payloads_default")} TO #{q(c.runtime)} WITH GRANT OPTION"
    )

    original_acls = catalog_acls(c)

    source =
      Generator.render_maintenance_upgrade(Repo, prefix: c.schema, maintenance_role: c.maintainer)

    [{module, _}] = Code.compile_string(source)
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      assert :ok =
               Ecto.Migrator.up(Repo, 20_261_113_000_002, module, prefix: c.schema, log: false)

      assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               SQL.query(c.outsider_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)", [])

      assert :ok =
               Ecto.Migrator.down(Repo, 20_261_113_000_002, module, prefix: c.schema, log: false)

      refute scalar(
               Repo,
               "SELECT prosecdef FROM pg_proc WHERE oid='#{rel(c, "ash_onetime_cleanup_nonce")}(integer)'::regprocedure"
             )

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
        Ecto.Migrator.up(Repo, 20_261_113_000_002, module, prefix: c.schema, log: false)
      end
    after
      Repo.put_dynamic_repo(previous)
      :code.purge(module)
      :code.delete(module)
    end
  end

  @tag legacy_install: true
  @tag transfer: true
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
               Ecto.Migrator.up(Repo, 20_261_113_000_002, module, prefix: c.schema, log: false)

      assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_nonce")}(1)") == 0
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
        sql!(Repo, """
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

    sql!(Repo, "ALTER TABLE #{rel(c, "old_other_owner")} OWNER TO #{q(c.runtime)}")
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
             "SELECT last_refusals->>'not_owner' FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE step='prune'"
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
        {20, "ALTER FUNCTION @schema@.ash_onetime_guard_nonce_delete() SUPPORT varchar_support"},
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

      assert_refusal(c, "ash_onetime_cleanup_nonce", "100", "maintenance_blinded")
      assert_refusal(c, "ash_onetime_cleanup_idempotency", "100", "maintenance_blinded")
      assert_refusal(c, "ash_onetime_reap_idempotency", "100,86400", "maintenance_blinded")

      assert scalar(
               c.runtime_repo,
               "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->>'policy'"
             ) == "false"
    end
  end

  for defect <- [:missing, :select_only, :wrong_role, :wrong_using, :restrictive] do
    @defect defect
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

      assert_refusal(c, "ash_onetime_cleanup_nonce", "1", "maintenance_blinded")
      assert_refusal(c, "ash_onetime_reap_idempotency", "1,86400", "maintenance_blinded")

      refute scalar(
               Repo,
               "SELECT EXISTS(SELECT 1 FROM #{rel(c, "ash_onetime_maintenance_runs")} WHERE last_success_at IS NOT NULL)"
             )
    end
  end

  test "Table 1 row 5: an owner-applicable policy cannot execute runtime-owned code", c do
    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "policy_probe")}() RETURNS boolean LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN true; END'"
    )

    sql!(
      c.owner_repo,
      "CREATE POLICY hostile_policy ON #{rel(c, "ash_onetime_nonce_claims")} AS RESTRICTIVE TO #{q(c.owner)} USING (#{rel(c, "policy_probe")}())"
    )

    assert_refusal(c, "ash_onetime_cleanup_nonce", "1", "maintenance_blinded")

    assert scalar(
             Repo,
             "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=19283 AND objid=42 AND granted"
           ) == 0
  end

  @tag builtin_dispatch: true
  @tag skip:
         "Release blocker: revision 6 trusts builtin SQL dispatchers; a catalog-only walk cannot see their SQL-string calls. Run with --include builtin_dispatch --include skip to reproduce owner execution."
  test "a builtin SQL dispatcher cannot hide a runtime routine in a default", c do
    inner = rel(c, "dispatched")
    sql!(c.runtime_repo, "CREATE FUNCTION #{inner}() RETURNS integer LANGUAGE sql AS 'SELECT 0'")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{rel(c, "ash_onetime_maintenance_runs")} ADD COLUMN extra_xml xml DEFAULT pg_catalog.query_to_xml(#{literal("SELECT " <> inner <> "()")},false,true,'')"
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
    assert message =~ "untrusted_dependency"

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

    assert scalar(c.runtime_repo, "SELECT #{q(second)}.ash_onetime_roll_payload_partitions(24)") >
             0

    first_status = scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_maintenance_status")}()")
    second_status = scalar(c.runtime_repo, "SELECT #{q(second)}.ash_onetime_maintenance_status()")
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
        RAISE EXCEPTION 'missing injected failure';
      EXCEPTION WHEN check_violation THEN NULL;
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

    assert scalar(
             c.runtime_repo,
             "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->>'acl'"
           ) == "false"

    scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_roll_payload_partitions")}(24)")

    assert scalar(
             c.runtime_repo,
             "SELECT #{rel(c, "ash_onetime_maintenance_status")}()->'checks'->>'acl'"
           ) == "false"
  end

  test "fresh partitions are relative to migration execution", c do
    assert scalar(
             Repo,
             "SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent='#{rel(c, "ash_onetime_response_payloads")}'::regclass AND pg_get_expr(c.relpartbound,c.oid) LIKE '%' || to_char(date_trunc('month',now()),'YYYY-MM-DD') || '%'"
           ) >= 1
  end

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

      sql!(c.owner_repo, "ALTER TABLE #{rel(c, "past#{-offset}")} ENABLE ROW LEVEL SECURITY")
      sql!(c.owner_repo, "ALTER TABLE #{rel(c, "past#{-offset}")} FORCE ROW LEVEL SECURITY")

      sql!(
        c.owner_repo,
        "SELECT #{rel(c, "ash_onetime_maintenance_copy_policy")}('#{rel(c, "past#{-offset}")}'::regclass)"
      )
    end

    sql!(
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

    sql!(
      Repo,
      "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET retain_until=now()-interval '1 second' WHERE logical_partition='tenant'"
    )

    assert scalar(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_idempotency")}(100)") == 1

    assert scalar(
             c.runtime_repo,
             "SELECT #{rel(c, "ash_onetime_prune_payload_partitions")}(8,2000)->>'dropped'"
           ) == "1"

    assert scalar(Repo, "SELECT to_regclass('#{rel(c, "past2")}') IS NULL")
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
      {:ok, ddl_repo} = subject(c.runtime)

      sql!(
        c.runtime_repo,
        "CREATE FUNCTION #{rel(c, "race_trigger")}() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN PERFORM pg_advisory_lock(19283,42); PERFORM set_config(''ash_onetime.probe_role'',current_user,false); RETURN NEW; END'"
      )

      for table <- [
            "ash_onetime_idempotency_claims",
            "ash_onetime_nonce_claims",
            "ash_onetime_response_payloads",
            "ash_onetime_response_payloads_default",
            "ash_onetime_maintenance_runs"
          ] do
        sql!(c.owner_repo, "GRANT TRIGGER ON #{rel(c, table)} TO #{q(c.runtime)}")
      end

      original =
        scalar(
          c.owner_repo,
          "SELECT prosrc FROM pg_proc WHERE oid='#{rel(c, "ash_onetime_cleanup_nonce")}(integer)'::regprocedure"
        )

      [lock_line] =
        Regex.run(~r/PERFORM [^;]+\.ash_onetime_maintenance_lock\(false,\s*5000\);/, original)

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
        "CREATE OR REPLACE FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(batch_size integer) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS #{literal(body)}"
      )

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

            sql!(ddl_repo, "SET ash_onetime.tenant='own'")

            sql!(
              ddl_repo,
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

    assert message =~ reason
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
    test "Table 1 row #{@row}: #{@kind} refuses before owner code runs", c do
      install_dependency(c, @kind)

      if @kind != :foreign_table do
        assert_refusal(c, "ash_onetime_cleanup_nonce", "100", "untrusted_dependency")
      end

      if @kind in [:trigger, :child_trigger, :constraint_trigger] do
        for {name, args} <- calls(),
            name != "ash_onetime_cleanup_nonce" and name != "ash_onetime_maintenance_status" do
          assert_refusal(c, name, args, "untrusted_dependency")
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

    # An immutable fixture may have been folded while the owner installed it.
    # Session advisory locks survive transaction rollback, so an invocation
    # during refused maintenance cannot be hidden by rollback.
    sql!(c.owner_repo, "SELECT pg_advisory_unlock_all()")
  end

  defp dependency_ddl(c, :trigger) do
    claims = rel(c, "ash_onetime_nonce_claims")

    trigger(c, claims, false)
  end

  defp dependency_ddl(c, :child_trigger) do
    trigger(c, rel(c, "ash_onetime_response_payloads_default"), false)
  end

  defp dependency_ddl(c, :constraint_trigger) do
    claims = rel(c, "ash_onetime_nonce_claims")

    trigger(c, claims, true)
  end

  defp dependency_ddl(c, :rule) do
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

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD COLUMN hostile boolean DEFAULT #{probe}()")
  end

  defp dependency_ddl(c, :generated) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD COLUMN hostile boolean GENERATED ALWAYS AS (#{probe}()) STORED"
    )
  end

  defp dependency_ddl(c, :check) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (#{probe}())")
  end

  defp dependency_ddl(c, :index) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(c.owner_repo, "CREATE INDEX hostile ON #{claims} ((#{probe}()))")
  end

  defp dependency_ddl(c, :routine) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "inner_probe")}() RETURNS boolean LANGUAGE sql AS 'SELECT true'"
    )

    sql!(
      c.owner_repo,
      "CREATE OR REPLACE FUNCTION #{probe}() RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS 'BEGIN RETURN #{rel(c, "inner_probe")}(); END'"
    )

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (#{probe}())")
  end

  defp dependency_ddl(c, :operator) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "comparison")}(integer,integer) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS 'BEGIN PERFORM pg_catalog.pg_advisory_lock(19283,42); RETURN true; END'"
    )

    sql!(
      c.runtime_repo,
      "CREATE OPERATOR #{q(c.schema)}.=== (LEFTARG=integer, RIGHTARG=integer, FUNCTION=#{rel(c, "comparison")})"
    )

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (1 OPERATOR(#{q(c.schema)}.===) 1)")
  end

  defp dependency_ddl(c, :operator_family) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "comparison")}(integer,integer) RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT CASE WHEN $1 < $2 THEN -1 WHEN $1 > $2 THEN 1 ELSE 0 END'"
    )

    sql!(
      Repo,
      "CREATE OPERATOR CLASS #{q(c.schema)}.hostile_ops FOR TYPE integer USING btree AS OPERATOR 1 < (integer,integer), OPERATOR 2 <= (integer,integer), OPERATOR 3 = (integer,integer), OPERATOR 4 >= (integer,integer), OPERATOR 5 > (integer,integer), FUNCTION 1 #{rel(c, "comparison")}(integer,integer)"
    )

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD COLUMN hostile integer")

    sql!(
      c.owner_repo,
      "CREATE INDEX hostile ON #{claims} (hostile #{q(c.schema)}.hostile_ops)"
    )
  end

  defp dependency_ddl(c, :foreign_key) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(
      c.owner_repo,
      "CREATE TABLE #{rel(c, "referencing")} (id uuid REFERENCES #{claims}(id) ON DELETE CASCADE)"
    )
  end

  defp dependency_ddl(c, :constraint_index) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(c.owner_repo, "CREATE DOMAIN #{rel(c, "hostile_type")} AS text CHECK (#{probe}())")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD COLUMN hostile #{rel(c, "hostile_type")} UNIQUE"
    )
  end

  defp dependency_ddl(c, :cast) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(c.runtime_repo, "CREATE TYPE #{rel(c, "hostile_type")} AS ENUM ('value')")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "cast_probe")}(#{rel(c, "hostile_type")}) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS 'BEGIN PERFORM pg_advisory_lock(19283,42); RETURN true; END'"
    )

    sql!(
      c.runtime_repo,
      "CREATE CAST (#{rel(c, "hostile_type")} AS boolean) WITH FUNCTION #{rel(c, "cast_probe")}(#{rel(c, "hostile_type")})"
    )

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD CHECK ('value'::#{rel(c, "hostile_type")}::boolean)"
    )
  end

  defp dependency_ddl(c, :base_type) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(Repo, "CREATE TYPE #{rel(c, "hostile_type")}")

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "type_input")}(cstring) RETURNS #{rel(c, "hostile_type")} LANGUAGE internal IMMUTABLE AS 'int4in'"
    )

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "type_output")}(#{rel(c, "hostile_type")}) RETURNS cstring LANGUAGE internal IMMUTABLE AS 'int4out'"
    )

    sql!(
      Repo,
      "CREATE TYPE #{rel(c, "hostile_type")} (INPUT=#{rel(c, "type_input")},OUTPUT=#{rel(c, "type_output")},INTERNALLENGTH=4,PASSEDBYVALUE,ALIGNMENT=int4)"
    )

    sql!(Repo, "ALTER TYPE #{rel(c, "hostile_type")} OWNER TO #{q(c.runtime)}")
    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD COLUMN hostile #{rel(c, "hostile_type")}")
  end

  defp dependency_ddl(c, :domain) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(
      c.owner_repo,
      "CREATE DOMAIN #{rel(c, "hostile_type")} AS integer CHECK (#{probe}())"
    )

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD COLUMN hostile #{rel(c, "hostile_type")}[]")
  end

  defp dependency_ddl(c, :range) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(
      c.runtime_repo,
      "CREATE FUNCTION #{rel(c, "range_diff")}(integer,integer) RETURNS float8 LANGUAGE sql IMMUTABLE AS 'SELECT ($1::float8-$2::float8)'"
    )

    sql!(
      c.runtime_repo,
      "CREATE TYPE #{rel(c, "hostile_type")} AS RANGE (SUBTYPE=integer,SUBTYPE_DIFF=#{rel(c, "range_diff")})"
    )

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD COLUMN hostile #{rel(c, "hostile_type")}")
  end

  defp dependency_ddl(c, :collation) do
    claims = rel(c, "ash_onetime_nonce_claims")

    sql!(c.runtime_repo, "CREATE COLLATION #{rel(c, "hostile_collation")} FROM \"C\"")

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD COLUMN hostile text COLLATE #{rel(c, "hostile_collation")}"
    )
  end

  defp dependency_ddl(c, :planner_support) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(
      Repo,
      "CREATE FUNCTION #{rel(c, "planner")}(internal) RETURNS internal LANGUAGE internal AS 'varchar_support'"
    )

    sql!(Repo, "ALTER FUNCTION #{rel(c, "planner")}(internal) OWNER TO #{q(c.runtime)}")
    sql!(Repo, "ALTER FUNCTION #{probe}() SUPPORT #{rel(c, "planner")}")
    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (#{probe}())")
  end

  defp dependency_ddl(c, :aggregate) do
    claims = rel(c, "ash_onetime_nonce_claims")

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

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (#{rel(c, "aggregate_check")}())")
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
      "CREATE OPERATOR CLASS #{rel(c, "am_ops")} DEFAULT FOR TYPE text USING #{q(am)} AS OPERATOR 1 < (text,text), OPERATOR 2 <= (text,text), OPERATOR 3 = (text,text), OPERATOR 4 >= (text,text), OPERATOR 5 > (text,text), FUNCTION 1 bttextcmp(text,text)"
    )

    sql!(c.owner_repo, "CREATE INDEX hostile ON #{claims} USING #{q(am)}(verifier_id)")
  end

  defp dependency_ddl(c, :foreign_table) do
    claims = rel(c, "ash_onetime_nonce_claims")
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
      "untrusted_dependency"
    )

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (#{probe}())")
  end

  defp dependency_ddl(c, :extension_member) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(Repo, "ALTER EXTENSION plpgsql ADD FUNCTION #{probe}()")

    on_exit(fn ->
      SQL.query!(Repo, "ALTER EXTENSION plpgsql DROP FUNCTION #{probe}()", [])
    end)

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (#{probe}())")
  end

  defp dependency_ddl(c, :statistics) do
    claims = rel(c, "ash_onetime_nonce_claims")
    probe = rel(c, "probe")

    sql!(
      c.owner_repo,
      "CREATE STATISTICS #{rel(c, "hostile_stats")} ON (#{probe}()),verifier_id FROM #{claims}"
    )
  end

  defp dependency_ddl(c, :partition_expression) do
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
      "ALTER TABLE #{claims} ADD COLUMN hostile bigint DEFAULT nextval('#{rel(c, "hostile_sequence")}')"
    )
  end

  defp dependency_ddl(c, :language) do
    claims = rel(c, "ash_onetime_nonce_claims")

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

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (#{rel(c, "language_probe")}())")
  end

  defp dependency_ddl(c, :text_search) do
    claims = rel(c, "ash_onetime_nonce_claims")

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

    sql!(
      c.owner_repo,
      "ALTER TABLE #{claims} ADD CHECK (to_tsvector('#{rel(c, "hostile_configuration")}'::regconfig,verifier_id) IS NOT NULL)"
    )
  end

  defp dependency_ddl(c, :conversion) do
    claims = rel(c, "ash_onetime_nonce_claims")
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

    sql!(c.owner_repo, "ALTER TABLE #{claims} ADD CHECK (#{probe}())")
  end

  @tag collision: true
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

    assert_refusal(c, "ash_onetime_roll_payload_partitions", "24", "untrusted_dependency")

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

    ddl =
      if constraint?,
        do:
          "CREATE CONSTRAINT TRIGGER hostile AFTER DELETE ON #{table} DEFERRABLE INITIALLY DEFERRED",
        else: "CREATE TRIGGER hostile BEFORE DELETE ON #{table}"

    sql!(c.owner_repo, ddl <> " FOR EACH ROW EXECUTE FUNCTION #{rel(c, "hostile_trigger")}()")
  end

  @tag maintenance_isolation_mutation: true
  test "SQL rejects NULL and out of range bounds and repeatable read", c do
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
      SELECT c.relname,coalesce(a.attname,''),x.grantee,x.privilege_type,bool_or(x.is_grantable)
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      LEFT JOIN pg_attribute a ON a.attrelid=c.oid AND a.attacl IS NOT NULL
      CROSS JOIN LATERAL aclexplode(CASE WHEN a.attname IS NULL THEN coalesce(c.relacl,acldefault('r',c.relowner)) ELSE a.attacl END) x
      WHERE n.nspname=$1 AND c.relname LIKE 'ash_onetime_%'
      GROUP BY c.relname,a.attname,x.grantee,x.privilege_type
      UNION ALL
      SELECT p.proname,'',x.grantee,x.privilege_type,bool_or(x.is_grantable)
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x
      WHERE n.nspname=$1
      GROUP BY p.proname,x.grantee,x.privilege_type
      ORDER BY 1,2,3,4
      """,
      [c.schema]
    ).rows
  end

  defp entry_points, do: Enum.map(calls(), &elem(&1, 0))

  defp calls,
    do: [
      {"ash_onetime_cleanup_idempotency", "100"},
      {"ash_onetime_cleanup_nonce", "100"},
      {"ash_onetime_reap_idempotency", "100,86400"},
      {"ash_onetime_prune_payload_partitions", "8,2000"},
      {"ash_onetime_roll_payload_partitions", "6"},
      {"ash_onetime_maintenance_status", ""}
    ]

  defp q(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
  defp rel(c, name), do: q(c.schema) <> "." <> q(name)
  defp sql!(repo, sql), do: SQL.query!(repo, sql, [])
  defp scalar(repo, sql), do: sql!(repo, sql).rows |> hd() |> hd()
end
