# Test stub: a repo whose get_dynamic_repo/0 raises, so committed_claim_transaction's rescue
# (inside claim_committed/2's spawned worker) fires — exercising the rescue→telemetry wiring
# through the PUBLIC claim_committed/2 entry without exposing the un-spawned inner fn.
defmodule AshOnetime.Test.RaisingDynamicRepo do
  @moduledoc false

  def get_dynamic_repo, do: raise("forced committed_claim_transaction fault")
  def put_dynamic_repo(_repo), do: :ok
end

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

    target = %Postgres.Target{
      repo_module: Repo,
      dynamic_repo: dead_repo,
      prefix: prefix,
      logical_partition: "global"
    }

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

  # L6: a raise inside committed_claim_transaction emits [:ash_onetime, :uncertain_exception]
  # (with the exception CLASS, not the struct) before collapsing to :dispatched_unknown. The
  # prior telemetry_test exercised Telemetry.uncertain_exception/2 as an API unit; this drives
  # the rescue through the PUBLIC claim_committed/2 entry so the spawn + rescue + telemetry
  # wiring is exercised end-to-end. The fault is injected via a stub repo whose
  # get_dynamic_repo/0 raises (with_dynamic_repo/2 calls it first inside the spawned worker),
  # so committed_claim_transaction's rescue catches it, emits, and collapses.
  @tag committed_claim_rescue_telemetry: true
  test "committed_claim_transaction rescue emits uncertain_exception via claim_committed/2" do
    handler = "ash-onetime-committed-rescue-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:ash_onetime, :uncertain_exception],
      fn event, measurements, metadata, _config ->
        send(parent, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    target = %Postgres.Target{
      repo_module: AshOnetime.Test.RaisingDynamicRepo,
      dynamic_repo: Repo,
      prefix: nil,
      logical_partition: "global"
    }

    assert %Result{status: :failure, reason: :dispatched_unknown} =
             Store.claim_committed(target, idempotency_request("committed-rescue"))

    assert_receive {:event, [:ash_onetime, :uncertain_exception], %{count: 1}, metadata}
    assert metadata.phase == :committed_claim
    assert metadata.exception == RuntimeError
    assert metadata.strategy == :idempotency
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
