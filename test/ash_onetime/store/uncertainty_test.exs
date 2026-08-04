defmodule AshOnetime.Store.UncertaintyTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.FaultStore

  @moduletag :store

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "a checkout failure before callback entry is the sole not-started store failure", %{
    prefix: prefix
  } do
    dead_repo = spawn(fn -> :ok end)
    monitor = Process.monitor(dead_repo)
    assert_receive {:DOWN, ^monitor, :process, ^dead_repo, :normal}

    target = %Postgres.Target{repo_module: Repo, dynamic_repo: dead_repo, prefix: prefix}

    assert %Result{
             status: :failure,
             reason: :checkout_unavailable,
             admission_dispatch: :not_started,
             transaction: :not_applicable
           } = Store.claim(target, idempotency_request("checkout-unavailable"))
  end

  @tag unboxed: true
  test "claim refuses to create an independent transaction", %{target: target} do
    assert %Result{
             status: :failure,
             reason: :not_in_transaction,
             admission_dispatch: :not_started
           } = Store.claim(target, idempotency_request("no-transaction"))
  end

  test "an expired nonce is rejected before admission SQL", %{prefix: prefix, target: target} do
    evaluated_at = Clock.now()
    request = nonce_request("expired", issued_at: DateTime.add(evaluated_at, -61, :second))

    assert {:ok,
            %Result{
              status: :failure,
              reason: :invalid_nonce_window,
              admission_dispatch: :not_started
            }} = Repo.transaction(fn -> Store.claim(target, request) end)

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM #{relation(prefix, "ash_onetime_nonce_claims")}",
               []
             )
  end

  test "a failed SHOW precondition is classified after dispatch, never not-started", %{
    target: target
  } do
    parent = self()

    _transaction_result =
      Repo.transaction(fn ->
        assert {:error, %Postgrex.Error{}} = SQL.query(Repo, "SELECT 1 / 0", [])
        result = Store.claim(target, idempotency_request("failed-show"))
        send(parent, {:failed_show_result, result})
        result
      end)

    assert_receive {:failed_show_result,
                    %Result{
                      status: :failure,
                      admission_dispatch: :sent,
                      transaction: :rolled_back
                    }}
  end

  test "a meaningful payload-byte corruption is terminal", %{prefix: prefix, target: target} do
    request = idempotency_request("corrupt-payload")
    payload = "stored-response"
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :complete, claim: claim}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, payload)
             end)

    SQL.query!(
      Repo,
      """
      UPDATE #{relation(prefix, "ash_onetime_response_payloads")}
      SET encoded_response = $1
      WHERE partition_date = $2 AND claim_id = $3::uuid
      """,
      ["stored-responsf", claim.response_partition, Ecto.UUID.dump!(claim.id)]
    )

    assert {:ok, %Result{status: :failure, reason: :corrupt_payload}} =
             Repo.transaction(fn -> Store.load(target, claim) end)
  end

  @tag operation_hash_select_mutation: true
  test "operation hash remains part of the shared command-two and load sink", %{target: target} do
    base = idempotency_request("operation-a")
    request_a = %{base | operation_hash: hash("operation-a")}

    request_b = %{
      base
      | id: Ecto.UUID.generate(),
        operation_hash: hash("operation-b"),
        fingerprint: hash("fingerprint-b")
    }

    assert {:ok, %Result{status: :admitted, claim: claim_a}} =
             Repo.transaction(fn -> Store.claim(target, request_a) end)

    assert {:ok, %Result{status: :admitted, claim: claim_b}} =
             Repo.transaction(fn -> Store.claim(target, request_b) end)

    assert claim_a.operation_hash != claim_b.operation_hash

    assert {:ok, %Result{status: :processing, claim: collision}} =
             Repo.transaction(fn -> Store.claim(target, request_a) end)

    assert collision.id == claim_a.id
    assert collision.operation_hash == request_a.operation_hash

    assert {:ok, %Result{status: :processing, claim: loaded_a}} =
             Repo.transaction(fn -> Store.load(target, claim_a) end)

    assert loaded_a.operation_hash == request_a.operation_hash
  end

  test "fault store exposes distinct conservative failure classes" do
    failures = [
      Result.failure(:checkout_unavailable, :not_started, :not_applicable),
      Result.failure(:dispatched_unknown, :unknown, :unknown),
      Result.failure(:disconnected, :unknown, :unknown),
      Result.failure(:lock_timeout, :sent, :rolled_back),
      Result.failure(:rolled_back, :sent, :rolled_back),
      Result.failure(:corrupt_payload, :sent, :open)
    ]

    on_exit(&FaultStore.reset/0)

    for result <- failures do
      FaultStore.put_result(result)
      assert FaultStore.claim(:target, :request) == result
    end

    assert Enum.count(failures, &(&1.admission_dispatch == :not_started)) == 1
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
