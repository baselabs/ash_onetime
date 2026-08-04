defmodule AshOnetime.Store.PostgresTest do
  use AshOnetime.Test.StoreCase, async: false

  @moduletag :store

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "idempotency admission collides on the full logical key", %{target: target} do
    request = idempotency_request("idempotency-collision")

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert {:ok, %Result{status: :processing, claim: collided}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert collided.id == claim.id
    assert collided.operation_hash == request.operation_hash
    assert collided.scope_hash == request.scope_hash
    assert collided.key_hash == request.key_hash
  end

  test "nonce admission returns an authoritative collision without response state", %{
    target: target
  } do
    request = nonce_request("nonce-collision")

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert claim.strategy == :one_time_nonce
    assert claim.response_codec == nil

    assert {:ok, %Result{status: :collision, claim: collided}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert collided.id == claim.id
  end

  test "completion and load accept a zero-byte payload", %{target: target} do
    request = idempotency_request("empty-payload")
    digest = :crypto.hash(:sha256, <<>>)

    assert {:ok, %Result{status: :complete, claim: complete, payload: <<>>}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, <<>>)
             end)

    assert complete.response_digest == digest

    assert {:ok, %Result{status: :complete, payload: <<>>}} =
             Repo.transaction(fn -> Store.load(target, complete) end)
  end

  test "completion accepts the Task 2 hard response ceiling exactly", %{target: target} do
    request = idempotency_request("hard-response-ceiling")
    payload = :binary.copy(<<0xA5>>, 16_777_216)
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :complete, payload: stored}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, payload)
             end)

    assert byte_size(stored) == 16_777_216
  end

  test "load rejects more than one payload row across all partitions", %{
    prefix: prefix,
    target: target
  } do
    request = idempotency_request("load-payload-cardinality")
    payload = "stored"
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :complete, claim: complete}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, payload)
             end)

    insert_payload!(prefix, ~D[2100-01-01], complete.id, "extra")

    assert {:ok, %Result{status: :failure, reason: :corrupt_payload}} =
             Repo.transaction(fn -> Store.load(target, complete) end)
  end

  test "idempotency requests accept only normalized bounded retention seconds" do
    base = [
      operation_hash: hash("retention-operation"),
      scope_hash: hash("retention-scope"),
      key_hash: hash("retention-key"),
      fingerprint: hash("retention-fingerprint")
    ]

    assert {:ok, %Claim.Request{retention_seconds: 2_147_483_647}} =
             Claim.idempotency(Keyword.put(base, :retention_seconds, 2_147_483_647))

    for invalid <- [0, -1, 2_147_483_648, DateTime.utc_now()] do
      assert {:error, :invalid_request} =
               Claim.idempotency(Keyword.put(base, :retention_seconds, invalid))
    end

    assert {:error, :invalid_request} =
             Claim.idempotency(Keyword.put(base, :retain_until, DateTime.utc_now()))
  end

  test "completion rejects a digest mismatch before payload insertion", %{target: target} do
    request = idempotency_request("bad-digest")

    assert {:error,
            %Result{
              status: :failure,
              reason: :invalid_request,
              transaction: :rolled_back
            }} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", hash("other"), "payload")
             end)
  end

  test "every completion failure rolls back claim, guarded effect, and payload", %{
    prefix: prefix,
    target: target
  } do
    create_effect_proof!(prefix)

    failures = [
      {:validation, fn claim -> {claim, "payload", hash("wrong")} end},
      {:payload,
       fn claim ->
         insert_payload!(prefix, Date.utc_today(), claim.id, "existing")
         {claim, "payload", hash("payload")}
       end},
      {:update,
       fn claim ->
         {%{claim | key_hash: hash("different-key")}, "payload", hash("payload")}
       end}
    ]

    for {failure, prepare} <- failures do
      request = idempotency_request("completion-rollback-#{failure}")

      assert {:error, %Result{status: :failure, transaction: :rolled_back}} =
               Repo.transaction(fn ->
                 admitted = Store.claim(target, request)
                 insert_effect!(prefix, Atom.to_string(failure))
                 {claim, payload, digest} = prepare.(admitted.claim)
                 Store.complete(target, claim, "test", digest, payload)
               end)
    end

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
    assert table_count(prefix, "ash_onetime_response_payloads") == 0
    assert table_count(prefix, "ash_onetime_completion_effects") == 0
  end

  test "completion rejects cross-partition payload duplication and rolls the transaction back", %{
    prefix: prefix,
    target: target
  } do
    request = idempotency_request("payload-cardinality")

    assert {:error, %Result{status: :failure, reason: :store_invariant}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               insert_payload!(prefix, ~D[2100-01-01], admitted.claim.id, "extra")
               payload = "authoritative"

               Store.complete(
                 target,
                 admitted.claim,
                 "test",
                 :crypto.hash(:sha256, payload),
                 payload
               )
             end)

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
    assert table_count(prefix, "ash_onetime_response_payloads") == 0
  end

  test "load reports a missing authoritative claim as a store invariant", %{target: target} do
    request = idempotency_request("missing-load")
    parent = self()

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               result = Store.claim(target, request)
               send(parent, {:rolled_back_claim, result.claim})
               Repo.rollback(:forced_rollback)
             end)

    assert_receive {:rolled_back_claim, claim}

    assert {:ok,
            %Result{
              status: :failure,
              reason: :store_invariant,
              admission_dispatch: :sent,
              transaction: :open
            }} = Repo.transaction(fn -> Store.load(target, claim) end)
  end

  test "catalog has separated strategy columns and exact payload columns", %{prefix: prefix} do
    nonce_columns = columns(prefix, "ash_onetime_nonce_claims")
    payload_columns = columns(prefix, "ash_onetime_response_payloads")

    refute "response_partition" in nonce_columns
    refute "response_codec" in nonce_columns
    refute "response_digest" in nonce_columns
    assert payload_columns == ["claim_id", "encoded_response", "partition_date"]
  end

  test "database rejects malformed hashes and invalid response state", %{prefix: prefix} do
    now = DateTime.utc_now()
    future = DateTime.add(now, 60, :second)
    table = relation(prefix, "ash_onetime_idempotency_claims")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{table}
                 (id, operation_hash, scope_hash, key_hash, fingerprint, state,
                  admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4, $5, 'processing', $6, $7, $6)
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 :binary.copy(<<1>>, 31),
                 hash("s"),
                 hash("k"),
                 hash("f"),
                 now,
                 future
               ]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{table}
                 (id, operation_hash, scope_hash, key_hash, fingerprint, state,
                  response_partition, response_codec, response_digest,
                  admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4, $5, 'complete', CURRENT_DATE, 'test', NULL,
                       $6, $7, $6)
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 hash("complete-o"),
                 hash("complete-s"),
                 hash("complete-k"),
                 hash("complete-f"),
                 now,
                 future
               ]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{table}
                 (id, operation_hash, scope_hash, key_hash, fingerprint, state,
                  admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4, $5, 'processing', $6, $7, $6)
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 :binary.copy(<<1>>, 33),
                 hash("s33"),
                 hash("k33"),
                 hash("f33"),
                 now,
                 future
               ]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{table}
                 (id, operation_hash, scope_hash, key_hash, fingerprint, state,
                  response_partition, admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4, $5, 'processing', CURRENT_DATE, $6, $7, $6)
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 hash("o"),
                 hash("s"),
                 hash("k"),
                 hash("f"),
                 now,
                 future
               ]
             )
  end

  test "nonce timestamp order and payload upper bound are database-enforced", %{prefix: prefix} do
    nonce_table = relation(prefix, "ash_onetime_nonce_claims")
    payload_table = relation(prefix, "ash_onetime_response_payloads")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{nonce_table}
                 (id, operation_hash, scope_hash, key_hash, issued_at, expires_at, verifier_id,
                  admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4,
                       transaction_timestamp(), transaction_timestamp() - interval '1 second', 'test',
                       transaction_timestamp(), transaction_timestamp() + interval '1 hour',
                       transaction_timestamp())
               """,
               [Ecto.UUID.dump!(Ecto.UUID.generate()), hash("no"), hash("ns"), hash("nk")]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
             SQL.query(
               Repo,
               "INSERT INTO #{payload_table} (partition_date, claim_id, encoded_response) VALUES (CURRENT_DATE, $1::uuid, NULL)",
               [Ecto.UUID.dump!(Ecto.UUID.generate())]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "INSERT INTO #{payload_table} (partition_date, claim_id, encoded_response) VALUES (CURRENT_DATE, $1::uuid, $2)",
               [Ecto.UUID.dump!(Ecto.UUID.generate()), :binary.copy(<<0>>, 16_777_217)]
             )

    constraint_sql =
      SQL.query!(
        Repo,
        """
        SELECT string_agg(pg_get_constraintdef(constraint_record.oid), ' ')
        FROM pg_constraint constraint_record
        JOIN pg_class table_record ON table_record.oid = constraint_record.conrelid
        JOIN pg_namespace namespace ON namespace.oid = table_record.relnamespace
        WHERE namespace.nspname = $1 AND table_record.relname = 'ash_onetime_response_payloads'
        """,
        [prefix]
      )
      |> then(fn %{rows: [[definition]]} -> definition end)

    assert constraint_sql =~ "octet_length(encoded_response) <= 16777216"
    refute constraint_sql =~ "octet_length(encoded_response) > 0"
  end

  defp columns(prefix, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2
        ORDER BY column_name
        """,
        [prefix, table]
      )

    Enum.map(rows, &hd/1)
  end

  defp create_effect_proof!(prefix) do
    SQL.query!(
      Repo,
      "CREATE TABLE IF NOT EXISTS #{relation(prefix, "ash_onetime_completion_effects")} (label text NOT NULL)",
      []
    )
  end

  defp insert_effect!(prefix, label) do
    SQL.query!(
      Repo,
      "INSERT INTO #{relation(prefix, "ash_onetime_completion_effects")} (label) VALUES ($1)",
      [label]
    )
  end

  defp insert_payload!(prefix, date, id, payload) do
    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_response_payloads")}
        (partition_date, claim_id, encoded_response)
      VALUES ($1, $2::uuid, $3)
      """,
      [date, Ecto.UUID.dump!(id), payload]
    )
  end

  defp table_count(prefix, table) do
    %{rows: [[count]]} = SQL.query!(Repo, "SELECT count(*) FROM #{relation(prefix, table)}", [])
    count
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
