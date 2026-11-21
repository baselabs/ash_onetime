for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.CatalogGuardsTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for {rule, message} <- [
          {"trust-partition-bound-refusal", "untrusted_dependency: partition bound"},
          {"trust-missing-root-refusal", "untrusted_dependency: missing package root"},
          {"capture-date-encoding-refusal", "untrusted_dependency: unsupported date encoding"},
          {"lock-root-budget-refusal", "maintenance lock budget exhausted"},
          {"lock-parent-owner-refusal", "untrusted_dependency: payload parent owner changed"}
        ] do
      @rule rule
      @message message
      @tag [
        {String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}
      ]
      test "#{partitioning || "plain"}: #{@rule} reports its native catalog boundary", c do
        query =
          case @rule do
            "trust-partition-bound-refusal" ->
              child = rel(c, "minimum_partition")

              SQL.query!(
                c.owner_repo,
                "CREATE TABLE #{child} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM (MINVALUE) TO ('2000-01-01')",
                []
              )

              on_exit(fn -> SQL.query!(c.owner_repo, "DROP TABLE #{child}", []) end)

              SQL.query!(
                c.owner_repo,
                "SELECT #{routine(c, "ash_onetime_maintenance_copy_policy")}($1::text::regclass::oid)",
                [child]
              )

              SQL.query!(
                c.owner_repo,
                "SELECT #{routine(c, "ash_onetime_maintenance_reset_acl")}($1::text::regclass::oid,false)",
                [child]
              )

              "SELECT #{routine(c, "ash_onetime_maintenance_trust")}()"

            "trust-missing-root-refusal" ->
              SQL.query!(
                c.owner_repo,
                "ALTER TABLE #{rel(c, "ash_onetime_nonce_claims")} RENAME TO consumer_nonce",
                []
              )

              on_exit(fn ->
                SQL.query!(
                  c.owner_repo,
                  "ALTER TABLE #{rel(c, "consumer_nonce")} RENAME TO ash_onetime_nonce_claims",
                  []
                )
              end)

              "SELECT #{routine(c, "ash_onetime_maintenance_trust")}()"

            "capture-date-encoding-refusal" ->
              [[child, name]] =
                SQL.query!(
                  c.owner_repo,
                  "SELECT c.oid::regclass::text,c.relname FROM pg_class c JOIN pg_inherits i ON i.inhrelid=c.oid WHERE i.inhparent=$1::text::regclass AND c.relpartbound::text LIKE '%:is_default false%' ORDER BY c.oid LIMIT 1",
                  [rel(c, "ash_onetime_response_payloads")]
                ).rows

              SQL.query!(
                c.owner_repo,
                "ALTER TABLE #{child} RENAME TO ash_onetime_response_payloads_2000_03",
                []
              )

              on_exit(fn ->
                SQL.query!(
                  c.owner_repo,
                  "ALTER TABLE #{rel(c, "ash_onetime_response_payloads_2000_03")} RENAME TO #{q(name)}",
                  []
                )
              end)

              "SELECT #{routine(c, "ash_onetime_maintenance_capture")}()"

            "lock-root-budget-refusal" ->
              "SELECT #{routine(c, "ash_onetime_maintenance_lock")}(false,0)"

            "lock-parent-owner-refusal" ->
              table = rel(c, "ash_onetime_response_payloads")
              SQL.query!(Repo, "ALTER TABLE #{table} OWNER TO #{q(c.runtime)}", [])
              SQL.query!(Repo, "GRANT ALL ON #{table} TO #{q(c.owner)}", [])

              on_exit(fn ->
                SQL.query!(Repo, "ALTER TABLE #{table} OWNER TO #{q(c.owner)}", [])
              end)

              "SELECT #{routine(c, "ash_onetime_maintenance_lock")}(false,5000)"
          end

        if @rule == "trust-partition-bound-refusal" do
          assert {:error,
                  %Postgrex.Error{
                    postgres: %{message: "untrusted_dependency: partition bound" <> _}
                  }} =
                   step(c, "ash_onetime_prune_payload_partitions", "1,5000")
        end

        result = SQL.query(c.owner_repo, query, [])

        actual =
          case result do
            {:error, %Postgrex.Error{postgres: %{message: message}}} ->
              String.starts_with?(message, @message)

            _ ->
              false
          end

        assert actual, inspect(result)
      end
    end

    @tag :enforcement_trust_partition_bound_refusal_mutation
    test "#{partitioning || "plain"}: native payload ranges reject equal and reversed endpoints",
         c do
      for {lower, upper} <- [{"2000-01-01", "2000-01-01"}, {"2000-02-01", "2000-01-01"}] do
        result =
          SQL.query(
            c.owner_repo,
            "CREATE TABLE #{rel(c, "invalid_range")} PARTITION OF #{rel(c, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{lower}') TO ('#{upper}')",
            []
          )

        assert {:error,
                %Postgrex.Error{
                  postgres: %{pg_code: "42P17", message: "empty range bound specified" <> _}
                }} = result

        assert [[nil]] =
                 SQL.query!(c.owner_repo, "SELECT to_regclass($1::text)", [
                   rel(c, "invalid_range")
                 ]).rows
      end
    end
  end
end
