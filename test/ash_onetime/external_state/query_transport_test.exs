for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.QueryTransportTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    @tag :enforcement_raised_before_checkout_mutation
    test "#{partitioning || "plain"}: a stopped native pool proves checkout never started", c do
      pool = connection!(c, :runtime, 1)
      native_target = target(%{c | runtime_repo: pool})
      assert [[pid]] = SQL.query!(pool, "SELECT pg_backend_pid()", []).rows
      assert is_integer(pid)
      GenServer.stop(pool, :normal, 5000)
      result = Postgres.claim(native_target, request!("stopped-pool"))
      assert %Result{status: :failure, reason: :checkout_unavailable, admission_dispatch: :not_started, transaction: :not_applicable} = result
    end

    @tag :enforcement_raised_after_dispatch_mutation
    test "#{partitioning || "plain"}: undecodable native state remains dispatched unknown", c do
      {:ok, %Result{claim: claim}} = runtime_transaction(c, fn -> Postgres.claim(target(c), request!("decode-state")) end)
      table = rel(c, "ash_onetime_idempotency_claims")
      SQL.query!(c.owner_repo, "ALTER TABLE #{table} DROP CONSTRAINT ash_onetime_idempotency_claims_state_check", [])
      unknown = "state_" <> String.replace(Ecto.UUID.generate(), "-", "")
      on_exit(fn ->
        owner_replica(c, fn -> SQL.query!(c.owner_repo, "UPDATE #{table} SET state='processing' WHERE id=$1::uuid", [Ecto.UUID.dump!(claim.id)]) end)
        SQL.query!(c.owner_repo, "ALTER TABLE #{table} ADD CONSTRAINT ash_onetime_idempotency_claims_state_check CHECK (state IN ('processing','complete'))", [])
      end)
      assert {:ok, _} = owner_replica(c, fn -> SQL.query!(c.owner_repo, "UPDATE #{table} SET state=$2 WHERE id=$1::uuid", [Ecto.UUID.dump!(claim.id), unknown]) end)
      {:ok, result} = runtime_transaction(c, fn -> Postgres.load(target(c), claim, lock_timeout_ms: 300) end)
      assert %Result{status: :failure, reason: :dispatched_unknown, admission_dispatch: :unknown, transaction: :unknown} = result
    end

    @tag :enforcement_query_connection_error_mutation
    test "#{partitioning || "plain"}: a native query exceeding the client bound stays disconnected", c do
      pool = connection!(c, :runtime, 1, timeout: 250)
      native = %{c | runtime_repo: pool}
      SQL.query!(c.owner_repo, "CREATE FUNCTION #{rel(c, "slow_insert")}() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN PERFORM pg_sleep(1); RETURN NEW; END'", [])
      SQL.query!(c.owner_repo, "CREATE TRIGGER consumer_slow_insert BEFORE INSERT ON #{rel(c, "ash_onetime_idempotency_claims")} FOR EACH ROW EXECUTE FUNCTION #{rel(c, "slow_insert")}()", [])
      on_exit(fn ->
        SQL.query!(c.owner_repo, "DROP TRIGGER consumer_slow_insert ON #{rel(c, "ash_onetime_idempotency_claims")}", [])
        SQL.query!(c.owner_repo, "DROP FUNCTION #{rel(c, "slow_insert")}()", [])
      end)
      result = Postgres.claim_committed(target(native), request!("slow-client"), lock_timeout_ms: 3000)
      assert %Result{status: :failure, reason: :disconnected, admission_dispatch: :unknown, transaction: :unknown} = result
    end
    @tag :enforcement_query_other_error_mutation
    test "#{partitioning || "plain"}: a real COPY connection refusal remains dispatched unknown", c do
      table = rel(c, "consumer_copy")
      SQL.query!(c.owner_repo, "CREATE TABLE #{table}(value integer)", [])
      on_exit(fn -> SQL.query!(c.owner_repo, "DROP TABLE #{table}", []) end)
      parent = self()
      # Opening the Collectable starts PostgreSQL COPY before the store call.
      # Postgrex refuses the store's SHOW while this native stream owns the wire.
      try do
        runtime_transaction(c, fn ->
          {copy_state, finish_copy} = Collectable.into(SQL.stream(c.runtime_repo, "COPY #{table}(value) FROM STDIN", []))
          result = Postgres.claim(target(c), request!("copy-connection"))
          send(parent, {:copy_store_result, result})
          finish_copy.(copy_state, :halt)
        end)
      rescue
        _error -> :copy_connection_closed
      catch
        :exit, _reason -> :copy_connection_closed
      end
      assert_receive {:copy_store_result, %Result{status: :failure, reason: :dispatched_unknown, admission_dispatch: :unknown, transaction: :unknown}}, 5000
      assert [[0]] = SQL.query!(c.owner_repo, "SELECT count(*) FROM #{table}", []).rows
    end
  end
end
