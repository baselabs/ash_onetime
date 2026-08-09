defmodule AshOnetime.Store.TransactionTest do
  use AshOnetime.Test.StoreCase, async: false

  @moduletag :store

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "claim rolls back with the caller transaction", %{target: target, prefix: prefix} do
    request = idempotency_request("caller-rollback")

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert %Result{status: :admitted} = Store.claim(target, request)
               Repo.rollback(:forced_rollback)
             end)

    assert {:ok, %Result{status: :admitted}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               """
               SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")}
               WHERE operation_hash = $1 AND scope_hash = $2 AND key_hash = $3
               """,
               [request.operation_hash, request.scope_hash, request.key_hash]
             )
  end

  test "database time derives retention after a long transaction regardless of app clock", %{
    target: target
  } do
    request = idempotency_request("database-retention", retention_seconds: 90)

    assert {:ok, {transaction_started_at, %Result{status: :admitted, claim: claim}}} =
             Repo.transaction(fn ->
               %{rows: [[started_at]]} =
                 SQL.query!(Repo, "SELECT transaction_timestamp()", [])

               SQL.query!(Repo, "SELECT pg_sleep(0.05)", [])
               {started_at, Store.claim(target, request)}
             end)

    assert claim.admitted_at == transaction_started_at
    assert DateTime.diff(claim.retain_until, claim.admitted_at, :second) == 90

    refute Map.has_key?(Map.from_struct(request), :retain_until)
  end

  @tag unboxed: true
  test "store rejects isolation other than READ COMMITTED", %{target: target} do
    request = idempotency_request("wrong-isolation")

    assert {:ok, %Result{status: :failure, reason: :unsupported_isolation}} =
             Repo.transaction(
               fn ->
                 SQL.query!(Repo, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", [])
                 Store.claim(target, request)
               end,
               isolation: :serializable
             )
  end

  test "target resolves the live repo and rejects a missing context tenant", %{prefix: prefix} do
    assert {:ok, %Postgres.Target{repo_module: Repo, prefix: nil}} =
             Postgres.target(AshOnetime.Test.StoreResource)

    assert %Result{status: :failure, reason: :missing_prefix} =
             Postgres.target(AshOnetime.Test.TenantStoreResource)

    assert {:ok, %Postgres.Target{repo_module: Repo, prefix: ^prefix}} =
             Postgres.target(AshOnetime.Test.TenantStoreResource, tenant: prefix)
  end

  @tag prefix_length_bound_mutation: true
  test "target rejects a context tenant prefix beyond PostgreSQL's 63-byte identifier limit" do
    within_bound = String.duplicate("t", 63)
    over_bound = String.duplicate("t", 64)

    assert {:ok, %Postgres.Target{prefix: ^within_bound}} =
             Postgres.target(AshOnetime.Test.TenantStoreResource, tenant: within_bound)

    assert %Result{status: :failure, reason: :missing_prefix} =
             Postgres.target(AshOnetime.Test.TenantStoreResource, tenant: over_bound)
  end

  @tag for_repo_prefix_bound_mutation: true
  test "for_repo rejects a schema prefix beyond PostgreSQL's 63-byte identifier limit" do
    within_bound = String.duplicate("t", 63)
    over_bound = String.duplicate("t", 64)

    assert %Postgres.Target{prefix: nil} = Postgres.for_repo(Repo)
    assert %Postgres.Target{prefix: ^within_bound} = Postgres.for_repo(Repo, within_bound)

    assert_raise ArgumentError, fn -> Postgres.for_repo(Repo, over_bound) end
  end

  test "quoted prefix selects the installed tenant-local store", %{prefix: prefix} do
    assert {:ok, %Postgres.Target{} = target} =
             Postgres.target(AshOnetime.Test.TenantStoreResource, tenant: prefix)

    assert {:ok, %Result{status: :admitted}} =
             Repo.transaction(fn -> Store.claim(target, idempotency_request("tenant-prefix")) end)
  end

  @tag unboxed: true
  @tag dynamic_repo_mutation: true
  test "two live dynamic repo instances preserve their transaction and quoted prefix", %{
    prefix: prefix
  } do
    repo_a = start_live_repo!()
    repo_b = start_live_repo!()
    on_exit(fn -> stop_live_repo(repo_a) end)
    on_exit(fn -> stop_live_repo(repo_b) end)
    request = idempotency_request("two-dynamic-repos")
    parent = self()
    task_a = live_repo_task(parent, repo_a, prefix, request, :hold)
    task_a_pid = task_a.pid
    assert_receive {:live_repo_ready, ^task_a_pid, backend_a}
    send(task_a_pid, :start_claim)
    assert_receive {:live_repo_claimed, ^task_a_pid, :admitted}

    task_b =
      live_repo_task(parent, repo_b, prefix, %{request | id: Ecto.UUID.generate()}, :proceed)

    task_b_pid = task_b.pid
    assert_receive {:live_repo_ready, ^task_b_pid, backend_b}
    assert repo_a != repo_b
    assert backend_a != backend_b
    send(task_a.pid, :release)

    assert {:ok, {^backend_a, %Result{status: :admitted, claim: claim_a}}} =
             Task.await(task_a, 5_000)

    assert {:ok, {^backend_b, %Result{status: :processing, claim: claim_b}}} =
             Task.await(task_b, 5_000)

    assert claim_a.id == claim_b.id

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               """
               SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")}
               WHERE operation_hash = $1 AND scope_hash = $2 AND key_hash = $3
               """,
               [request.operation_hash, request.scope_hash, request.key_hash]
             )
  end

  defp start_live_repo! do
    {:ok, pid} =
      Repo.start_link(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    Process.unlink(pid)
    pid
  end

  defp stop_live_repo(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000)
  end

  defp live_repo_task(parent, dynamic_repo, prefix, request, mode) do
    Task.async(fn ->
      previous = Repo.get_dynamic_repo()
      Repo.put_dynamic_repo(dynamic_repo)

      try do
        target = Postgres.for_repo(Repo, prefix)

        Repo.transaction(fn ->
          %{rows: [[backend]]} = SQL.query!(dynamic_repo, "SELECT pg_backend_pid()", [])
          send(parent, {:live_repo_ready, self(), backend})

          if mode == :hold do
            receive do
              :start_claim -> :ok
            end
          end

          result = Store.claim(target, request)

          if mode == :hold do
            send(parent, {:live_repo_claimed, self(), result.status})

            receive do
              :release -> :ok
            end
          end

          {backend, result}
        end)
      after
        Repo.put_dynamic_repo(previous)
      end
    end)
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
