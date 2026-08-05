defmodule AshOnetime.System.FailureDirectionTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.{Admission, Error}
  alias AshOnetime.Resource.Info
  alias AshOnetime.Store.Result
  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.FaultStore

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup do
    Admission.put_test_store(FaultStore)

    on_exit(fn ->
      FaultStore.reset()
      Admission.reset_test_store()
    end)

    :ok
  end

  @tag nonce_failure_direction_mutation: true
  test "nonce always fails closed while only a definite idempotency checkout can opt out" do
    idempotency = Info.protection(Resource, :redeem)
    nonce = Info.protection(Resource, :consume)

    idempotency_input = input(:redeem, %{value: 4, request_key: "system-fault"})
    nonce_input = input(:consume, %{value: 4, proof: "system-fault"})
    checkout = Result.failure(:checkout_unavailable, :not_started, :not_applicable)
    FaultStore.put_result(checkout)

    assert {:execute_untracked, %{class: :untracked}} =
             Admission.reserve(
               idempotency_input,
               %{idempotency | on_definite_store_failure: :execute_untracked},
               %{}
             )

    assert {:error, %Error{code: :checkout_unavailable}} =
             Admission.reserve(nonce_input, nonce, %{})

    for failure <- [
          Result.failure(:lock_timeout, :sent, :rolled_back),
          Result.failure(:disconnected, :unknown, :unknown),
          Result.failure(:dispatched_unknown, :unknown, :unknown)
        ] do
      FaultStore.put_result(failure)

      assert {:error, %Error{code: code}} =
               Admission.reserve(
                 idempotency_input,
                 %{idempotency | on_definite_store_failure: :execute_untracked},
                 %{}
               )

      assert code == failure.reason

      assert {:error, %Error{code: nonce_code}} =
               Admission.reserve(nonce_input, nonce, %{})

      assert nonce_code == failure.reason
    end
  end

  test "a real PostgreSQL claim runs inside the caller transaction", %{target: target} do
    assert {:ok, %Result{status: :admitted, transaction: :open}} =
             Repo.transaction(fn ->
               Store.claim(target, idempotency_request("system-transaction"))
             end)
  end

  defp input(action, arguments) do
    Resource
    |> Ash.ActionInput.for_action(action, arguments)
    |> Ash.ActionInput.set_tenant("system-fault-tenant")
  end
end
