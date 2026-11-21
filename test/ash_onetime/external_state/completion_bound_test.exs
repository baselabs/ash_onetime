for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.CompletionBoundTest,
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
      %{runtime_repo: connection!(c, :runtime, 4)}
    end

    test "#{partitioning || "plain"}: the joined caller read excludes ACCESS EXCLUSIVE on its actual payload leaf",
         c do
      probe = insert_claim(c) |> then(&complete_claim(c, &1))

      leaf =
        scalar(
          c.runtime_repo,
          "SELECT tableoid::regclass::text FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1",
          [Ecto.UUID.dump!(probe)]
        )

      {caller, monitor, reference, id} = paused_action(c, "leaf-proof")
      holder = connection!(c, :owner, 1)

      try do
        assert scalar(
                 Repo,
                 "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE l.relation=$1::text::regclass AND l.mode='AccessShareLock' AND l.granted AND a.state='idle in transaction'",
                 [leaf]
               ) > 0

        assert {:error, :blocked} =
                 runtime_transaction(%{c | runtime_repo: holder}, fn ->
                   assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                            SQL.query(
                              holder,
                              "LOCK TABLE #{leaf} IN ACCESS EXCLUSIVE MODE NOWAIT",
                              []
                            )

                   Repo.rollback(:blocked)
                 end)

        assert ExternalPeer.calls(c.schema) == [["execute", id]]
      after
        send(caller, {:external_continue, reference})
        assert_receive {:completion_result, ^caller, {:ok, 42}}, 4000
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1000
      end
    end

    for blocked <- [:payload, :policy] do
      @tag blocked_completion: blocked
      test "#{partitioning || "plain"}: completion bounds #{blocked} and the retry recovers without another execute",
           c do
        blocked = c.blocked_completion

        {lock_relation, lock_sql} =
          if blocked == :payload do
            probe = insert_claim(c) |> then(&complete_claim(c, &1))

            leaf =
              scalar(
                c.runtime_repo,
                "SELECT tableoid::regclass::text FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1",
                [Ecto.UUID.dump!(probe)]
              )

            {leaf, "LOCK TABLE #{leaf} IN SHARE MODE"}
          else
            consumer = c.schema <> "_completion"
            SQL.query!(Repo, "CREATE SCHEMA #{q(consumer)} AUTHORIZATION #{q(c.maintainer)}", [])
            on_exit(fn -> SQL.query!(Repo, "DROP SCHEMA #{q(consumer)} CASCADE", []) end)
            SQL.query!(Repo, "CREATE TABLE #{q(consumer)}.gate(id integer PRIMARY KEY)", [])
            SQL.query!(Repo, "ALTER TABLE #{q(consumer)}.gate OWNER TO #{q(c.maintainer)}", [])
            SQL.query!(Repo, "INSERT INTO #{q(consumer)}.gate VALUES (1)", [])

            SQL.query!(
              Repo,
              "GRANT USAGE ON SCHEMA #{q(consumer)} TO #{q(c.runtime)},#{q(c.owner)}",
              []
            )

            SQL.query!(
              Repo,
              "CREATE FUNCTION #{q(consumer)}.visible() RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $helper$ BEGIN IF current_query() ~* '^UPDATE ' THEN PERFORM 1 FROM #{q(consumer)}.gate FOR UPDATE; END IF; RETURN true; END $helper$",
              []
            )

            SQL.query!(
              Repo,
              "ALTER FUNCTION #{q(consumer)}.visible() OWNER TO #{q(c.maintainer)}",
              []
            )

            SQL.query!(
              c.owner_repo,
              "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ENABLE ROW LEVEL SECURITY",
              []
            )

            SQL.query!(
              c.owner_repo,
              "CREATE POLICY completion_runtime ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.runtime)} USING (#{q(consumer)}.visible()) WITH CHECK (#{q(consumer)}.visible())",
              []
            )

            on_exit(fn ->
              SQL.query!(
                c.owner_repo,
                "DROP POLICY completion_runtime ON #{rel(c, "ash_onetime_idempotency_claims")}",
                []
              )

              SQL.query!(
                c.owner_repo,
                "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DISABLE ROW LEVEL SECURITY",
                []
              )
            end)

            {q(consumer) <> ".gate", "SELECT id FROM #{q(consumer)}.gate FOR UPDATE"}
          end

        {caller, monitor, reference, id} = paused_action(c, "completion-#{blocked}")
        holder_repo = connection!(c, :owner, 1)
        # The owner must be able to hold the consumer's unrelated gate too.
        if blocked == :policy,
          do: SQL.query!(Repo, "GRANT SELECT,UPDATE ON #{lock_relation} TO #{q(c.owner)}", [])

        parent = self()

        holder =
          Task.async(fn ->
            runtime_transaction(%{c | runtime_repo: holder_repo}, fn ->
              SQL.query!(holder_repo, lock_sql, [])
              send(parent, {:completion_held, self()})

              receive do
                :release -> :ok
              after
                10_000 -> flunk("completion holder was not released")
              end
            end)
          end)

        assert_receive {:completion_held, holder_pid}, 3000

        try do
          send(caller, {:external_continue, reference})

          assert_receive {:completion_result, ^caller,
                          {:error,
                           %Ash.Error.Invalid{
                             errors: [%AshOnetime.Error{code: :request_in_progress}]
                           }}},
                         2000

          assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1000

          assert SQL.query!(
                   c.runtime_repo,
                   "SELECT state,effect_local,effect_attempt FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1",
                   [Ecto.UUID.dump!(id)]
                 ).rows == [["processing", false, 1]]

          assert scalar(
                   c.runtime_repo,
                   "SELECT count(*) FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1",
                   [Ecto.UUID.dump!(id)]
                 ) == 0

          assert scalar(
                   c.runtime_repo,
                   "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1",
                   [Ecto.UUID.dump!(id)]
                 ) == 0
        after
          send(holder_pid, :release)
          Task.await(holder, 3000)
        end

        age_claim(c, id)
        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_reap_idempotency", "100,86400")
        ExternalEffectSupport.reset_mode()
        assert {:ok, 42} = run_action(c, "completion-#{blocked}")
        assert ExternalPeer.calls(c.schema) == [["execute", id], ["recover", id]]
      end
    end

    defp paused_action(c, key) do
      parent = self()
      reference = make_ref()

      {caller, monitor} =
        StoreCase.start_monitored_worker(fn ->
          ExternalEffectSupport.put_mode({:pause_after_execute, parent, reference})
          send(parent, {:completion_result, self(), run_action(c, key)})
        end)

      assert_receive {:external_pause, ^reference, :after_execute, id, ^caller}, 5000
      {caller, monitor, reference, id}
    end

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
  end
end
