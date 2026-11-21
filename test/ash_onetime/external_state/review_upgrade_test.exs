for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.ReviewUpgradeTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.{SchemaFixture, ShippedMigrations}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true
    @moduletag :external_state_review_upgrade

    test "#{partitioning || "plain"}: rollback restores every prior routine definition and grant",
         c do
      legacy_install(c)

      SQL.query!(
        c.owner_repo,
        "ALTER FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(integer) SET extra_float_digits=1",
        []
      )

      SQL.query!(
        c.owner_repo,
        "GRANT EXECUTE ON FUNCTION #{rel(c, "ash_onetime_reap_idempotency")}(integer,bigint) TO #{q(c.runtime)} WITH GRANT OPTION",
        []
      )

      SQL.query!(
        c.owner_repo,
        "REVOKE ALL ON FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(integer) FROM PUBLIC",
        []
      )

      SQL.query!(
        c.owner_repo,
        "ALTER FUNCTION #{rel(c, "ash_onetime_cleanup_eligible")}(timestamptz) SECURITY DEFINER",
        []
      )

      before = routines(c)
      source = Generator.render_external_state_upgrade(Repo, [])
      assert :ok = migrate(c, 13, source)

      SQL.query!(
        c.owner_repo,
        "GRANT EXECUTE ON FUNCTION #{rel(c, "ash_onetime_cleanup_nonce")}(integer) TO #{q(c.runtime)}",
        []
      )

      assert :ok = migrate(c, 13, source, :down)
      assert routines(c) == before

      assert scalar(c.owner_repo, "SELECT to_regclass($1) IS NULL", [
               rel(c, "ash_onetime_external_state_restore")
             ])
    end

    test "#{partitioning || "plain"}: every restored cleanup and guard executes after rollback",
         c do
      legacy_install(c)
      source = Generator.render_external_state_upgrade(Repo, [])
      assert :ok = migrate(c, 13, source)
      assert :ok = migrate(c, 13, source, :down)

      SQL.query!(
        c.owner_repo,
        "INSERT INTO #{rel(c, "ash_onetime_nonce_claims")} (id,operation_hash,scope_hash,key_hash,issued_at,verifier_id,admitted_at,retain_until,inserted_at) VALUES (gen_random_uuid(),sha256('o'::bytea),sha256('s'::bytea),sha256('k'::bytea),transaction_timestamp()-interval '3 days','review',transaction_timestamp()-interval '3 days',transaction_timestamp()-interval '2 days',transaction_timestamp()-interval '3 days')",
        []
      )

      SQL.query!(
        c.owner_repo,
        "WITH claim AS (INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (id,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at) VALUES (gen_random_uuid(),sha256('o'::bytea),sha256('s'::bytea),sha256('complete'::bytea),sha256('request'::bytea),'complete',transaction_timestamp()::date,'review',sha256('response'::bytea),transaction_timestamp()-interval '3 days',transaction_timestamp()-interval '2 days',transaction_timestamp()-interval '3 days') RETURNING id) INSERT INTO #{rel(c, "ash_onetime_response_payloads")} (logical_partition,partition_date,claim_id,encoded_response) SELECT 'global',transaction_timestamp()::date,id,'response'::bytea FROM claim",
        []
      )

      results =
        for {name, args} <- [
              {"ash_onetime_reap_idempotency", "10,86400"},
              {"ash_onetime_cleanup_nonce", "10"},
              {"ash_onetime_cleanup_idempotency", "10"},
              {"ash_onetime_cleanup_eligible", "transaction_timestamp()-interval '1 day'"}
            ] do
          {name, SQL.query(c.owner_repo, "SELECT #{rel(c, name)}(#{args})", [])}
        end

      assert Enum.all?(results, fn {_name, result} -> match?({:ok, _}, result) end),
             inspect(results)

      assert scalar(c.owner_repo, "SELECT count(*) FROM #{rel(c, "ash_onetime_nonce_claims")}") ==
               0

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             ) == 0
    end

    @tag :external_state_review_journal
    test "#{partitioning || "plain"}: the rollback journal captures all six routines with owner-only grants",
         c do
      legacy_install(c)
      assert :ok = migrate(c, 13, Generator.render_external_state_upgrade(Repo, []))

      assert scalar(c.owner_repo, "SELECT to_regclass($1) IS NOT NULL", [
               rel(c, "ash_onetime_external_state_restore")
             ])

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_external_state_restore")}"
             ) == 6

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM pg_class c CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a WHERE c.oid=$1::text::regclass AND a.grantee<>c.relowner",
               [rel(c, "ash_onetime_external_state_restore")]
             ) == 0
    end

    @tag :external_state_review_journal
    test "#{partitioning || "plain"}: rollback refuses a missing journal without changing external state",
         c do
      legacy_install(c)
      source = Generator.render_external_state_upgrade(Repo, [])
      assert :ok = migrate(c, 13, source)

      SQL.query!(
        c.owner_repo,
        "DROP TABLE IF EXISTS #{rel(c, "ash_onetime_external_state_restore")}",
        []
      )

      assert {:error,
              %Postgrex.Error{
                postgres: %{pg_code: "23514", message: "external rollback journal is missing"}
              }} = migrate(c, 13, source, :down)

      assert scalar(c.owner_repo, "SELECT to_regclass($1) IS NOT NULL", [
               rel(c, "ash_onetime_effect_outcomes")
             ])
    end

    @tag :external_state_review_journal
    test "#{partitioning || "plain"}: rollback refuses an incomplete journal without changing external state",
         c do
      legacy_install(c)
      source = Generator.render_external_state_upgrade(Repo, [])
      assert :ok = migrate(c, 13, source)

      if scalar(c.owner_repo, "SELECT to_regclass($1) IS NOT NULL", [
           rel(c, "ash_onetime_external_state_restore")
         ]) do
        SQL.query!(
          c.owner_repo,
          "DELETE FROM #{rel(c, "ash_onetime_external_state_restore")} WHERE routine_identity LIKE '%ash_onetime_cleanup_nonce(%'",
          []
        )
      end

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  pg_code: "23514",
                  message: "external rollback journal does not cover all six routines"
                }
              }} = migrate(c, 13, source, :down)

      assert scalar(c.owner_repo, "SELECT to_regclass($1) IS NOT NULL", [
               rel(c, "ash_onetime_effect_outcomes")
             ])
    end

    @tag :external_state_review_journal
    test "#{partitioning || "plain"}: upgrade refuses to capture fewer than six prior routines",
         c do
      legacy_install(c)

      SQL.query!(
        c.owner_repo,
        "DROP FUNCTION #{rel(c, "ash_onetime_reap_idempotency")}(integer,bigint)",
        []
      )

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  pg_code: "23514",
                  message: "external rollback journal does not cover all six routines"
                }
              }} =
               migrate(c, 13, Generator.render_external_state_upgrade(Repo, []))

      assert scalar(c.owner_repo, "SELECT to_regclass($1) IS NULL", [
               rel(c, "ash_onetime_external_state_restore")
             ])
    end

    @tag :external_state_review_journal
    test "#{partitioning || "plain"}: rollback refuses journal attributes inconsistent with its saved definition",
         c do
      legacy_install(c)
      source = Generator.render_external_state_upgrade(Repo, [])
      assert :ok = migrate(c, 13, source)

      SQL.query!(
        c.owner_repo,
        "UPDATE #{rel(c, "ash_onetime_external_state_restore")} SET security_definer=NOT security_definer",
        []
      )

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  pg_code: "23514",
                  message: "external rollback journal routine attributes differ"
                }
              }} = migrate(c, 13, source, :down)

      assert scalar(c.owner_repo, "SELECT to_regclass($1) IS NOT NULL", [
               rel(c, "ash_onetime_effect_outcomes")
             ])
    end

    @tag :external_state_review_journal
    test "#{partitioning || "plain"}: the journal primary key refuses a duplicate routine snapshot",
         c do
      legacy_install(c)
      assert :ok = migrate(c, 13, Generator.render_external_state_upgrade(Repo, []))

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23505"}}} =
               SQL.query(
                 c.owner_repo,
                 "INSERT INTO #{rel(c, "ash_onetime_external_state_restore")} SELECT * FROM #{rel(c, "ash_onetime_external_state_restore")} LIMIT 1",
                 []
               )
    end

    test "#{partitioning || "plain"}: external upgrade restores the migrating role before its journal insert",
         c do
      legacy_install(c)
      migrator = journal_migrator(c)

      assert :ok =
               migrate(
                 %{c | owner_repo: migrator},
                 13,
                 Generator.render_external_state_upgrade(Repo, [])
               )

      assert scalar(migrator, "SELECT current_user") == c.migrator

      assert scalar(
               migrator,
               "SELECT count(*) FROM #{rel(c, "schema_migrations")} WHERE version=13"
             ) == 1
    end

    test "#{partitioning || "plain"}: external rollback restores the migrating role before its journal delete",
         c do
      legacy_install(c)
      source = Generator.render_external_state_upgrade(Repo, [])
      assert :ok = migrate(c, 13, source)
      migrator = journal_migrator(c)
      assert :ok = migrate(%{c | owner_repo: migrator}, 13, source, :down)
      assert scalar(migrator, "SELECT current_user") == c.migrator

      assert scalar(
               migrator,
               "SELECT count(*) FROM #{rel(c, "schema_migrations")} WHERE version=13"
             ) == 0
    end

    test "#{partitioning || "plain"}: rollback succeeds under FORCE and restores both row security flags",
         c do
      legacy_install(c)
      source = Generator.render_external_state_upgrade(Repo, [])
      assert :ok = migrate(c, 13, source)

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ENABLE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} FORCE ROW LEVEL SECURITY",
        []
      )

      assert :ok = migrate(c, 13, source, :down)

      assert [[true, true]] =
               SQL.query!(
                 c.owner_repo,
                 "SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid=$1::text::regclass",
                 [rel(c, "ash_onetime_idempotency_claims")]
               ).rows
    end

    for {name, args} <- [
          {"ash_onetime_expire_responses", "10"},
          {"ash_onetime_cleanup_idempotency", "10"},
          {"ash_onetime_cleanup_nonce", "10"},
          {"ash_onetime_reap_idempotency", "10,86400"},
          {"ash_onetime_cleanup_eligible", "transaction_timestamp()"}
        ] do
      @routine name
      @arguments args
      test "#{partitioning || "plain"}: without maintenance an unprivileged role cannot execute #{name}",
           c do
        legacy_install(c)
        assert :ok = migrate(c, 13, Generator.render_external_state_upgrade(Repo, []))

        tables =
          SQL.query!(
            c.owner_repo,
            "SELECT format('%I.%I',n.nspname,c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relkind IN ('r','p')",
            [c.schema]
          ).rows

        for [table] <- tables do
          SQL.query!(c.owner_repo, "REVOKE ALL ON #{table} FROM #{q(c.runtime)}", [])
        end

        refute scalar(
                 c.owner_repo,
                 "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relnamespace=$1::text::regnamespace AND relkind IN ('r','p') AND has_table_privilege($2,oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'))",
                 [c.schema, c.runtime]
               )

        assert {:error,
                %Postgrex.Error{
                  postgres: %{pg_code: "42501", message: "permission denied for function " <> _}
                }} = SQL.query(c.runtime_repo, "SELECT #{rel(c, @routine)}(#{@arguments})", [])
      end
    end

    defp legacy_install(c) do
      options = if c[:hash_partitions], do: [hash_partitions: c.hash_partitions], else: []

      :ok =
        SchemaFixture.migrate!(c, ShippedMigrations.render("v1.10.0", :render, Repo, options), 10)

      :ok = SchemaFixture.migrate!(c, Generator.render_operation_hold_upgrade(Repo, []), 12)
    end

    defp routines(c) do
      SQL.query!(
        c.owner_repo,
        "SELECT p.proname,pg_get_functiondef(p.oid),p.proowner::text,p.prosecdef,p.proconfig,(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.grantor,a.grantee,a.privilege_type,a.is_grantable) FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a) FROM pg_proc p WHERE p.pronamespace=$1::text::regnamespace AND p.proname=ANY($2::text[]) ORDER BY p.proname",
        [
          c.schema,
          ~w(ash_onetime_cleanup_eligible ash_onetime_guard_idempotency_delete ash_onetime_guard_nonce_delete ash_onetime_cleanup_idempotency ash_onetime_cleanup_nonce ash_onetime_reap_idempotency)
        ]
      ).rows
    end

    defp journal_migrator(c) do
      SQL.query!(Repo, "GRANT #{q(c.owner)} TO #{q(c.migrator)} WITH INHERIT FALSE, SET TRUE", [])
      SQL.query!(Repo, "GRANT USAGE,CREATE ON SCHEMA #{q(c.schema)} TO #{q(c.migrator)}", [])

      on_exit(fn ->
        SQL.query!(
          Repo,
          "GRANT #{q(c.owner)} TO #{q(c.migrator)} WITH INHERIT TRUE, SET TRUE",
          []
        )
      end)

      SQL.query!(Repo, "ALTER TABLE #{rel(c, "schema_migrations")} OWNER TO #{q(c.migrator)}", [])

      SQL.query!(
        Repo,
        "REVOKE ALL ON #{rel(c, "schema_migrations")} FROM #{q(c.owner)}, PUBLIC",
        []
      )

      refute scalar(Repo, "SELECT has_table_privilege($1,$2,'INSERT')", [
               c.owner,
               rel(c, "schema_migrations")
             ])

      connection!(c, :owner, 2,
        after_connect: fn connection -> Postgrex.query!(connection, "SET jit=off", []) end
      )
    end

    defp migrate(c, version, source, direction \\ :up) do
      SchemaFixture.migrate!(c, source, version, direction)
    rescue
      error in Postgrex.Error -> {:error, error}
    end
  end
end
