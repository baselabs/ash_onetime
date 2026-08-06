defmodule AshOnetime.Store.ReapTest do
  use AshOnetime.Test.StoreCase, async: false

  @moduletag :store

  # 7 days, comfortably above the migration's 86_400 s (1 day) hard floor.
  @horizon 7 * 86_400

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  @tag reap_removes_abandoned_mutation: true
  test "reaps a processing recovery point past the abandonment horizon and its retention", %{
    prefix: prefix,
    target: target
  } do
    claim_id =
      insert_processing(prefix, "abandoned", inserted_ago: "40 days", retain_ago: "39 days")

    assert {:ok, 1} = Store.reap(target, 100, @horizon)
    assert claim_count(prefix, claim_id) == 0
  end

  @tag reap_retention_guard_mutation: true
  test "never reaps a processing claim still inside its retention horizon", %{
    prefix: prefix,
    target: target
  } do
    # Old enough to pass the abandonment cutoff and the floor, but retention has NOT lapsed
    # (a long-retention in-flight claim). Invariant (c): it is still recoverable.
    claim_id =
      insert_processing(prefix, "within-retention", inserted_ago: "40 days", retain_in: "40 days")

    assert {:ok, 0} = Store.reap(target, 100, @horizon)
    assert claim_count(prefix, claim_id) == 1

    # The guard re-enforces retention even when the reap session variable is armed to "now".
    assert_guarded_reap_delete(prefix, claim_id, "now")
    assert claim_count(prefix, claim_id) == 1
  end

  @tag reap_floor_guard_mutation: true
  test "never reaps a processing claim younger than the hard floor", %{prefix: prefix} do
    # Past retention but only hours old — below the 1-day floor. Even with the session variable
    # armed to "now" (any-age cutoff), the guard's floor rejects the delete.
    claim_id =
      insert_processing(prefix, "too-young", inserted_ago: "3 hours", retain_ago: "2 hours")

    assert_guarded_reap_delete(prefix, claim_id, "now")
    assert claim_count(prefix, claim_id) == 1
  end

  test "an un-sanctioned processing delete still raises (recovery-point invariant preserved)", %{
    prefix: prefix
  } do
    claim_id =
      insert_processing(prefix, "unsanctioned", inserted_ago: "40 days", retain_ago: "39 days")

    assert_guarded_delete(prefix, claim_id)
    assert claim_count(prefix, claim_id) == 1
  end

  test "leaves complete idempotency and nonce claims untouched", %{prefix: prefix, target: target} do
    processing_id =
      insert_processing(prefix, "reap-me", inserted_ago: "40 days", retain_ago: "39 days")

    complete_id = insert_expired_complete(prefix)
    insert_expired_nonce(prefix, "leave-nonce")

    assert {:ok, 1} = Store.reap(target, 100, @horizon)
    assert claim_count(prefix, processing_id) == 0
    assert claim_count(prefix, complete_id) == 1
    assert nonce_count(prefix) == 1
  end

  test "rejects an abandonment horizon below the safe floor", %{target: target} do
    assert %Result{status: :failure} = Store.reap(target, 100, 3_600)
  end

  test "rejects an out-of-range batch size before touching the database", %{target: target} do
    assert %Result{status: :failure, reason: :invalid_request} = Store.reap(target, 0, @horizon)

    assert %Result{status: :failure, reason: :invalid_request} =
             Store.reap(target, 20_000, @horizon)
  end

  # --- helpers ---

  defp insert_processing(prefix, label, timings) do
    claim_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'processing',
              #{inserted_expr(timings)}, #{retain_expr(timings)}, #{inserted_expr(timings)})
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

  defp inserted_expr(timings),
    do: "transaction_timestamp() - interval '#{Keyword.fetch!(timings, :inserted_ago)}'"

  defp retain_expr(timings) do
    cond do
      ago = timings[:retain_ago] -> "transaction_timestamp() - interval '#{ago}'"
      future = timings[:retain_in] -> "transaction_timestamp() + interval '#{future}'"
    end
  end

  defp insert_expired_complete(prefix) do
    claim_id = Ecto.UUID.generate()
    partition_date = Date.utc_today()
    payload = "reap-complete"
    digest = :crypto.hash(:sha256, payload)

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         response_partition, response_codec, response_digest,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'complete', $6, 'test', $7,
              transaction_timestamp() - interval '40 days',
              transaction_timestamp() - interval '39 days',
              transaction_timestamp() - interval '40 days')
      """,
      [
        Ecto.UUID.dump!(claim_id),
        hash("operation:complete"),
        hash("scope:complete"),
        hash("key:complete"),
        hash("fingerprint:complete"),
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

    claim_id
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

  defp assert_guarded_delete(prefix, claim_id) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.transaction(fn ->
               case delete_claim(prefix, claim_id) do
                 {:error, error} -> Repo.rollback(error)
                 result -> result
               end
             end)
  end

  defp assert_guarded_reap_delete(prefix, claim_id, reap_before) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.transaction(fn ->
               SQL.query!(
                 Repo,
                 "SELECT set_config('ash_onetime.reap_before', $1, true)",
                 [reap_before]
               )

               case delete_claim(prefix, claim_id) do
                 {:error, error} -> Repo.rollback(error)
                 result -> result
               end
             end)
  end

  defp delete_claim(prefix, claim_id) do
    SQL.query(
      Repo,
      "DELETE FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
      [Ecto.UUID.dump!(claim_id)]
    )
  end

  defp claim_count(prefix, claim_id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
        [Ecto.UUID.dump!(claim_id)]
      )

    count
  end

  defp nonce_count(prefix) do
    %{rows: [[count]]} =
      SQL.query!(Repo, "SELECT count(*) FROM #{relation(prefix, "ash_onetime_nonce_claims")}", [])

    count
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
