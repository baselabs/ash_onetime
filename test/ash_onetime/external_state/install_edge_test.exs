for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.InstallEdgeTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true
    @moduletag outcome_column_update: true
    @moduletag :external_state_install_edge_mutation

    test "#{partitioning || "plain"}: install normalizes append-only privileges and permits the outcome worker",
         c do
      assert :ok = install(c)
      id = insert_claim(c)
      assert {:ok, %{num_rows: 1}} = record_outcome(c, id)

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
             ) == 1

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               SQL.query(
                 c.runtime_repo,
                 "UPDATE #{rel(c, "ash_onetime_effect_outcomes")} SET outcome='absent_proven'",
                 []
               )
    end

    @tag :external_state_outcome_acl_runtime_mutation
    test "#{partitioning || "plain"}: install normalizes the outcome privilege for its holder",
         c do
      install_with_audit!(c, ["ash_onetime_effect_outcomes", "MAINTAIN", c.runtime])
    end

    @tag :external_state_visibility_helper_public_mutation
    test "#{partitioning || "plain"}: install grants PUBLIC EXECUTE on the visibility helper",
         c do
      install_with_audit!(c, ["ash_onetime_claim_visible", "PUBLIC", "EXECUTE"])
    end

    defp install_with_audit!(c, expected) do
      case install(c) do
        :ok ->
          :ok

        {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} ->
          for part <- expected, do: assert(String.contains?(message, part))
          flunk("install audit refused the required normalization: #{message}")

        result ->
          flunk("unexpected installation result: #{inspect(result)}")
      end
    end
  end
end
