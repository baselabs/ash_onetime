defmodule AshOnetime.Store.CommittedCompletionTest do
  # §2.7: `deliver/2` opens an envelope only on the committed completion of its exact
  # claim. The read runs outside any transaction, so it sees only committed rows, and it
  # binds the claim id, so another generation's row under the same logical key is never
  # adopted.
  use AshOnetime.Test.StoreCase, async: false

  @moduletag :store

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  @tag unboxed: true
  @tag committed_generation_mutation: true
  test "only the exact claim's committed completion reads complete", %{target: target} do
    request = idempotency_request("committed-generation")
    payload = "stored-response"
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    # Committed, still processing.
    assert Store.committed_completion(target, claim) == :absent

    assert {:ok, %Result{status: :complete}} =
             Repo.transaction(fn -> Store.complete(target, claim, "test", digest, payload) end)

    assert Store.committed_completion(target, claim) == :complete

    # A complete row cannot authorize another granted attempt under the same UUID.
    assert Store.committed_completion(target, %{claim | effect_attempt: claim.effect_attempt + 1}) == :absent

    # Same logical key, another claim id: a row reaped and re-inserted is not this claim.
    stranger = %{claim | id: Ecto.UUID.generate()}
    assert Store.committed_completion(target, stranger) == :absent
  end

  @tag unboxed: true
  test "a completion that rolled back is absent", %{target: target} do
    request = idempotency_request("committed-rollback")
    payload = "stored-response"
    digest = :crypto.hash(:sha256, payload)
    test = self()

    assert {:error, :undone} =
             Repo.transaction(fn ->
               %Result{status: :admitted, claim: claim} = Store.claim(target, request)
               %Result{status: :complete} = Store.complete(target, claim, "test", digest, payload)
               send(test, {:claim, claim})
               Repo.rollback(:undone)
             end)

    assert_received {:claim, claim}
    assert Store.committed_completion(target, claim) == :absent
  end

  @tag unboxed: true
  test "the read refuses inside a transaction", %{target: target} do
    request = idempotency_request("committed-in-transaction")

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert {:ok, %Result{status: :failure, reason: :in_transaction}} =
             Repo.transaction(fn -> Store.committed_completion(target, claim) end)
  end
end
