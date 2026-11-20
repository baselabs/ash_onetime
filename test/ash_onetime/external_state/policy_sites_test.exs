for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.PolicySitesTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true

    for {rule, source, site, name, attribute} <- [
          {"install-upgrade-policy-policy", "priv/templates/migrations/maintenance_helpers.exs",
           "install-upgrade-policy", "ash_onetime_upgrade_policy", "permissive"},
          {"install-upgrade-policy-check", "priv/templates/migrations/maintenance_helpers.exs",
           "install-upgrade-policy", "ash_onetime_upgrade_policy", "check"},
          {"install-maintenance-policy", "priv/templates/migrations/maintenance_helpers.exs",
           "install-maintenance", "ash_onetime_maintenance", "permissive"},
          {"install-maintenance-check", "priv/templates/migrations/maintenance_helpers.exs",
           "install-maintenance", "ash_onetime_maintenance", "check"},
          {"install-claim-visibility-policy", "priv/templates/migrations/maintenance_helpers.exs",
           "install-claim-visibility", "ash_onetime_claim_visibility", "permissive"},
          {"install-claim-visibility-check", "priv/templates/migrations/maintenance_helpers.exs",
           "install-claim-visibility", "ash_onetime_claim_visibility", "check"},
          {"external-maintenance-policy", "priv/templates/migrations/external_state.exs",
           "external-maintenance", "ash_onetime_maintenance", "permissive"},
          {"external-maintenance-check", "priv/templates/migrations/external_state.exs",
           "external-maintenance", "ash_onetime_maintenance", "check"},
          {"external-claim-visibility-policy", "priv/templates/migrations/external_state.exs",
           "external-claim-visibility", "ash_onetime_claim_visibility", "permissive"},
          {"external-claim-visibility-check", "priv/templates/migrations/external_state.exs",
           "external-claim-visibility", "ash_onetime_claim_visibility", "check"}
        ] do
      @rule rule
      @source source
      @site site
      @name name
      @attribute attribute
      @tag [
        {String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}
      ]
      test "#{partitioning || "plain"}: #{@rule} preserves its native policy attribute", c do
        actual =
          case install(c) do
            :ok ->
              source = File.read!(@source)

              [command] =
                Regex.run(~r/EXECUTE format\('\s*-- rule:#{@site}(?:-policy)?\n[\s\S]*?;/, source)

              SQL.query!(
                c.owner_repo,
                "CREATE TABLE #{rel(c, "policy_target")} (claim_id uuid, operation_hash bytea, logical_partition text)",
                []
              )

              on_exit(fn ->
                SQL.query!(c.owner_repo, "DROP TABLE #{rel(c, "policy_target")}", [])
              end)

              body = """
              DECLARE target record; owner_name name := #{literal(c.owner)}; install_schema name := #{literal(c.schema)};
                routine_schema name := #{literal(Postgres.routine_schema(c.schema))};
              BEGIN
                SELECT #{literal(rel(c, "policy_target"))}::regclass::oid AS oid,
                  #{literal(rel(c, "policy_target"))} AS relation_name INTO target;
                #{command}
              END
              """

              SQL.query!(c.owner_repo, "DO #{literal(body)}", [])

              [[permissive, check]] =
                SQL.query!(
                  c.owner_repo,
                  "SELECT polpermissive,pg_get_expr(polwithcheck,polrelid) FROM pg_policy WHERE polrelid=$1::text::regclass AND polname=$2",
                  [rel(c, "policy_target"), @name]
                ).rows

              if @attribute == "permissive",
                do: permissive,
                else:
                  is_binary(check) and
                    String.contains?(
                      check,
                      if(@name == "ash_onetime_claim_visibility",
                        do: "ash_onetime_claim_visible(",
                        else: "ash_onetime_maintenance_active()"
                      )
                    )

            {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} ->
              assert String.starts_with?(message, "maintenance_blinded: ")

              if @name == "ash_onetime_claim_visibility" do
                assert String.contains?(
                         message,
                         c.schema <> ".ash_onetime_effect_outcomes: invalid claim visibility"
                       )
              else
                assert String.contains?(message, "." <> @name)
              end

              false
          end

        assert actual == true
      end
    end

    @tag :enforcement_copy_policy_check_mutation
    test "#{partitioning || "plain"}: copying a policy preserves its explicit write check", c do
      assert :ok = install(c)

      SQL.query!(
        c.owner_repo,
        "CREATE POLICY consumer_write ON #{rel(c, "ash_onetime_response_payloads")} FOR INSERT TO #{q(c.runtime)} WITH CHECK (octet_length(encoded_response)>0)",
        []
      )

      SQL.query!(
        c.owner_repo,
        "CREATE TABLE #{rel(c, "policy_target")} (LIKE #{rel(c, "ash_onetime_response_payloads")})",
        []
      )

      on_exit(fn ->
        SQL.query!(c.owner_repo, "DROP TABLE #{rel(c, "policy_target")}", [])

        SQL.query!(
          c.owner_repo,
          "DROP POLICY consumer_write ON #{rel(c, "ash_onetime_response_payloads")}",
          []
        )
      end)

      SQL.query!(
        c.owner_repo,
        "SELECT #{routine(c, "ash_onetime_maintenance_copy_policy")}($1::text::regclass::oid)",
        [rel(c, "policy_target")]
      )

      assert [["(octet_length(encoded_response) > 0)"]] =
               SQL.query!(
                 c.owner_repo,
                 "SELECT pg_get_expr(polwithcheck,polrelid) FROM pg_policy WHERE polrelid=$1::text::regclass AND polname='consumer_write'",
                 [rel(c, "policy_target")]
               ).rows
    end
  end
end
