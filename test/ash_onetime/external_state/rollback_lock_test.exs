for partitioning <- [nil, 2], migration <- [:install, :external_state, :maintenance] do
  defmodule Module.concat(
              AshOnetime.ExternalState.RollbackLockTest,
              "Claims#{partitioning || "Plain"}#{Macro.camelize(to_string(migration))}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.ShippedMigrations
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true
    @moduletag :external_state_rollback_lock_mutation

    test "#{partitioning || "plain"}: #{migration} rollback excludes reservations after its refusal count",
         c do
      {version, module, tag} = prepare(c, unquote(migration), unquote(partitioning))
      gate = System.unique_integer([:positive])
      probe = "ao_rollback_probe_#{gate}"
      trigger = probe <> "_event"
      gate_repo = connection!(c, :owner, 1)
      down_repo = connection!(c, :owner, 2)
      SQL.query!(gate_repo, "SELECT pg_advisory_lock($1)", [gate])

      # The event runs before the first protection-removing DDL. It leaves the
      # migration's real transaction and refusal query untouched.
      SQL.query!(
        Repo,
        "CREATE FUNCTION #{rel(c, probe)}() RETURNS event_trigger LANGUAGE plpgsql AS $probe$ BEGIN IF current_user=#{literal(c.owner)} THEN PERFORM pg_advisory_xact_lock(#{gate}); END IF; END $probe$",
        []
      )

      SQL.query!(
        Repo,
        "CREATE EVENT TRIGGER #{q(trigger)} ON ddl_command_start WHEN TAG IN (#{literal(tag)}) EXECUTE FUNCTION #{rel(c, probe)}()",
        []
      )

      on_exit(fn ->
        SQL.query!(Repo, "DROP EVENT TRIGGER IF EXISTS #{q(trigger)}", [])
        SQL.query!(Repo, "DROP FUNCTION IF EXISTS #{rel(c, probe)}()", [])
      end)

      down =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(down_repo)

          try do
            Ecto.Migrator.down(Repo, version, module, prefix: c.schema, log: false)
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      try do
        wait_for_gate!(c, gate)

        grant =
          Postgres.claim_committed(target(c), request!("rollback-race"), lock_timeout_ms: 300)

        assert %Result{status: :failure, reason: :lock_timeout} = grant
      after
        SQL.query!(gate_repo, "SELECT pg_advisory_unlock($1)", [gate])
        assert :ok = Task.await(down, 15_000)
      end
    end

    test "#{partitioning || "plain"}: B8 #{migration} rollback is bounded beside L3 and bounds queued callers",
         c do
      {version, module, _} = prepare(c, unquote(migration), unquote(partitioning))

      held_migration(c, fn ->
        Ecto.Migrator.down(Repo, version, module, prefix: c.schema, log: false)
      end)
    end

    if migration == :external_state do
      test "#{partitioning || "plain"}: B8 maintenance upgrade is bounded beside L3 and bounds queued callers",
           c do
        prepare(c, :external_state, unquote(partitioning))
        source = Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer)
        module = compile_migration(source)

        held_migration(c, fn ->
          Ecto.Migrator.up(Repo, 14, module, prefix: c.schema, log: false)
        end)
      end
    end

    defp held_migration(c, migration) do
      t = target(c)
      grant = Postgres.claim_committed(t, request!("B8-held"), lock_timeout_ms: 300)
      caller_repo = connection!(c, :runtime, 1)
      parent = self()

      caller =
        Task.async(fn ->
          runtime_transaction(%{c | runtime_repo: caller_repo}, fn ->
            assert %Result{status: :processing} =
                     Postgres.lock_for_effect(%{t | dynamic_repo: caller_repo}, grant.claim,
                       lock_timeout_ms: 300
                     )

            send(parent, {:B8_held, self()})

            receive do
              :complete -> :ok
            after
              10_000 -> flunk("B8 caller was not released")
            end

            Postgres.complete_external(
              %{t | dynamic_repo: caller_repo},
              grant.claim,
              "test",
              :crypto.hash(:sha256, "response"),
              "response",
              nil,
              lock_timeout_ms: 300
            )
          end)
        end)

      assert_receive {:B8_held, caller_pid}, 3000
      migrator_repo = connection!(c, :owner, 2)
      started = System.monotonic_time(:millisecond)

      migrating =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(migrator_repo)

          try do
            migration.()
          rescue
            error in Postgrex.Error -> {:error, error}
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      try do
        await_migration_wait(c, 300)
        queued_repo = connection!(c, :runtime, 2)
        queued_started = System.monotonic_time(:millisecond)

        assert %Result{status: :failure, reason: :lock_timeout} =
                 Postgres.claim_committed(%{t | dynamic_repo: queued_repo}, request!("B8-queued"),
                   lock_timeout_ms: 300
                 )

        assert System.monotonic_time(:millisecond) - queued_started < 1300

        assert {:error, :rollback} =
                 runtime_transaction(%{c | runtime_repo: queued_repo}, fn ->
                   SQL.query!(queued_repo, "SET LOCAL lock_timeout='300ms'", [])

                   assert %Result{status: :failure, reason: :lock_timeout} =
                            Postgres.claim(%{t | dynamic_repo: queued_repo}, request!("B8-local"))
                 end)

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                 Task.await(migrating, 6500)

        assert System.monotonic_time(:millisecond) - started < 6500
      after
        send(caller_pid, :complete)
      end

      assert {:ok, %Result{status: :complete}} = Task.await(caller, 3000)

      assert scalar(
               c.runtime_repo,
               "SELECT state='complete' FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             )
    end

    defp await_migration_wait(c, remaining) do
      if scalar(
           c.owner_repo,
           "SELECT EXISTS (SELECT 1 FROM pg_locks l JOIN pg_class r ON r.oid=l.relation JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname=$1 AND l.mode='AccessExclusiveLock' AND NOT l.granted)",
           [c.schema]
         ) do
        :ok
      else
        assert remaining > 0
        Process.sleep(10)
        await_migration_wait(c, remaining - 1)
      end
    end

    defp compile_migration(source) do
      module = Module.concat(__MODULE__, "Migration#{System.unique_integer([:positive])}")

      source =
        Regex.replace(~r/defmodule [A-Za-z0-9_.]+ do/, source, "defmodule #{inspect(module)} do",
          global: false
        )

      Code.compile_string(source)

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
      end)

      module
    end

    defp wait_for_gate!(c, gate, remaining \\ 300)

    defp wait_for_gate!(_c, _gate, 0),
      do: flunk("native rollback did not reach its post-count DDL barrier")

    defp wait_for_gate!(c, gate, remaining) do
      if scalar(
           c.owner_repo,
           "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=0 AND objid=$1::oid AND NOT granted)",
           [gate]
         ) do
        :ok
      else
        receive do
        after
          10 -> :ok
        end

        wait_for_gate!(c, gate, remaining - 1)
      end
    end

    defp prepare(c, migration, partitions) do
      if migration == :install do
        assert :ok = install(c)
        {20_261_116_000_001, c.migration_module, "DROP FUNCTION"}
      else
        options = if partitions, do: [hash_partitions: partitions], else: []
        migrate!(c, 10, ShippedMigrations.render("v0.6.0", :render, Repo, options))

        migrate!(
          c,
          11,
          ShippedMigrations.render("v1.1.0", :render_logical_partition_upgrade, Repo, [])
        )

        migrate!(c, 12, Generator.render_operation_hold_upgrade(Repo, []))
        external = migrate!(c, 13, Generator.render_external_state_upgrade(Repo, []))

        if migration == :external_state do
          {13, external, "DROP POLICY"}
        else
          maintenance =
            migrate!(
              c,
              14,
              Generator.render_maintenance_upgrade(Repo, maintenance_role: c.maintainer)
            )

          {14, maintenance, "REVOKE"}
        end
      end
    end

    defp migrate!(c, version, source) do
      module = compile_migration(source)
      previous = Repo.put_dynamic_repo(c.owner_repo)

      try do
        assert :ok = Ecto.Migrator.up(Repo, version, module, prefix: c.schema, log: false)
      after
        Repo.put_dynamic_repo(previous)
      end

      module
    end
  end
end
