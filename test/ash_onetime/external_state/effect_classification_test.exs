for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.EffectClassificationTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for state <- [:local, :resolved, :finalized, :unknown, :held, :absent_proven, :unresolved] do
      @state state
      @tag [{String.to_atom("enforcement_effect_classify_#{state}_mutation"), true}]
      test "#{partitioning || "plain"}: the loaded claim classifies #{@state}", c do
        attempt = if @state in [:local, :resolved, :unknown], do: 0, else: 1
        local = @state == :local
        id = insert_claim(c, key: "classification", local: local, attempt: attempt)
        if @state in [:resolved, :finalized], do: complete_claim(c, id)
        if @state in [:held, :absent_proven], do: assert({:ok, _} = record_outcome(c, id, @state))

        {:ok, %Result{claim: claim}} =
          runtime_transaction(c, fn -> Postgres.claim(target(c), request!("classification")) end)

        assert {:ok, %Result{claim: %{effect_state: @state}}} =
                 runtime_transaction(c, fn ->
                   Postgres.load(target(c), claim, lock_timeout_ms: 300)
                 end)
      end
    end
  end
end
