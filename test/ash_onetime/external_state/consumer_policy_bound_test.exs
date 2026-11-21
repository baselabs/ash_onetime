for partitions <- [nil, 2], force <- [false, true] do
  defmodule Module.concat(
              AshOnetime.ExternalState.ConsumerPolicyBoundTest,
              "Claims#{partitions || "Plain"}Force#{force}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Resource.Info
    alias AshOnetime.Test.ActionExamples.Resource
    alias AshOnetime.Test.{ExternalEffectSupport, ExternalPeer, StoreCase}
    @moduletag hash_partitions: partitions
    @moduletag force_claim_rls: force

    setup c do
      ExternalPeer.install!(c.schema)
      ExternalEffectSupport.reset_mode()

      SQL.query!(
        Repo,
        "GRANT INSERT ON #{rel(c, "external_local_effects")} TO #{q(c.runtime)}",
        []
      )

      SQL.query!(
        Repo,
        "GRANT USAGE ON ALL SEQUENCES IN SCHEMA #{q(c.schema)} TO #{q(c.runtime)}",
        []
      )

      on_exit(&ExternalEffectSupport.reset_mode/0)
      %{runtime_repo: connection!(c, :runtime, 4)}
    end

    test "#{partitions || "plain"}/#{force}: P12 a consumer KEY SHARE helper permits the outcome beside L3",
         c do
      grant = Postgres.claim_committed(target(c), request!("P12"), lock_timeout_ms: 300)
      helper = consumer_policy(c)
      helper.("KEY SHARE", :inherited)
      {holder, caller} = caller_lock(c, grant)
      worker_repo = connection!(c, :runtime, 1)
      backend = scalar(worker_repo, "SELECT pg_backend_pid()")

      try do
        started = System.monotonic_time(:millisecond)

        assert %Result{status: :processing, transaction: :committed} =
                 Postgres.record_outcome_committed(
                   %{target(c) | dynamic_repo: worker_repo},
                   grant.claim,
                   :held,
                   lock_timeout_ms: 1000
                 )

        assert System.monotonic_time(:millisecond) - started < 100

        assert scalar(
                 c.owner_repo,
                 "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted",
                 [backend]
               ) == 0

        assert SQL.query!(
                 c.owner_repo,
                 "SELECT polname::text FROM pg_policy WHERE polrelid=$1::text::regclass ORDER BY polname",
                 [rel(c, "ash_onetime_effect_outcomes")]
               ).rows == [["ash_onetime_claim_visibility"], ["ash_onetime_maintenance"]]

        send(caller, :release)
        Task.await(holder, 3000)

        SQL.query!(
          c.owner_repo,
          "CREATE POLICY hidden_runtime ON #{rel(c, "ash_onetime_idempotency_claims")} AS RESTRICTIVE TO #{q(c.runtime)} USING (false)",
          []
        )

        try do
          assert scalar(
                   worker_repo,
                   "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
                 ) == 0
        after
          SQL.query!(
            c.owner_repo,
            "DROP POLICY hidden_runtime ON #{rel(c, "ash_onetime_idempotency_claims")}",
            []
          )
        end
      after
        if Process.alive?(holder.pid) do
          send(caller, :release)
          Task.await(holder, 3000)
        end
      end
    end

    for operation <- [:classify, :replay], timeout_mode <- [:inherited, :set, :body] do
      @tag policy_operation: operation, timeout_mode: timeout_mode
      test "#{partitions || "plain"}/#{force}: B9 #{operation} honors the consumer #{timeout_mode} timeout boundary",
           c do
        grant = Postgres.claim_committed(target(c), request!("B9-caller"), lock_timeout_ms: 300)
        if c.policy_operation == :replay, do: complete_claim(c, grant.claim.id)
        helper = consumer_policy(c)
        helper.("KEY SHARE", :inherited)
        {holder, caller} = caller_lock(c, grant)
        helper.("UPDATE", c.timeout_mode)
        repo = connection!(c, :runtime, 1)
        SQL.query!(repo, "SET lock_timeout='7s'", [])
        backend = scalar(repo, "SELECT pg_backend_pid()")

        waiter =
          Task.async(fn ->
            runtime_transaction(%{c | runtime_repo: repo}, fn ->
              t = %{target(c) | dynamic_repo: repo}

              result =
                if c.policy_operation == :replay,
                  do: Postgres.load(t, grant.claim, lock_timeout_ms: 300),
                  else: Postgres.lock_for_effect(t, grant.claim, lock_timeout_ms: 300)

              if result.status == :failure do
                Repo.rollback(result)
              else
                {result, SQL.query!(repo, "SHOW lock_timeout", []).rows}
              end
            end)
          end)

        try do
          await_wait(c, backend)

          if c.timeout_mode == :inherited do
            assert {:error, %Result{reason: :lock_timeout}} = Task.await(waiter, 1300)
            send(caller, :release)
            Task.await(holder, 3000)
          else
            assert Task.yield(waiter, 650) == nil
            assert ExternalPeer.calls(c.schema) == []
            send(caller, :release)
            Task.await(holder, 3000)
            assert {:ok, {%Result{status: status}, [["7s"]]}} = Task.await(waiter, 3000)
            assert status == if(c.policy_operation == :replay, do: :complete, else: :processing)
          end

          assert scalar(
                   c.runtime_repo,
                   "SELECT effect_attempt FROM #{rel(c, "ash_onetime_idempotency_claims")}"
                 ) == 1
        after
          if Process.alive?(holder.pid), do: send(caller, :release)
          if Process.alive?(holder.pid), do: Task.await(holder, 3000)
        end
      end
    end

    for timeout_mode <- [:inherited, :set, :body] do
      @tag timeout_mode: timeout_mode
      test "#{partitions || "plain"}/#{force}: a consumer #{timeout_mode} helper bounds the outcome and retains unresolved state",
           c do
        input =
          Resource
          |> Ash.ActionInput.for_action(:external_redeem_quick_lock, %{
            value: 42,
            request_key: "outcome-policy",
            proof: "outcome-policy"
          })
          |> Ash.ActionInput.set_tenant(c.schema)

        protection = %{
          Info.protection(Resource, :external_redeem_quick_lock)
          | external_lock_timeout_ms: 300
        }

        previous = Repo.put_dynamic_repo(c.runtime_repo)

        state =
          try do
            {:ok, state} = AshOnetime.Admission.prepare(input, protection, %{})
            state
          after
            Repo.put_dynamic_repo(previous)
          end

        assert %Result{status: :admitted} =
                 Postgres.claim_committed(state.target, state.request, lock_timeout_ms: 300)

        helper = consumer_policy(c)
        helper.("KEY SHARE", :inherited)
        reference = make_ref()
        parent = self()
        handler = make_ref()

        :ok =
          :telemetry.attach(
            handler,
            [:ash_onetime, :external_recovery],
            fn _, _, metadata, _ -> send(parent, {:external_result, metadata.result_class}) end,
            nil
          )

        on_exit(fn -> :telemetry.detach(handler) end)

        {caller, monitor} =
          StoreCase.start_monitored_worker(fn ->
            ExternalEffectSupport.put_mode({:pause_recover_unknown, parent, reference})

            result =
              runtime_transaction(c, fn ->
                AshOnetime.ExternalRecovery.reserve(input, protection, %{}, nil)
              end)

            send(parent, {:policy_action_result, self(), result})
          end)

        assert_receive {:external_pause, ^reference, :recover_unknown, id, ^caller}, 3000
        helper.("UPDATE", c.timeout_mode)
        started = System.monotonic_time(:millisecond)
        send(caller, {:external_continue, reference})

        try do
          assert_receive {:policy_action_result, ^caller,
                          {:ok, {:error, %AshOnetime.Error{code: :outcome_unknown}}}},
                         6500

          elapsed = System.monotonic_time(:millisecond) - started

          if c.timeout_mode == :inherited,
            do: assert(elapsed < 1300),
            else: assert(elapsed >= 5000 and elapsed < 6500)

          assert_receive {:external_result, :outcome_unrecorded}, 1000
          assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1000

          assert scalar(
                   c.runtime_repo,
                   "SELECT effect_attempt FROM #{rel(c, "ash_onetime_idempotency_claims")}"
                 ) == 2

          assert scalar(
                   c.runtime_repo,
                   "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")}"
                 ) == 0

          drop_policy(c)
          age_claim(c, id)
          assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_reap_idempotency", "100,86400")
        after
          Process.exit(caller, :kill)
        end
      end
    end

    defp consumer_policy(c) do
      schema = c.schema <> "_consumer"
      SQL.query!(Repo, "CREATE SCHEMA #{q(schema)} AUTHORIZATION #{q(c.maintainer)}", [])
      on_exit(fn -> SQL.query!(Repo, "DROP SCHEMA IF EXISTS #{q(schema)} CASCADE", []) end)

      SQL.query!(
        c.owner_repo,
        "GRANT SELECT,UPDATE ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.maintainer)}",
        []
      )

      SQL.query!(Repo, "GRANT USAGE ON SCHEMA #{q(schema)} TO #{q(c.runtime)},#{q(c.owner)}", [])

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ENABLE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_effect_outcomes")} ENABLE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "DROP POLICY IF EXISTS runtime_visible ON #{rel(c, "ash_onetime_idempotency_claims")}",
        []
      )

      SQL.query!(
        c.owner_repo,
        "CREATE POLICY consumer_helper_view ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.maintainer)} USING (true) WITH CHECK (true)",
        []
      )

      replace = fn mode, timeout_mode ->
        setting = if timeout_mode == :set, do: "SET lock_timeout='30s'", else: ""

        body =
          if timeout_mode == :body, do: "PERFORM set_config('lock_timeout','0',true);", else: ""

        SQL.query!(
          Repo,
          "CREATE OR REPLACE FUNCTION #{q(schema)}.visible(claim uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog #{setting} AS $helper$ DECLARE context text; BEGIN GET DIAGNOSTICS context=PG_CONTEXT; IF position('ash_onetime_bound_effect_outcome' in context)=0 THEN #{body} PERFORM 1 FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=claim FOR #{mode}; END IF; RETURN true; END $helper$",
          []
        )

        SQL.query!(
          Repo,
          "ALTER FUNCTION #{q(schema)}.visible(uuid) OWNER TO #{q(c.maintainer)}",
          []
        )
      end

      replace.("KEY SHARE", :inherited)

      SQL.query!(
        c.owner_repo,
        "CREATE POLICY consumer_runtime ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.runtime)} USING (#{q(schema)}.visible(id)) WITH CHECK (#{q(schema)}.visible(id))",
        []
      )

      on_exit(fn -> drop_policy(c) end)
      replace
    end

    defp drop_policy(c) do
      for policy <- ["consumer_runtime", "consumer_helper_view"] do
        SQL.query!(
          c.owner_repo,
          "DROP POLICY IF EXISTS #{q(policy)} ON #{rel(c, "ash_onetime_idempotency_claims")}",
          []
        )
      end

      SQL.query!(
        c.owner_repo,
        "REVOKE SELECT,UPDATE ON #{rel(c, "ash_onetime_idempotency_claims")} FROM #{q(c.maintainer)}",
        []
      )

      if c[:force_claim_rls] do
        SQL.query!(
          c.owner_repo,
          "DROP POLICY IF EXISTS runtime_visible ON #{rel(c, "ash_onetime_idempotency_claims")}",
          []
        )

        SQL.query!(
          c.owner_repo,
          "CREATE POLICY runtime_visible ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.runtime)} USING (true) WITH CHECK (true)",
          []
        )
      else
        SQL.query!(
          c.owner_repo,
          "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DISABLE ROW LEVEL SECURITY",
          []
        )

        SQL.query!(
          c.owner_repo,
          "ALTER TABLE #{rel(c, "ash_onetime_effect_outcomes")} DISABLE ROW LEVEL SECURITY",
          []
        )
      end
    end

    defp caller_lock(c, grant) do
      parent = self()
      repo = connection!(c, :runtime, 1)

      task =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: repo}, fn ->
            assert %Result{status: status} =
                     result =
                     Postgres.lock_for_effect(%{target(c) | dynamic_repo: repo}, grant.claim,
                       lock_timeout_ms: 300
                     )

            assert status in [:processing, :complete], inspect(result)
            send(parent, {:consumer_held, self()})

            receive do
              :release -> :ok
            after
              15_000 -> flunk("consumer holder was not released")
            end
          end)
        end)

      assert_receive {:consumer_held, caller}, 3000
      {task, caller}
    end

    defp await_wait(c, backend, remaining \\ 100) do
      if scalar(c.owner_repo, "SELECT count(*) FROM pg_locks WHERE pid=$1 AND NOT granted", [
           backend
         ]) > 0 do
        :ok
      else
        assert remaining > 0
        Process.sleep(5)
        await_wait(c, backend, remaining - 1)
      end
    end
  end
end
