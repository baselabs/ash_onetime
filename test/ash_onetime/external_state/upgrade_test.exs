for partitioning <- [nil, 2, 4] do
  defmodule Module.concat(
              AshOnetime.ExternalState.UpgradeTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.ShippedMigrations
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true
    @moduletag :external_state_upgrade_mutation

    test "#{partitioning || "plain"}: historical logical-partition keys are authenticated and rekeyed before the outcome FK",
         c do
      install_historical(c, unquote(partitioning))
      assert {:ok, source} = render_external()
      assert :ok = migrate(c, 13, source)

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE NOT effect_local AND effect_attempt=0 AND response_retain_until=retain_until"
             ) == 1

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM pg_constraint WHERE conrelid=$1::text::regclass AND contype='f'",
               [rel(c, "ash_onetime_effect_outcomes")]
             ) >= 1

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM pg_trigger WHERE tgrelid=$1::text::regclass AND NOT tgisinternal AND tgenabled<>'A'",
               [rel(c, "ash_onetime_idempotency_claims")]
             ) == 0

      assert :ok =
               migrate(
                 c,
                 14,
                 Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer)
               )

      assert {:ok, %{rows: [[%{"checks" => %{"trust" => true}}]]}} =
               step(c, "ash_onetime_maintenance_status", "")

      [[id]] =
        SQL.query!(
          c.runtime_repo,
          "SELECT id FROM #{rel(c, "ash_onetime_idempotency_claims")}",
          []
        ).rows

      complete_claim(c, Ecto.UUID.load!(id))

      assert :ok =
               migrate(
                 c,
                 14,
                 Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer),
                 :down
               )

      assert :ok = migrate(c, 13, source, :down)
    end

    test "#{partitioning || "plain"}: an extra historical CHECK is refused before adding external state",
         c do
      install_historical(c, unquote(partitioning))

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ADD CONSTRAINT consumer_extra CHECK (retain_until > admitted_at - interval '1 second')",
        []
      )

      assert {:ok, source} = render_external()

      assert {:error,
              %Postgrex.Error{
                postgres: %{message: "untrusted_dependency: upgrade relation shape" <> _}
              }} = migrate(c, 13, source)

      assert scalar(c.owner_repo, "SELECT to_regclass($1) IS NULL", [
               rel(c, "ash_onetime_effect_outcomes")
             ])
    end

    test "#{partitioning || "plain"}: maintenance forced past the generator refuses missing external state",
         c do
      install_historical(c, unquote(partitioning))
      source = Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer)

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  message:
                    "untrusted_dependency: upgrade relation shape ash_onetime_idempotency_claims"
                }
              }} = migrate(c, 14, source)

      assert scalar(
               c.owner_repo,
               "SELECT NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=$1::text::regclass AND attname='effect_local' AND NOT attisdropped)",
               [rel(c, "ash_onetime_idempotency_claims")]
             )
    end

    for rollback <- [:external_state, :maintenance] do
      @tag forced_rollback: rollback
      test "#{partitioning || "plain"}: #{rollback} rollback refuses a narrowed FORCE RLS view",
           c do
        install_historical(c, unquote(partitioning))
        assert {:ok, external} = render_external()
        assert :ok = migrate(c, 13, external)
        maintenance = Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer)
        if c.forced_rollback == :maintenance, do: assert(:ok == migrate(c, 14, maintenance))

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

        SQL.query!(
          c.owner_repo,
          "DROP POLICY ash_onetime_maintenance ON #{rel(c, "ash_onetime_idempotency_claims")}",
          []
        )

        {version, source} =
          if c.forced_rollback == :maintenance, do: {14, maintenance}, else: {13, external}

        expected_code = if c.forced_rollback == :maintenance, do: "42501", else: "23514"
        assert {:error, %Postgrex.Error{postgres: %{pg_code: ^expected_code}}} =
                 migrate(c, version, source, :down)
      end
    end

    test "#{partitioning || "plain"}: external-state rollback refuses unresolved claims before removing protection",
         c do
      install_historical(c, unquote(partitioning))
      assert {:ok, source} = render_external()
      assert :ok = migrate(c, 13, source)

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  pg_code: "23514",
                  message: "unresolved external claims prevent rollback"
                }
              }} = migrate(c, 13, source, :down)
    end

    test "#{partitioning || "plain"}: maintenance rollback refuses unresolved claims before restoring routines",
         c do
      install_historical(c, unquote(partitioning))
      assert {:ok, source} = render_external()
      assert :ok = migrate(c, 13, source)
      maintenance = Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer)
      assert :ok = migrate(c, 14, maintenance)

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  pg_code: "23514",
                  message: "unresolved external claims prevent rollback"
                }
              }} = migrate(c, 14, maintenance, :down)
    end

    test "#{partitioning || "plain"}: external-state rollback refuses expired responses before the old CHECK",
         c do
      install_historical(c, unquote(partitioning))
      assert {:ok, source} = render_external()
      assert :ok = migrate(c, 13, source)

      [[binary_id]] =
        SQL.query!(
          c.runtime_repo,
          "SELECT id FROM #{rel(c, "ash_onetime_idempotency_claims")}",
          []
        ).rows

      id = Ecto.UUID.load!(binary_id)
      complete_claim(c, id)
      age_claim(c, id, retain: "transaction_timestamp()+interval '1 day'")

      assert %{rows: [[1]]} =
               SQL.query!(
                 c.runtime_repo,
                 "SELECT #{rel(c, "ash_onetime_expire_responses")}(10)",
                 []
               )

      assert {:error,
              %Postgrex.Error{
                postgres: %{pg_code: "23514", message: "expired responses prevent rollback"}
              }} = migrate(c, 13, source, :down)
    end

    defp render_external do
      if function_exported?(Generator, :render_external_state_upgrade, 2),
        do: {:ok, Generator.render_external_state_upgrade(Repo, [])},
        else: {:error, :external_state_upgrade_missing}
    end

    defp install_historical(c, partitions) do
      options = if partitions, do: [hash_partitions: partitions], else: []
      assert :ok = migrate(c, 10, ShippedMigrations.render("v0.6.0", :render, Repo, options))

      assert :ok =
               migrate(
                 c,
                 11,
                 ShippedMigrations.render("v1.1.0", :render_logical_partition_upgrade, Repo, [])
               )

      assert :ok = migrate(c, 12, Generator.render_operation_hold_upgrade(Repo, []))

      SQL.query!(
        c.runtime_repo,
        """
        INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")}
          (id,operation_hash,scope_hash,key_hash,fingerprint,admitted_at,retain_until,inserted_at)
        VALUES (gen_random_uuid(),sha256('operation'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('request'::bytea),transaction_timestamp(),transaction_timestamp()+interval '1 day',transaction_timestamp())
        """,
        []
      )
    end

    def migrate(c, version, source, direction \\ :up) do
      module = Module.concat(__MODULE__, "Migration#{System.unique_integer([:positive])}")

      source =
        Regex.replace(~r/defmodule [A-Za-z0-9_.]+ do/, source, "defmodule #{inspect(module)} do",
          global: false
        )

      Code.compile_string(source)
      previous = Repo.put_dynamic_repo(c.owner_repo)

      try do
        apply(Ecto.Migrator, direction, [Repo, version, module, [prefix: c.schema, log: false]])
      rescue
        error in Postgrex.Error -> {:error, error}
      after
        Repo.put_dynamic_repo(previous)
        :code.purge(module)
        :code.delete(module)
      end
    end
  end
end
