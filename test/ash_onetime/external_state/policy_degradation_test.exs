for partitioning <- [nil, 2], force <- [false, true] do
  defmodule Module.concat(
              AshOnetime.ExternalState.PolicyDegradationTest,
              "Claims#{partitioning || "Plain"}Force#{force}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag force_claim_rls: force
    @moduletag :external_state_policy_degradation_mutation

    test "#{partitioning || "plain"}/#{force}: a visibility helper inherits the outcome worker's bound",
         c do
      grant = Postgres.claim_committed(target(c), request!("policy-bound"), lock_timeout_ms: 300)
      consumer_schema = c.schema <> "_policy"
      SQL.query!(Repo, "CREATE SCHEMA #{q(consumer_schema)} AUTHORIZATION #{q(c.maintainer)}", [])
      on_exit(fn -> SQL.query!(Repo, "DROP SCHEMA #{q(consumer_schema)} CASCADE", []) end)

      SQL.query!(
        Repo,
        "GRANT USAGE ON SCHEMA #{q(consumer_schema)} TO #{q(c.runtime)},#{q(c.owner)}",
        []
      )

      SQL.query!(
        c.owner_repo,
        "GRANT SELECT,UPDATE ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.maintainer)}",
        []
      )

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
        "CREATE POLICY consumer_helper_visible ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.maintainer)} USING (true) WITH CHECK (true)",
        []
      )

      helper = fn mode ->
        SQL.query!(
          Repo,
          "CREATE OR REPLACE FUNCTION #{q(consumer_schema)}.visible(claim uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $helper$ DECLARE context text; BEGIN GET DIAGNOSTICS context=PG_CONTEXT; IF position('ash_onetime_bound_effect_outcome' in context)=0 THEN PERFORM 1 FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=claim FOR #{mode}; END IF; RETURN true; END $helper$",
          []
        )

        SQL.query!(
          Repo,
          "ALTER FUNCTION #{q(consumer_schema)}.visible(uuid) OWNER TO #{q(c.maintainer)}",
          []
        )
      end

      helper.("KEY SHARE")

      SQL.query!(
        c.owner_repo,
        "CREATE POLICY runtime_locks ON #{rel(c, "ash_onetime_idempotency_claims")} TO #{q(c.runtime)} USING (#{q(consumer_schema)}.visible(id)) WITH CHECK (#{q(consumer_schema)}.visible(id))",
        []
      )

      caller_repo = connection!(c, :runtime, 1)
      caller_target = %{target(c) | dynamic_repo: caller_repo}
      parent = self()

      caller =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(caller_repo)

          try do
            Repo.transaction(fn ->
              assert %Result{status: :processing} =
                       Postgres.lock_for_effect(caller_target, grant.claim, lock_timeout_ms: 300)

              send(parent, {:caller_locked, self()})

              receive do
                :release -> :ok
              end
            end)
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      assert_receive {:caller_locked, caller_pid}, 3000

      try do
        helper.("UPDATE")

        worker =
          Task.async(fn ->
            Postgres.record_outcome_committed(target(c), grant.claim, :held, lock_timeout_ms: 300)
          end)

        result = Task.yield(worker, 900)

        if is_nil(result) do
          send(caller_pid, :release)
          :ok
          Task.await(worker, 5000)
        end

        assert {:ok, %Result{status: :failure, reason: :outcome_unrecorded}} = result

        probe_repo = connection!(c, :runtime, 1)
        SQL.query!(probe_repo, "SET lock_timeout='300ms'", [])

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03", where: where}}} =
                 record_outcome(%{c | runtime_repo: probe_repo}, grant.claim.id)

        assert where =~ "ash_onetime_claim_visible"
      after
        send(caller_pid, :release)
        Task.await(caller, 5000)

        SQL.query!(
          c.owner_repo,
          "DROP POLICY runtime_locks ON #{rel(c, "ash_onetime_idempotency_claims")}",
          []
        )

        SQL.query!(
          c.owner_repo,
          "DROP POLICY consumer_helper_visible ON #{rel(c, "ash_onetime_idempotency_claims")}",
          []
        )

        SQL.query!(
          c.owner_repo,
          "REVOKE SELECT,UPDATE ON #{rel(c, "ash_onetime_idempotency_claims")} FROM #{q(c.maintainer)}",
          []
        )
      end
    end
  end
end
