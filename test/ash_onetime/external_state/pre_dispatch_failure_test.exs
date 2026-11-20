for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.PreDispatchFailureTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for termination <- [:idle_timeout, :same_role] do
      @tag :enforcement_raised_before_dispatch_mutation
      @tag termination: termination
      test "#{partitioning || "plain"}: #{termination} of a checked out transaction stays disconnected",
           c do
        pool = connection!(c, :runtime, 1)
        observer = connection!(c, :runtime, 1)
        native = %{c | runtime_repo: pool}
        native_target = target(native)
        request = request!("terminated-#{c.termination}")
        reference = make_ref()
        parent = self()

        # The transaction keeps its connection checked out while PostgreSQL
        # terminates it. All observation uses another connection of the same role.
        # Keep the result even if the dead transaction's COMMIT then raises.
        try do
          runtime_transaction(native, fn ->
            assert [[pid, role]] =
                     SQL.query!(pool, "SELECT pg_backend_pid(), current_user", []).rows

            assert role == c.runtime
            assert [[^role]] = SQL.query!(observer, "SELECT current_user", []).rows

            case c.termination do
              :idle_timeout ->
                SQL.query!(pool, "SET LOCAL idle_in_transaction_session_timeout = '100ms'", [])

              :same_role ->
                assert [[true]] =
                         SQL.query!(observer, "SELECT pg_terminate_backend($1)", [pid]).rows
            end

            assert backend_gone?(observer, pid, System.monotonic_time(:millisecond) + 5_000)
            send(parent, {reference, Postgres.claim(native_target, request)})
          end)
        rescue
          _error in [Postgrex.Error, DBConnection.ConnectionError] -> :terminated_transaction
        catch
          :exit, _reason -> :terminated_transaction
        end

        assert_receive {^reference,
                        %Result{
                          status: :failure,
                          reason: :disconnected,
                          admission_dispatch: :unknown,
                          transaction: :unknown
                        }},
                       5_000

        assert [[0]] =
                 SQL.query!(
                   c.runtime_repo,
                   "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE key_hash=$1",
                   [request.key_hash]
                 ).rows
      end
    end

    defp backend_gone?(observer, pid, deadline) do
      case SQL.query!(observer, "SELECT count(*) FROM pg_stat_activity WHERE pid=$1", [pid]).rows do
        [[0]] ->
          true

        [[1]] ->
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(10)
            backend_gone?(observer, pid, deadline)
          else
            false
          end
      end
    end
  end
end
