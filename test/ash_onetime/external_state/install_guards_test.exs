for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.InstallGuardsTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.{SchemaFixture, ShippedMigrations}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    for {rule, message} <- [
          {"install-owner-set-role", "maintenance_owner_set_role:"},
          {"install-owner-schema-create", "maintenance_owner_schema_create:"},
          {"install-function-ownership", "maintenance_function_ownership:"},
          {"install-maintenance-role-exists", "maintenance_role_missing:"},
          {"install-reserved-policy-refusal",
           "maintenance_blinded: reserved policy ash_onetime_maintenance already exists on"}
        ] do
      @rule rule
      @message message
      @tag [
        {String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}
      ]
      test "#{partitioning || "plain"}: #{@rule} identifies its native install refusal", c do
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
                 SchemaFixture.migrate!(c, Generator.render_operation_hold_upgrade(Repo, []), 12)

        assert :ok =
                 SchemaFixture.migrate!(c, Generator.render_external_state_upgrade(Repo, []), 13)

        {migration_context, maintenance_role} =
          case @rule do
            "install-owner-set-role" ->
              SQL.query!(Repo, "GRANT #{q(c.owner)} TO #{q(c.migrator)} WITH SET FALSE", [])

              on_exit(fn ->
                SQL.query!(Repo, "GRANT #{q(c.owner)} TO #{q(c.migrator)} WITH SET TRUE", [])
              end)

              migrator =
                connection!(c, :owner, 2,
                  after_connect: fn connection ->
                    Postgrex.query!(connection, "SET jit=off", [])
                  end
                )

              {%{c | owner_repo: migrator}, c.maintainer}

            "install-owner-schema-create" ->
              SQL.query!(Repo, "ALTER SCHEMA #{q(c.schema)} OWNER TO #{q(c.runtime)}", [])

              SQL.query!(
                Repo,
                "REVOKE CREATE ON SCHEMA #{q(c.schema)} FROM #{q(c.owner)}, PUBLIC",
                []
              )

              SQL.query!(Repo, "GRANT USAGE ON SCHEMA #{q(c.schema)} TO #{q(c.owner)},#{q(c.migrator)}", [])
              SQL.query!(Repo, "GRANT CREATE ON SCHEMA #{q(c.schema)} TO #{q(c.migrator)}", [])

              on_exit(fn ->
                SQL.query!(Repo, "ALTER SCHEMA #{q(c.schema)} OWNER TO #{q(c.owner)}", [])
              end)

              migrator = connection!(c, :owner, 2, after_connect: fn connection ->
                Postgrex.query!(connection, "SET jit=off", [])
              end)

              {%{c | owner_repo: migrator}, c.maintainer}

            "install-function-ownership" ->
              identity = rel(c, "ash_onetime_cleanup_eligible") <> "(timestamptz)"
              SQL.query!(Repo, "ALTER FUNCTION #{identity} OWNER TO #{q(c.runtime)}", [])

              on_exit(fn ->
                SQL.query!(Repo, "ALTER FUNCTION #{identity} OWNER TO #{q(c.owner)}", [])
              end)

              {c, c.maintainer}

            "install-maintenance-role-exists" ->
              {c, "ao_missing_" <> String.replace(Ecto.UUID.generate(), "-", "")}

            "install-reserved-policy-refusal" ->
              table = rel(c, "ash_onetime_nonce_claims")
              SQL.query!(c.owner_repo, "DROP POLICY ash_onetime_maintenance ON #{table}", [])

              SQL.query!(
                c.owner_repo,
                "CREATE POLICY ash_onetime_maintenance ON #{table} FOR ALL TO #{q(c.owner)} USING (true) WITH CHECK (true)",
                []
              )

              {c, c.maintainer}
          end

        result =
          try do
            SchemaFixture.migrate!(
              migration_context,
              Generator.render_maintenance_upgrade(Repo, maintenance_role: maintenance_role),
              14
            )
          rescue
            error in Postgrex.Error -> {:error, error.postgres.pg_code, error.postgres.message}
          end

        actual =
          case result do
            {:error, "P0001", message} -> String.starts_with?(message, @message)
            _ -> false
          end

        assert actual, inspect(result)
      end
    end
  end
end
