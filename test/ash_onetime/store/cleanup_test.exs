defmodule AshOnetime.Store.CleanupTest do
  use AshOnetime.Test.StoreCase, async: false

  @moduletag :store

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  @tag cleanup_boundary_mutation: true
  test "cleanup predicate, function, and parent triggers are strict at the retention boundary", %{
    prefix: prefix,
    target: target
  } do
    assert %{rows: [[false]]} =
             SQL.query!(
               Repo,
               "SELECT #{relation(prefix, "ash_onetime_cleanup_eligible")}(transaction_timestamp())",
               []
             )

    equal_claims =
      for strategy <- [:idempotency, :nonce], into: %{} do
        {strategy, insert_boundary_claim(prefix, strategy, "equal-#{strategy}", :equal)}
      end

    assert {:ok, %{idempotency: 0, nonce: 0}} = Store.cleanup(target, 100)

    for {strategy, claim_id} <- equal_claims do
      assert_guarded_delete(prefix, strategy, claim_id)
    end

    direct_after =
      for strategy <- [:idempotency, :nonce], into: %{} do
        {strategy, insert_boundary_claim(prefix, strategy, "direct-after-#{strategy}", :after)}
      end

    for {strategy, claim_id} <- direct_after do
      assert %{num_rows: 1} = delete_claim!(prefix, strategy, claim_id)
    end

    for strategy <- [:idempotency, :nonce] do
      insert_boundary_claim(prefix, strategy, "cleanup-after-#{strategy}", :after)
    end

    assert {:ok, %{idempotency: 1, nonce: 1}} = Store.cleanup(target, 100)
  end

  test "cleanup atomically removes explicit and default zero-byte payloads with their claims", %{
    prefix: prefix,
    target: target
  } do
    claim_id = Ecto.UUID.generate()
    default_claim_id = Ecto.UUID.generate()
    insert_expired_complete(prefix, claim_id, Date.utc_today(), <<>>)
    insert_expired_complete(prefix, default_claim_id, ~D[2100-01-01], <<>>)

    assert {:ok, %{idempotency: 2, nonce: 0}} = Store.cleanup(target, 100)

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")}",
               []
             )

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM #{relation(prefix, "ash_onetime_response_payloads")}",
               []
             )
  end

  test "cleanup rejects duplicate payload rows across partitions without deleting either row", %{
    prefix: prefix,
    target: target
  } do
    claim_id = Ecto.UUID.generate()
    insert_expired_complete(prefix, claim_id, Date.utc_today(), "current")

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_response_payloads")}
        (partition_date, claim_id, encoded_response)
      VALUES ($1, $2::uuid, $3)
      """,
      [~D[2100-01-01], Ecto.UUID.dump!(claim_id), "extra"]
    )

    assert %Result{status: :failure, reason: :store_invariant, transaction: :rolled_back} =
             Store.cleanup(target, 100)

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
               [Ecto.UUID.dump!(claim_id)]
             )

    assert %{rows: [[2]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM #{relation(prefix, "ash_onetime_response_payloads")} WHERE claim_id = $1::uuid",
               [Ecto.UUID.dump!(claim_id)]
             )
  end

  test "cleanup removes only its bounded eligible batch", %{prefix: prefix, target: target} do
    for index <- 1..3 do
      insert_expired_nonce(prefix, "batch-#{index}")
    end

    assert {:ok, %{idempotency: 0, nonce: 2}} = Store.cleanup(target, 2)

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM #{relation(prefix, "ash_onetime_nonce_claims")}",
               []
             )
  end

  defp insert_expired_complete(prefix, claim_id, partition_date, payload) do
    digest = :crypto.hash(:sha256, payload)

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         response_partition, response_codec, response_digest,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'complete', $6, 'test', $7,
              transaction_timestamp() - interval '2 hours',
              transaction_timestamp() - interval '1 hour',
              transaction_timestamp() - interval '2 hours')
      """,
      [
        Ecto.UUID.dump!(claim_id),
        hash("operation:" <> claim_id),
        hash("scope:" <> claim_id),
        hash("key:" <> claim_id),
        hash("fingerprint:" <> claim_id),
        partition_date,
        digest
      ]
    )

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_response_payloads")}
        (partition_date, claim_id, encoded_response)
      VALUES ($1, $2::uuid, $3)
      """,
      [partition_date, Ecto.UUID.dump!(claim_id), payload]
    )
  end

  defp insert_expired_nonce(prefix, label) do
    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_nonce_claims")}
        (id, operation_hash, scope_hash, key_hash, issued_at, verifier_id,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4,
              transaction_timestamp() - interval '3 hours', 'test',
              transaction_timestamp() - interval '2 hours',
              transaction_timestamp() - interval '1 hour',
              transaction_timestamp() - interval '2 hours')
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        hash("o:" <> label),
        hash("s:" <> label),
        hash("k:" <> label)
      ]
    )
  end

  defp insert_boundary_claim(prefix, :idempotency, label, boundary) do
    claim_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'processing',
              transaction_timestamp() - interval '1 hour',
              #{boundary_expression(boundary)},
              transaction_timestamp() - interval '1 hour')
      """,
      [
        Ecto.UUID.dump!(claim_id),
        hash("operation:" <> label),
        hash("scope:" <> label),
        hash("key:" <> label),
        hash("fingerprint:" <> label)
      ]
    )

    claim_id
  end

  defp insert_boundary_claim(prefix, :nonce, label, boundary) do
    claim_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_nonce_claims")}
        (id, operation_hash, scope_hash, key_hash, issued_at, verifier_id,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4,
              transaction_timestamp() - interval '2 hours', 'test',
              transaction_timestamp() - interval '1 hour',
              #{boundary_expression(boundary)},
              transaction_timestamp() - interval '1 hour')
      """,
      [
        Ecto.UUID.dump!(claim_id),
        hash("operation:" <> label),
        hash("scope:" <> label),
        hash("key:" <> label)
      ]
    )

    claim_id
  end

  defp assert_guarded_delete(prefix, strategy, claim_id) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.transaction(fn ->
               case delete_claim(prefix, strategy, claim_id) do
                 {:error, error} -> Repo.rollback(error)
                 result -> result
               end
             end)
  end

  defp delete_claim!(prefix, strategy, claim_id) do
    {:ok, result} = delete_claim(prefix, strategy, claim_id)
    result
  end

  defp delete_claim(prefix, strategy, claim_id) do
    table =
      case strategy do
        :idempotency -> "ash_onetime_idempotency_claims"
        :nonce -> "ash_onetime_nonce_claims"
      end

    SQL.query(
      Repo,
      "DELETE FROM #{relation(prefix, table)} WHERE id = $1::uuid",
      [Ecto.UUID.dump!(claim_id)]
    )
  end

  defp boundary_expression(:equal), do: "transaction_timestamp()"
  defp boundary_expression(:after), do: "transaction_timestamp() - interval '1 microsecond'"

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
