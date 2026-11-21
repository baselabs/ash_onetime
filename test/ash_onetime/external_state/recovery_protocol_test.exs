for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.RecoveryProtocolTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.ActionExamples.Resource
    alias AshOnetime.Test.{ExternalEffectSupport, ExternalPeer, StoreCase}
    @moduletag hash_partitions: partitioning

    setup c do
      ExternalPeer.install!(c.schema)

      SQL.query!(
        Repo,
        "GRANT INSERT, SELECT ON #{rel(c, "external_local_effects")} TO #{q(c.runtime)}",
        []
      )

      SQL.query!(
        Repo,
        "GRANT USAGE ON ALL SEQUENCES IN SCHEMA #{q(c.schema)} TO #{q(c.runtime)}",
        []
      )

      ExternalEffectSupport.reset_mode()
      on_exit(&ExternalEffectSupport.reset_mode/0)
      handler = make_ref()
      observer = self()

      :ok =
        :telemetry.attach(
          handler,
          [:ash_onetime, :external_recovery],
          fn _, _, metadata, _ -> send(observer, {:external_event, metadata.result_class}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{runtime_repo: connection!(c, :runtime, 4)}
    end

    test "#{partitioning || "plain"}: a cold observer sees the committed grant before the first peer call",
         c do
      {caller, monitor, reference} = start_action(c, "grant", :pause_before_execute)
      assert_receive {:external_pause, ^reference, :before_execute, id, ^caller}, 5000
      assert claim(c, id) |> Enum.take(3) == ["processing", false, 1]
      assert ExternalPeer.calls(c.schema) == []
      send(caller, {:external_continue, reference})
      assert_receive {:action_result, ^caller, {:ok, 42}}, 5000
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5000
      assert ExternalPeer.calls(c.schema) == [["execute", id]]
    end

    for previous <- [:unresolved, :held, :absent_proven, :unknown] do
      @tag protocol_previous: previous
      test "#{partitioning || "plain"}: #{previous} re-dispatch commits its next attempt under the original identity",
           c do
        previous = c.protocol_previous
        id = abandon(c, "redispatch", :pause_before_execute)
        before = claim(c, id)

        if previous in [:held, :absent_proven],
          do: assert({:ok, _} = action_outcome(c, id, previous))

        if previous == :unknown do
          StoreCase.restore_fixture!(
            Repo,
            "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET effect_attempt=0 WHERE id=$1",
            [Ecto.UUID.dump!(id)]
          )
        end

        {caller, monitor, reference} = start_action(c, "redispatch", :pause_before_execute)
        assert_receive {:external_pause, ^reference, :before_execute, ^id, ^caller}, 5000
        row = claim(c, id)

        assert Enum.take(row, 3) == [
                 "processing",
                 false,
                 if(previous == :unknown, do: 1, else: 2)
               ]

        assert Enum.drop(row, 3) == Enum.drop(before, 3)
        assert ExternalPeer.calls(c.schema) == [["recover", id]]
        send(caller, {:external_continue, reference})
        assert_receive {:action_result, ^caller, {:ok, 42}}, 5000
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5000
        assert ExternalPeer.calls(c.schema) == [["recover", id], ["execute", id]]
      end
    end

    for mode <- [:recover_unknown, :raise_recover, :throw_recover, :invalid_recover] do
      test "#{partitioning || "plain"}: #{mode} records held for exactly the granted attempt",
           c do
        id = abandon(c, "held", :pause_before_execute)
        before = claim(c, id)
        ExternalEffectSupport.put_mode(unquote(mode))
        assert_error(run_action(c, "held"), :outcome_unknown)
        assert claim(c, id) |> Enum.take(3) == ["processing", false, 2]
        assert claim(c, id) |> Enum.drop(3) == Enum.drop(before, 3)

        assert SQL.query!(
                 c.runtime_repo,
                 "SELECT attempt,outcome FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1",
                 [Ecto.UUID.dump!(id)]
               ).rows == [[2, "held"]]

        assert ExternalPeer.calls(c.schema) == [["recover", id]]
        assert ExternalPeer.count(c.schema, "external_local_effects") == 0
      end
    end

    for mode <- [:raise_execute, :throw_execute, :invalid_execute] do
      test "#{partitioning || "plain"}: #{mode} followed by proven absence records absent_proven",
           c do
        ExternalEffectSupport.put_mode(unquote(mode))
        assert_error(run_action(c, "absent"), :external_effect_unavailable)
        assert [["recover", id]] = ExternalPeer.calls(c.schema)

        assert SQL.query!(
                 c.runtime_repo,
                 "SELECT attempt,outcome FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1",
                 [Ecto.UUID.dump!(id)]
               ).rows == [[1, "absent_proven"]]

        assert claim(c, id) |> Enum.take(3) == ["processing", false, 1]
      end
    end

    for transaction_mode <- [:naive, :strict],
        failure <- [:recover_failed_query, :recover_nested_rollback] do
      test "#{partitioning || "plain"}: #{transaction_mode} #{failure} cannot abort the independent outcome commit",
           c do
        id = abandon(c, "failed-caller", :pause_before_execute)
        repo = connection!(c, :runtime, 3, transactions: unquote(transaction_mode))
        ExternalEffectSupport.put_mode(unquote(failure))
        started = System.monotonic_time(:millisecond)
        assert_error(run_action(%{c | runtime_repo: repo}, "failed-caller"), :outcome_unknown)
        assert System.monotonic_time(:millisecond) - started < 2000

        assert SQL.query!(
                 c.runtime_repo,
                 "SELECT attempt,outcome FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1",
                 [Ecto.UUID.dump!(id)]
               ).rows == [[2, "held"]]

        assert claim(c, id) |> Enum.take(3) == ["processing", false, 2]
        assert ExternalPeer.count(c.schema, "external_local_effects") == 0
      end
    end

    test "#{partitioning || "plain"}: crash after peer success survives reap and recovers with no second execute",
         c do
      id = abandon(c, "crash", :pause_after_execute)
      before = claim(c, id)
      age_claim(c, id)
      assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_reap_idempotency", "100,86400")
      assert {:ok, 42} = run_action(c, "crash")
      assert ExternalPeer.calls(c.schema) == [["execute", id], ["recover", id]]
      assert Enum.take(claim(c, id), 3) == ["complete", false, 2]
      assert Enum.drop(claim(c, id), 3) == Enum.drop(before, 3)
    end

    for kind <- [:grant, :outcome] do
      @tag protocol_kind: kind
      test "#{partitioning || "plain"}: a lost #{kind} acknowledgment preserves its committed attempt",
           c do
        kind = c.protocol_kind
        id = if kind == :outcome, do: abandon(c, "lost-ack", :pause_before_execute)
        reference = query_barrier(c, :after_commit, kind)

        {caller, monitor} =
          start_action_mode(
            c,
            "lost-ack",
            if(kind == :outcome, do: :recover_unknown, else: :normal)
          )

        assert_receive {:query_barrier, ^reference, worker}, 5000
        on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

        id =
          id ||
            scalar(
              c.runtime_repo,
              "SELECT id::text FROM #{rel(c, "ash_onetime_idempotency_claims")}"
            )

        assert Enum.take(claim(c, id), 3) == [
                 "processing",
                 false,
                 if(kind == :outcome, do: 2, else: 1)
               ]

        if kind == :outcome,
          do:
            assert(
              scalar(
                c.runtime_repo,
                "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
              ) == 1
            )

        :telemetry.detach(reference)
        Process.exit(worker, :kill)
        assert_receive {:action_result, ^caller, result}, 5000
        assert match?({:error, _}, result)
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5000
        if kind == :outcome, do: assert_receive({:external_event, :outcome_unrecorded}, 1000)
        assert {:ok, 42} = run_action(c, "lost-ack")

        assert Enum.take(claim(c, id), 3) == [
                 "complete",
                 false,
                 if(kind == :outcome, do: 3, else: 2)
               ]

        assert Enum.count(ExternalPeer.calls(c.schema), fn [operation, _] ->
                 operation == "execute"
               end) == 1
      end
    end

    for ordering <- [:cleanup_first, :worker_first] do
      test "#{partitioning || "plain"}: a late outcome worker survives its caller and #{ordering} leaves no orphan",
           c do
        id = abandon(c, "late-worker", :pause_before_execute)
        reference = query_barrier(c, :before_insert, :outcome)
        {caller, monitor} = start_action_mode(c, "late-worker", :recover_unknown)
        assert_receive {:query_barrier, ^reference, worker}, 5000
        worker_monitor = Process.monitor(worker)
        on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 5000
        assert {:ok, 42} = run_action(c, "late-worker")
        age_claim(c, id)

        if unquote(ordering) == :worker_first do
          send(worker, {:release_query, reference})
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 5000

          assert scalar(
                   c.runtime_repo,
                   "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
                 ) == 1
        end

        assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")

        if unquote(ordering) == :cleanup_first do
          send(worker, {:release_query, reference})
          assert_receive {:query_error, ^reference, "23503"}, 5000
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 5000
          assert_receive {:external_event, :outcome_unrecorded}, 1000
        end

        assert scalar(
                 c.runtime_repo,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
               ) == 0

        assert scalar(
                 c.runtime_repo,
                 "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
               ) == 0
      end
    end

    test "#{partitioning || "plain"}: race A's late outcome cannot classify B's crashed peer attempt",
         c do
      id = abandon(c, "race-a", :pause_before_execute)
      reference = query_barrier(c, :before_insert, :outcome)
      {a, a_monitor} = start_action_mode(c, "race-a", :recover_unknown)
      assert_receive {:query_barrier, ^reference, worker}, 5000
      worker_monitor = Process.monitor(worker)
      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      Process.exit(a, :kill)
      assert_receive {:DOWN, ^a_monitor, :process, ^a, :killed}, 5000
      assert id == abandon(c, "race-a", :pause_after_execute)
      assert Enum.take(claim(c, id), 3) == ["processing", false, 3]
      send(worker, {:release_query, reference})
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 5000

      assert SQL.query!(
               c.runtime_repo,
               "SELECT attempt,outcome FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1",
               [Ecto.UUID.dump!(id)]
             ).rows == [[2, "held"]]

      age_claim(c, id)
      assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_reap_idempotency", "100,86400")
      assert {:ok, 42} = run_action(c, "race-a")
      assert Enum.take(claim(c, id), 3) == ["complete", false, 4]

      assert Enum.count(ExternalPeer.calls(c.schema), fn [operation, _] ->
               operation == "execute"
             end) == 1
    end

    test "#{partitioning || "plain"}: race B's proven absence fences A before any peer call", c do
      reference = query_barrier(c, :after_commit, :grant)
      {a, a_monitor} = start_action_mode(c, "race-b", :normal)
      assert_receive {:query_barrier, ^reference, worker}, 5000
      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

      id =
        scalar(c.runtime_repo, "SELECT id::text FROM #{rel(c, "ash_onetime_idempotency_claims")}")

      other = %{c | runtime_repo: connection!(c, :runtime, 3)}
      ExternalEffectSupport.put_mode(:raise_execute)
      assert_error(run_action(other, "race-b"), :external_effect_unavailable)
      ExternalEffectSupport.reset_mode()

      assert SQL.query!(
               c.runtime_repo,
               "SELECT attempt,outcome FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1",
               [Ecto.UUID.dump!(id)]
             ).rows == [[2, "absent_proven"]]

      send(worker, {:release_query, reference})
      assert_receive {:action_result, ^a, result}, 5000
      assert_error(result, :request_in_progress)
      assert_receive {:DOWN, ^a_monitor, :process, ^a, :normal}, 5000
      assert ExternalPeer.calls(c.schema) == [["recover", id], ["recover", id]]
      assert Enum.take(claim(c, id), 3) == ["processing", false, 2]
    end

    test "#{partitioning || "plain"}: concurrent same-key callers execute once and the next caller replays",
         c do
      {a, a_monitor, reference} = start_action(c, "same-key", :pause_before_execute)
      assert_receive {:external_pause, ^reference, :before_execute, id, ^a}, 5000
      other = %{c | runtime_repo: connection!(c, :runtime, 3)}
      assert_error(run_action(other, "same-key"), :request_in_progress)
      assert ExternalPeer.calls(c.schema) == []
      send(a, {:external_continue, reference})
      assert_receive {:action_result, ^a, {:ok, 42}}, 5000
      assert_receive {:DOWN, ^a_monitor, :process, ^a, :normal}, 5000
      assert {:ok, 42} = run_action(other, "same-key")
      assert ExternalPeer.calls(c.schema) == [["execute", id]]
    end

    defp query_barrier(c, stage, kind) do
      reference = make_ref()
      parent = self()

      relation =
        if kind == :grant,
          do: "ash_onetime_idempotency_claims",
          else: "ash_onetime_effect_outcomes"

      event = Repo.config()[:telemetry_prefix] ++ [:query]
      first = :atomics.new(1, [])

      :ok =
        :telemetry.attach(
          reference,
          event,
          fn _, _, metadata, _ ->
            handle_query(metadata, rel(c, relation), stage, first, reference, parent)
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(reference) end)
      reference
    end

    defp handle_query(metadata, relation, stage, first, reference, parent) do
      query = metadata.query |> to_string() |> String.downcase()

      if String.contains?(query, "insert into #{String.downcase(relation)}"),
        do: Process.put(reference, true)

      if barrier_reached?(stage, query, metadata.params, relation, reference) and
           :atomics.compare_exchange(first, 1, 0, 1) == :ok do
        Process.put(reference, :released)
        send(parent, {:query_barrier, reference, self()})

        receive do
          {:release_query, ^reference} -> :ok
        after
          15_000 -> raise "query barrier was not released"
        end
      end

      if stage == :before_insert and Process.get(reference) == true,
        do: report_query_error(metadata.result, parent, reference)
    end

    defp barrier_reached?(:before_insert, query, params, relation, _reference),
      do: String.starts_with?(query, "select relkind='p'") and relation in params

    defp barrier_reached?(:after_commit, query, _params, _relation, reference),
      do: query == "commit" and Process.get(reference) == true

    defp report_query_error(
           {:error, %Postgrex.Error{postgres: %{pg_code: code}}},
           parent,
           reference
         ),
         do: send(parent, {:query_error, reference, code})

    defp report_query_error(_result, _parent, _reference), do: :ok

    defp run_action(c, key) do
      previous = Repo.put_dynamic_repo(c.runtime_repo)

      try do
        Resource
        |> Ash.ActionInput.for_action(:external_redeem_quick_lock, %{
          value: 42,
          request_key: key,
          proof: "proof-#{key}"
        })
        |> Ash.ActionInput.set_tenant(c.schema)
        |> Ash.run_action()
      after
        Repo.put_dynamic_repo(previous)
      end
    end

    defp start_action(c, key, phase) do
      reference = make_ref()
      {caller, monitor} = start_action_mode(c, key, {phase, self(), reference})
      {caller, monitor, reference}
    end

    defp start_action_mode(c, key, mode) do
      parent = self()

      StoreCase.start_monitored_worker(fn ->
        ExternalEffectSupport.put_mode(mode)
        send(parent, {:action_result, self(), run_action(c, key)})
      end)
    end

    defp abandon(c, key, phase) do
      {caller, monitor, reference} = start_action(c, key, phase)

      observed_phase =
        %{pause_before_execute: :before_execute, pause_after_execute: :after_execute}[phase]

      assert_receive {:external_pause, ^reference, ^observed_phase, id, ^caller}, 5000
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 5000
      id
    end

    defp action_outcome(c, id, outcome) do
      keys = if c[:hash_partitions], do: "operation_hash,logical_partition,", else: ""

      SQL.query(
        c.runtime_repo,
        "INSERT INTO #{rel(c, "ash_onetime_effect_outcomes")} (#{keys}claim_id,attempt,outcome,recorded_at) SELECT #{keys}id,effect_attempt,$2,transaction_timestamp() FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1",
        [Ecto.UUID.dump!(id), Atom.to_string(outcome)]
      )
    end

    defp claim(c, id) do
      SQL.query!(
        c.runtime_repo,
        "SELECT state,effect_local,effect_attempt,id::text,logical_partition,operation_hash,scope_hash,key_hash,fingerprint FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1",
        [Ecto.UUID.dump!(id)]
      ).rows
      |> hd()
    end

    defp assert_error({:error, error}, expected) do
      assert Enum.any?(
               Map.get(error, :errors, [error]),
               &match?(%AshOnetime.Error{code: ^expected}, &1)
             )
    end
  end
end
