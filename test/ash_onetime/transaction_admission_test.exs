defmodule AshOnetime.TransactionAdmissionTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.{Error, Transaction, Verified}
  alias AshOnetime.Test.Clock

  @moduletag :store

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "idempotency executes once and replays the exact completed bytes", %{prefix: prefix} do
    options = idempotency_options(prefix, "tenant-a", "request-a", hash("body-a"))
    payload = <<0, 1, 2, 3, 255>>

    assert {:ok, :fresh} =
             Repo.transaction(fn ->
               assert {:execute, admission} = Transaction.idempotency(Repo, options)
               assert :ok = Transaction.complete(admission, payload)
               :fresh
             end)

    assert {:ok, {:replay, ^payload}} =
             Repo.transaction(fn -> Transaction.idempotency(Repo, options) end)
  end

  test "the same key with a different fingerprint conflicts", %{prefix: prefix} do
    first = idempotency_options(prefix, "tenant-a", "request-conflict", hash("body-a"))
    changed = Keyword.replace!(first, :fingerprint, hash("body-b"))

    assert {:ok, :done} =
             Repo.transaction(fn ->
               assert {:execute, admission} = Transaction.idempotency(Repo, first)
               assert :ok = Transaction.complete(admission, "stored")
               :done
             end)

    assert {:ok, {:error, %Error{code: :key_reused_with_different_request}}} =
             Repo.transaction(fn -> Transaction.idempotency(Repo, changed) end)
  end

  test "logical partitions isolate identical operation scope and key", %{prefix: prefix} do
    first = idempotency_options(prefix, "tenant-a", "same-key", hash("same-body"))
    second = Keyword.replace!(first, :partition, "tenant-b")

    assert {:ok, {:execute, first_admission}} =
             Repo.transaction(fn -> Transaction.idempotency(Repo, first) end)

    assert {:ok, {:execute, second_admission}} =
             Repo.transaction(fn -> Transaction.idempotency(Repo, second) end)

    refute first_admission.claim_id == second_admission.claim_id
  end

  test "nonce collision rejects within one partition and is independent across partitions", %{
    prefix: prefix
  } do
    first = nonce_options(prefix, "tenant-a", "nonce-a")
    second_partition = Keyword.replace!(first, :partition, "tenant-b")

    assert {:ok, :ok} = Repo.transaction(fn -> Transaction.nonce(Repo, first) end)

    assert {:ok, {:error, %Error{code: :nonce_already_used}}} =
             Repo.transaction(fn -> Transaction.nonce(Repo, first) end)

    assert {:ok, :ok} = Repo.transaction(fn -> Transaction.nonce(Repo, second_partition) end)
  end

  test "admission rejects outside a caller-owned transaction", %{prefix: prefix} do
    assert {:error, %Error{code: :not_in_transaction}} =
             Transaction.idempotency(
               Repo,
               idempotency_options(prefix, "tenant-a", "outside", hash("outside"))
             )
  end

  test "a caller rollback removes idempotency and nonce admission together", %{prefix: prefix} do
    idempotency = idempotency_options(prefix, "tenant-a", "rollback-key", hash("rollback"))
    nonce = nonce_options(prefix, "tenant-a", "rollback-nonce")

    assert {:error, :forced} =
             Repo.transaction(fn ->
               assert {:execute, _admission} = Transaction.idempotency(Repo, idempotency)
               assert :ok = Transaction.nonce(Repo, nonce)
               Repo.rollback(:forced)
             end)

    assert {:ok, {:execute, _admission}} =
             Repo.transaction(fn -> Transaction.idempotency(Repo, idempotency) end)

    assert {:ok, :ok} = Repo.transaction(fn -> Transaction.nonce(Repo, nonce) end)
  end

  test "the public option contract rejects extras, duplicates, and malformed partitions", %{
    prefix: prefix
  } do
    base = idempotency_options(prefix, "tenant-a", "bounded", hash("body"))

    for options <- [
          Keyword.put(base, :unknown, true),
          base ++ [key: "duplicate"],
          Keyword.replace!(base, :partition, ""),
          Keyword.replace!(base, :partition, String.duplicate("x", 256)),
          Keyword.replace!(base, :partition, <<255>>)
        ] do
      assert {:ok, {:error, %Error{code: :invalid_request}}} =
               Repo.transaction(fn -> Transaction.idempotency(Repo, options) end)
    end
  end

  test "nonce verified facts must bind the exact nonce key", %{prefix: prefix} do
    options = nonce_options(prefix, "tenant-a", "nonce-bound")

    changed =
      Keyword.update!(options, :verified, fn [verified] ->
        [%{verified | key: "different-nonce"}]
      end)

    assert {:ok, {:error, %Error{code: :invalid_request}}} =
             Repo.transaction(fn -> Transaction.nonce(Repo, changed) end)
  end

  test "replay is bound to the exact response codec", %{prefix: prefix} do
    options = idempotency_options(prefix, "tenant-a", "codec-bound", hash("body"))

    assert {:ok, :done} =
             Repo.transaction(fn ->
               assert {:execute, admission} = Transaction.idempotency(Repo, options)
               assert :ok = Transaction.complete(admission, "stored")
               :done
             end)

    changed = Keyword.replace!(options, :codec, "test.changed-codec")

    assert {:ok, {:error, %Error{code: :store_invariant}}} =
             Repo.transaction(fn -> Transaction.idempotency(Repo, changed) end)
  end

  test "completion requires the original process and an open caller transaction", %{
    prefix: prefix
  } do
    options = idempotency_options(prefix, "tenant-a", "completion-bound", hash("body"))

    assert {:ok, {:execute, admission}} =
             Repo.transaction(fn -> Transaction.idempotency(Repo, options) end)

    assert {:error, %Error{code: :not_in_transaction}} =
             Transaction.complete(admission, "late")

    task = Task.async(fn -> Transaction.complete(admission, "foreign") end)
    assert {:error, %Error{code: :invalid_request}} = Task.await(task)
  end

  defp idempotency_options(prefix, partition, key, fingerprint) do
    [
      operation: {__MODULE__, :management_command},
      partition: partition,
      prefix: prefix,
      scope: "principal-a",
      key: key,
      fingerprint: fingerprint,
      retention_seconds: 3_600,
      codec: "test.management-response"
    ]
  end

  defp nonce_options(prefix, partition, key) do
    now = Clock.now()

    [
      operation: {__MODULE__, :management_nonce},
      partition: partition,
      prefix: prefix,
      scope: "credential-a",
      key: key,
      verified: [
        %Verified{
          key: key,
          issued_at: now,
          expires_at: DateTime.add(now, 300, :second),
          verifier_id: "management-gateway"
        }
      ],
      max_age: 300,
      clock_skew: 0,
      clock: Clock
    ]
  end
end
