for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.OutcomeAuditTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_outcome_audit_mutation

    for privilege <- ["UPDATE", "DELETE", "TRIGGER", "TRUNCATE", "REFERENCES", "MAINTAIN"],
        child <- if(partitioning, do: [false, true], else: [false]) do
      test "#{partitioning || "plain"}: trust refuses outcome #{privilege} on #{if child, do: "partition", else: "root"}",
           c do
        relation =
          rel(
            c,
            unquote(
              if child, do: "ash_onetime_effect_outcomes_p0", else: "ash_onetime_effect_outcomes"
            )
          )

        SQL.query!(
          c.owner_repo,
          "GRANT #{unquote(privilege)} ON #{relation} TO #{q(c.runtime)}",
          []
        )

        try do
          assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} =
                   trust(c)

          assert message =~ "untrusted_dependency: effective"
        after
          SQL.query!(
            c.owner_repo,
            "REVOKE #{unquote(privilege)} ON #{relation} FROM #{q(c.runtime)}",
            []
          )
        end
      end
    end

    test "#{partitioning || "plain"}: trust refuses outcome column UPDATE", c do
      relation = rel(c, "ash_onetime_effect_outcomes")
      SQL.query!(c.owner_repo, "GRANT UPDATE(outcome) ON #{relation} TO #{q(c.runtime)}", [])

      try do
        assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} =
                 trust(c)

        assert message =~ "untrusted_dependency: effective"
      after
        SQL.query!(c.owner_repo, "REVOKE UPDATE(outcome) ON #{relation} FROM #{q(c.runtime)}", [])
      end
    end

    test "#{partitioning || "plain"}: trust accepts runtime SELECT and INSERT", c do
      assert scalar(
               c.runtime_repo,
               "SELECT has_table_privilege(current_user,$1,'SELECT') AND has_table_privilege(current_user,$1,'INSERT')",
               [rel(c, "ash_onetime_effect_outcomes")]
             )

      assert {:ok, _} = trust(c)
    end

    test "#{partitioning || "plain"}: trust refuses a named visibility-helper grant", c do
      function = routine(c, "ash_onetime_claim_visible") <> "(bytea,text,uuid)"
      SQL.query!(c.owner_repo, "GRANT EXECUTE ON FUNCTION #{function} TO #{q(c.runtime)}", [])

      try do
        assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001"}}} = trust(c)
      after
        SQL.query!(
          c.owner_repo,
          "REVOKE EXECUTE ON FUNCTION #{function} FROM #{q(c.runtime)}",
          []
        )
      end
    end

    test "#{partitioning || "plain"}: trust refuses an altered visibility expression", c do
      relation = rel(c, "ash_onetime_effect_outcomes")

      [[using, check]] =
        SQL.query!(
          c.owner_repo,
          "SELECT pg_get_expr(polqual,polrelid),pg_get_expr(polwithcheck,polrelid) FROM pg_policy WHERE polrelid=$1::text::regclass AND polname='ash_onetime_claim_visibility'",
          [relation]
        ).rows

      SQL.query!(
        c.owner_repo,
        "ALTER POLICY ash_onetime_claim_visibility ON #{relation} USING (true) WITH CHECK (true)",
        []
      )

      try do
        assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001"}}} = trust(c)
      after
        SQL.query!(
          c.owner_repo,
          "ALTER POLICY ash_onetime_claim_visibility ON #{relation} USING (#{using}) WITH CHECK (#{check})",
          []
        )
      end
    end

    test "#{partitioning || "plain"}: revoking a table privilege also removes its column grants",
         c do
      relation = rel(c, "ash_onetime_effect_outcomes")

      for privilege <- ["UPDATE", "REFERENCES"] do
        SQL.query!(
          c.owner_repo,
          "GRANT #{privilege}(outcome) ON #{relation} TO #{q(c.runtime)}",
          []
        )

        assert scalar(
                 c.runtime_repo,
                 "SELECT has_column_privilege(current_user,$1,'outcome',$2)",
                 [relation, privilege]
               )

        SQL.query!(
          c.owner_repo,
          "REVOKE #{privilege} ON TABLE #{relation} FROM #{q(c.runtime)} CASCADE",
          []
        )

        refute scalar(
                 c.runtime_repo,
                 "SELECT has_column_privilege(current_user,$1,'outcome',$2)",
                 [relation, privilege]
               )
      end
    end

    defp trust(c),
      do: SQL.query(c.owner_repo, "SELECT #{routine(c, "ash_onetime_maintenance_trust")}()", [])
  end
end
