for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.OperationHoldRaceTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.ShippedMigrations
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag install_in_test: true
    @moduletag hash_partitions: partitioning

    test "#{partitioning || "plain"}: operation-hold rollback excludes a hold set after its refusal count",
         c do
      migrate(
        c,
        1,
        ShippedMigrations.render("v1.1.0", :render, Repo, hash_partitions: unquote(partitioning))
      )

      hold_module = migrate(c, 2, Generator.render_operation_hold_upgrade(Repo, []))
      id = Ecto.UUID.bingenerate()

      SQL.query!(
        c.runtime_repo,
        "INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (id,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at) VALUES ($1,sha256('op'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('request'::bytea),'complete',current_date,'test',sha256('response'::bytea),transaction_timestamp(),transaction_timestamp()+interval '1 day',transaction_timestamp())",
        [id]
      )

      SQL.query!(
        c.runtime_repo,
        "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} (logical_partition,partition_date,claim_id,encoded_response) VALUES ('global',current_date,$1,'response'::bytea)",
        [id]
      )

      gate = System.unique_integer([:positive])
      function = "hold_gate_#{gate}"
      event = function <> "_event"

      SQL.query!(
        Repo,
        "CREATE FUNCTION #{rel(c, function)}() RETURNS event_trigger LANGUAGE plpgsql AS $gate$ BEGIN IF current_user=#{literal(c.owner)} THEN PERFORM pg_advisory_xact_lock(#{gate}); END IF; END $gate$",
        []
      )

      SQL.query!(
        Repo,
        "CREATE EVENT TRIGGER #{q(event)} ON ddl_command_start WHEN TAG IN ('CREATE FUNCTION') EXECUTE FUNCTION #{rel(c, function)}()",
        []
      )

      on_exit(fn ->
        SQL.query!(Repo, "DROP EVENT TRIGGER IF EXISTS #{q(event)}", [])
        SQL.query!(Repo, "DROP FUNCTION IF EXISTS #{rel(c, function)}()", [])
      end)

      gate_repo = connection!(c, :owner, 1)
      down_repo = connection!(c, :owner, 2)
      writer = connection!(c, :runtime, 1)
      SQL.query!(gate_repo, "SELECT pg_advisory_lock($1)", [gate])

      down =
        Task.async(fn ->
          previous = Repo.put_dynamic_repo(down_repo)

          try do
            Ecto.Migrator.down(Repo, 2, hold_module, prefix: c.schema, log: false)
          after
            Repo.put_dynamic_repo(previous)
          end
        end)

      try do
        await_gate(c, gate)
        SQL.query!(writer, "SET lock_timeout='300ms'", [])

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                 SQL.query(
                   writer,
                   "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET hold_reference='concurrent' WHERE id=$1",
                   [id]
                 )
      after
        SQL.query!(gate_repo, "SELECT pg_advisory_unlock($1)", [gate])
        assert :ok = Task.await(down, 8000)
      end

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             ) == 1

      assert scalar(
               c.owner_repo,
               "SELECT count(*) FROM pg_attribute WHERE attrelid=$1::text::regclass AND attname='hold_reference' AND NOT attisdropped",
               [rel(c, "ash_onetime_idempotency_claims")]
             ) == 0
    end

    defp await_gate(c, gate, remaining \\ 300) do
      if scalar(
           c.owner_repo,
           "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
           [gate]
         ) > 0 do
        :ok
      else
        assert remaining > 0
        Process.sleep(5)
        await_gate(c, gate, remaining - 1)
      end
    end

    defp migrate(c, version, source) do
      module = Module.concat(__MODULE__, "Migration#{System.unique_integer([:positive])}")

      source =
        Regex.replace(~r/defmodule \S+ do/, source, "defmodule #{inspect(module)} do",
          global: false
        )

      Code.compile_string(source)

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
      end)

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
