for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.OutcomeConstraintsTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    @tag :external_state_outcomes_check_attempt_mutation
    test "#{partitioning || "plain"}: the outcome CHECK refuses attempt zero", c do
      id = insert_claim(c)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               record_outcome(%{c | runtime_repo: c.owner_repo}, id, :held, 0)
    end

    @tag :external_state_outcomes_check_outcome_mutation
    test "#{partitioning || "plain"}: the outcome CHECK refuses an unknown value", c do
      id = insert_claim(c)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               record_outcome(%{c | runtime_repo: c.owner_repo}, id, :unresolved)
    end

    @tag :external_state_outcomes_primary_key_mutation
    test "#{partitioning || "plain"}: the outcome primary key refuses a second row for an attempt",
         c do
      id = insert_claim(c)
      owner = %{c | runtime_repo: c.owner_repo}
      assert {:ok, _} = record_outcome(owner, id)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23505"}}} =
               record_outcome(owner, id, :absent_proven)
    end
  end
end
