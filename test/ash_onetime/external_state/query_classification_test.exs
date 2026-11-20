for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.QueryClassificationTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for {rule, code, reason, dispatch, transaction} <- [
      {"query-classify-privilege", "42501", :store_invariant, :sent, :rolled_back},
      {"query-classify-lock", "55P03", :lock_timeout, :sent, :rolled_back},
      {"query-classify-completion-unknown", "40003", :dispatched_unknown, :unknown, :unknown},
      {"query-classify-connection", "08006", :disconnected, :unknown, :unknown},
      {"query-classify-shutdown", "57P01", :disconnected, :unknown, :unknown},
      {"query-classify-idle", "25P03", :disconnected, :unknown, :unknown},
      {"query-classify-transient", "40001", :store_failure, :sent, :rolled_back},
      {"query-classify-postgres-other", "23514", :store_invariant, :sent, :rolled_back}
    ] do
      @code code
      @reason reason
      @dispatch dispatch
      @transaction transaction
      @tag [{String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}]
      test "#{partitioning || "plain"}: SQLSTATE #{@code} retains its dispatch and transaction classification", c do
        SQL.query!(c.owner_repo, "CREATE FUNCTION #{rel(c, "insert_error")}() RETURNS trigger LANGUAGE plpgsql AS #{literal("BEGIN RAISE EXCEPTION 'consumer insert refused' USING ERRCODE='#{@code}'; END")}", [])
        SQL.query!(c.owner_repo, "CREATE TRIGGER consumer_insert_error BEFORE INSERT ON #{rel(c, "ash_onetime_idempotency_claims")} FOR EACH ROW EXECUTE FUNCTION #{rel(c, "insert_error")}()", [])
        on_exit(fn ->
          SQL.query!(c.owner_repo, "DROP TRIGGER consumer_insert_error ON #{rel(c, "ash_onetime_idempotency_claims")}", [])
          SQL.query!(c.owner_repo, "DROP FUNCTION #{rel(c, "insert_error")}()", [])
        end)

        assert {:error, :classified} = runtime_transaction(c, fn ->
          assert %Result{status: :failure, reason: @reason, admission_dispatch: @dispatch, transaction: @transaction} = Postgres.claim(target(c), request!("query-error"))
          Repo.rollback(:classified)
        end)
        assert [[0]] = SQL.query!(c.owner_repo, "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}", []).rows
      end
    end
  end
end
