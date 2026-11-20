AshOnetime.Test.ShippedRuntime.load!()

for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.HistoricalRuntimeTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.ShippedRuntime
    alias AshOnetimeV1_9_2.Store.Claim, as: HistoricalClaim
    alias AshOnetimeV1_9_2.Store.Postgres, as: HistoricalPostgres
    @moduletag hash_partitions: partitioning

    setup_all do
      {:ok, historical_binaries: ShippedRuntime.load!()}
    end

    test "#{partitioning || "plain"}: historical xref closure calls no current package module",
         c do
      assert map_size(c.historical_binaries) == 14
      assert Map.has_key?(c.historical_binaries, HistoricalPostgres)

      for {module, binary} <- c.historical_binaries do
        assert String.starts_with?(Atom.to_string(module), "Elixir.AshOnetimeV1_9_2.")
        assert {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(binary, [:imports])

        refute Enum.any?(imports, fn {callee, _, _} ->
                 String.starts_with?(Atom.to_string(callee), "Elixir.AshOnetime.")
               end)
      end

      manifest =
        File.read!("test/support/fixtures/shipped/runtime_v1_9_2/sources.json") |> Jason.decode!()

      xref = File.read!("test/support/fixtures/shipped/runtime_v1_9_2/xref_graph.dot")

      paths =
        Regex.scan(~r/"(lib\/[^"\n]+\.ex)"/, xref, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()

      assert paths == Enum.sort(Enum.map(manifest["sources"], & &1["path"]))
    end

    for reserve <- [:claim, :claim_committed] do
      test "#{partitioning || "plain"}: v1.9.2 #{reserve} and recovery remain safe after upgrade",
           c do
        request = old_request!("legacy-#{unquote(reserve)}")
        target = old_target(c)

        result =
          if unquote(reserve) == :claim do
            {:ok, result} =
              runtime_transaction(c, fn ->
                HistoricalPostgres.claim(target, request)
              end)

            result
          else
            HistoricalPostgres.claim_committed(target, request, lock_timeout_ms: 300)
          end

        assert %{status: :admitted, claim: %{id: id}} = result

        assert [[false, 0]] =
                 SQL.query!(
                   c.runtime_repo,
                   "SELECT effect_local,effect_attempt FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1",
                   [Ecto.UUID.dump!(id)]
                 ).rows

        assert {:ok, %{status: :processing}} =
                 runtime_transaction(c, fn ->
                   HistoricalPostgres.load(target, result.claim)
                 end)

        grant =
          Postgres.claim_committed(target(c), request!("legacy-#{unquote(reserve)}"),
            lock_timeout_ms: 300
          )

        assert %{
                 status: :processing,
                 previous_effect_state: :unknown,
                 claim: %{id: ^id, effect_attempt: 1}
               } = grant

        assert {:ok, %{status: :processing}} =
                 runtime_transaction(c, fn ->
                   HistoricalPostgres.lock_for_effect(target, result.claim, lock_timeout_ms: 300)
                 end)

        assert {:ok, %{status: :complete}} =
                 runtime_transaction(c, fn ->
                   HistoricalPostgres.complete_external(
                     target,
                     result.claim,
                     "test",
                     :crypto.hash(:sha256, "response"),
                     "response"
                   )
                 end)

        assert {:ok, %Result{status: :complete, payload: "response"}} =
                 runtime_transaction(c, fn ->
                   Postgres.load(target(c), grant.claim, lock_timeout_ms: 300)
                 end)

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "42883"}}} =
                 SQL.query(
                   c.runtime_repo,
                   "SELECT #{rel(c, "ash_onetime_reap_idempotency")}(100,86400)",
                   []
                 )
      end
    end

    test "#{partitioning || "plain"}: B6 a historical caller bounds a new outcome worker", c do
      request = old_request!("B6")

      old =
        HistoricalPostgres.claim_committed(old_target(c), request, lock_timeout_ms: 300)

      grant = Postgres.claim_committed(target(c), request!("B6"), lock_timeout_ms: 300)
      holder_repo = connection!(c, :runtime, 1)
      parent = self()

      holder =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: holder_repo}, fn ->
            assert %{status: :processing} =
                     HistoricalPostgres.lock_for_effect(
                       old_target(%{c | runtime_repo: holder_repo}),
                       old.claim,
                       lock_timeout_ms: 300
                     )

            send(parent, {:historical_locked, self()})

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive {:historical_locked, _}, 3000

      try do
        started = System.monotonic_time(:millisecond)

        assert %Result{reason: :outcome_unrecorded} =
                 Postgres.record_outcome_committed(target(c), grant.claim, :held,
                   lock_timeout_ms: 300
                 )

        assert System.monotonic_time(:millisecond) - started < 1000

        assert scalar(
                 c.runtime_repo,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
               ) == 0
      after
        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 3000)
      end
    end

    defp old_target(c) do
      previous = Repo.put_dynamic_repo(c.runtime_repo)

      try do
        HistoricalPostgres.for_repo(Repo, c.schema)
      after
        Repo.put_dynamic_repo(previous)
      end
    end

    defp old_request!(key) do
      {:ok, request} =
        HistoricalClaim.idempotency(
          operation_hash: :crypto.hash(:sha256, "operation"),
          scope_hash: :crypto.hash(:sha256, "scope"),
          key_hash: :crypto.hash(:sha256, key),
          fingerprint: :crypto.hash(:sha256, "request"),
          retention_seconds: 86_400
        )

      request
    end
  end
end
