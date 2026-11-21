for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.QueryTransportTest,
              "Claims#{partitioning || "Plain"}"
            ) do
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

      assert %Result{
               status: :failure,
               reason: :checkout_unavailable,
               admission_dispatch: :not_started,
               transaction: :not_applicable
             } = result
    end

    @tag :enforcement_raised_after_dispatch_mutation
    test "#{partitioning || "plain"}: undecodable native state remains dispatched unknown", c do
      {:ok, %Result{claim: claim}} =
        runtime_transaction(c, fn -> Postgres.claim(target(c), request!("decode-state")) end)

      table = rel(c, "ash_onetime_idempotency_claims")

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{table} DROP CONSTRAINT ash_onetime_idempotency_claims_state_check",
        []
      )

      unknown = "state_" <> String.replace(Ecto.UUID.generate(), "-", "")

      on_exit(fn ->
        owner_replica(c, fn ->
          SQL.query!(c.owner_repo, "UPDATE #{table} SET state='processing' WHERE id=$1::uuid", [
            Ecto.UUID.dump!(claim.id)
          ])
        end)

        SQL.query!(
          c.owner_repo,
          "ALTER TABLE #{table} ADD CONSTRAINT ash_onetime_idempotency_claims_state_check CHECK (state IN ('processing','complete'))",
          []
        )
      end)

      assert {:ok, _} =
               owner_replica(c, fn ->
                 SQL.query!(c.owner_repo, "UPDATE #{table} SET state=$2 WHERE id=$1::uuid", [
                   Ecto.UUID.dump!(claim.id),
                   unknown
                 ])
               end)

      {:ok, result} =
        runtime_transaction(c, fn -> Postgres.load(target(c), claim, lock_timeout_ms: 300) end)

      assert %Result{
               status: :failure,
               reason: :dispatched_unknown,
               admission_dispatch: :unknown,
               transaction: :unknown
             } = result
    end

    @tag :enforcement_query_connection_error_mutation
    test "#{partitioning || "plain"}: a terminated native client stays disconnected after dispatch",
         c do
      pool = connection!(c, :runtime, 1)
      native = %{c | runtime_repo: pool}
      native_target = target(native)
      adapter_pool = Ecto.Adapter.lookup_meta(pool).pid

      [{supervisor, child_id, connection}] =
        for {_, supervisor, _, _} <-
              DynamicSupervisor.which_children(DBConnection.ConnectionPool.Supervisor),
            is_pid(supervisor),
            {child_id = {Postgrex.Protocol, ^adapter_pool, _}, connection, _, _} <-
              Supervisor.which_children(supervisor),
            do: {supervisor, child_id, connection}

      monitor = Process.monitor(connection)
      parent = self()

      try do
        runtime_transaction(native, fn ->
          assert [[role]] = SQL.query!(pool, "SELECT current_user", []).rows
          assert role == c.runtime
          :ok = Supervisor.terminate_child(supervisor, child_id)
          assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 5000

          send(
            parent,
            {:lost_client_result, Postgres.claim(native_target, request!("lost-client"))}
          )

          send(parent, {:native_driver_result, SQL.query(pool, "SELECT 1", [])})
        end)
      rescue
        _error in [Postgrex.Error, DBConnection.ConnectionError] -> :terminated_transaction
      catch
        :exit, _reason -> :terminated_transaction
      end

      assert_receive {:native_driver_result, {:error, %DBConnection.ConnectionError{}}}, 5000

      assert_receive {:lost_client_result,
                      %Result{
                        status: :failure,
                        reason: :disconnected,
                        admission_dispatch: :unknown,
                        transaction: :unknown
                      }},
                     5000
    end

    @tag :enforcement_query_other_error_mutation
    test "#{partitioning || "plain"}: a real COPY connection refusal remains dispatched unknown",
         c do
      table = rel(c, "consumer_copy")
      SQL.query!(c.owner_repo, "CREATE TABLE #{table}(value integer)", [])
      on_exit(fn -> SQL.query!(c.owner_repo, "DROP TABLE #{table}", []) end)
      parent = self()
      # Opening the Collectable starts PostgreSQL COPY before the store call.
      # Postgrex refuses the store's SHOW while this native stream owns the wire.
      try do
        runtime_transaction(c, fn ->
          {copy_state, finish_copy} =
            Collectable.into(SQL.stream(c.runtime_repo, "COPY #{table}(value) FROM STDIN", []))

          copy_state = finish_copy.(copy_state, {:cont, "1\n"})
          result = Postgres.claim(target(c), request!("copy-connection"))
          send(parent, {:copy_store_result, result})
          finish_copy.(copy_state, :halt)
        end)
      rescue
        _error -> :copy_connection_closed
      catch
        :exit, _reason -> :copy_connection_closed
      end

      assert_receive {:copy_store_result,
                      %Result{
                        status: :failure,
                        reason: :dispatched_unknown,
                        admission_dispatch: :unknown,
                        transaction: :unknown
                      }},
                     5000

      assert [[0]] = SQL.query!(c.owner_repo, "SELECT count(*) FROM #{table}", []).rows
    end
  end
end
