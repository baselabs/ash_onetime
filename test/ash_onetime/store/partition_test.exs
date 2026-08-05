defmodule AshOnetime.Store.PartitionTest do
  use AshOnetime.Test.StoreCase, async: false

  @moduletag :store

  setup_all do
    installation = install_store!(claims: :hash, partitions: 4)
    {:ok, prefix: installation.schema}
  end

  test "hash parents use PostgreSQL-compatible primary keys", %{prefix: prefix} do
    for table <- ["ash_onetime_idempotency_claims", "ash_onetime_nonce_claims"] do
      assert constraint_columns(prefix, table, "p") == ["operation_hash", "id"]

      assert constraint_columns(prefix, table, "u") == [
               "operation_hash",
               "scope_hash",
               "key_hash"
             ]
    end
  end

  @tag unique_constraint_mutation: true
  test "logical uniqueness rejects idempotency and nonce duplicates in every hash child", %{
    prefix: prefix,
    target: target
  } do
    for {strategy, table, collision_status} <- [
          {:idempotency, "ash_onetime_idempotency_claims", :processing},
          {:nonce, "ash_onetime_nonce_claims", :collision}
        ] do
      children = partition_children(prefix, table)
      assert length(children) == 4

      requests = requests_by_child(prefix, target, table, strategy, children)
      assert Map.keys(requests) |> Enum.sort() == Enum.sort(children)

      for {child, request} <- requests do
        duplicate = %{request | id: Ecto.UUID.generate()}

        assert %Result{status: ^collision_status, claim: claim} =
                 Repo.transaction(fn -> Store.claim(target, duplicate) end) |> elem(1)

        assert routed_child(prefix, table, request.operation_hash, request.id) == child
        assert claim.operation_hash == request.operation_hash
      end
    end
  end

  test "range and default payload partitions both accept zero-byte payloads", %{prefix: prefix} do
    current_id = Ecto.UUID.generate()
    default_id = Ecto.UUID.generate()

    insert_payload(prefix, Date.utc_today(), current_id, <<>>)
    insert_payload(prefix, ~D[2100-01-01], default_id, <<>>)

    assert payload_partition(prefix, current_id) =~ "ash_onetime_response_payloads_"
    refute payload_partition(prefix, current_id) =~ "_default"
    assert payload_partition(prefix, default_id) =~ "ash_onetime_response_payloads_default"
  end

  @tag cleanup_boundary_mutation: true
  test "every idempotency and nonce hash child trigger is strict at and after the horizon", %{
    prefix: prefix
  } do
    for {strategy, table, trigger} <- [
          {:idempotency, "ash_onetime_idempotency_claims",
           "ash_onetime_idempotency_delete_guard"},
          {:nonce, "ash_onetime_nonce_claims", "ash_onetime_nonce_delete_guard"}
        ] do
      children = partition_children(prefix, table)
      assert Enum.all?(children, &(&1 in triggered_tables(prefix, trigger)))

      claims = boundary_claims_by_child(prefix, table, strategy, children)
      assert Map.keys(claims) |> Enum.sort() == Enum.sort(children)

      for {child, {id, operation_hash}} <- claims do
        assert routed_child(prefix, table, operation_hash, id) == child
        assert_guarded_delete(prefix, table, operation_hash, id)
        expire_claim!(prefix, table, operation_hash, id)

        case strategy do
          :idempotency -> assert_guarded_delete(prefix, table, operation_hash, id)
          :nonce -> assert %{num_rows: 1} = delete_claim!(prefix, table, operation_hash, id)
        end
      end
    end
  end

  @tag operation_hash_completion_mutation: true
  test "completion update keeps operation identity when hash partitions share an id", %{
    target: target
  } do
    shared_id = Ecto.UUID.generate()
    base = idempotency_request("completion-operation-a")

    request_a = %{base | id: shared_id, operation_hash: hash("completion-operation-a")}

    request_b = %{
      base
      | id: shared_id,
        operation_hash: hash("completion-operation-b"),
        fingerprint: hash("completion-fingerprint-b")
    }

    payload = "operation-a-response"
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :complete, claim: complete}} =
             Repo.transaction(fn ->
               claim_a = Store.claim(target, request_a).claim
               _claim_b = Store.claim(target, request_b).claim
               Store.complete(target, claim_a, "test", digest, payload)
             end)

    assert complete.operation_hash == request_a.operation_hash

    assert {:ok, %Result{status: :processing, claim: pending_b}} =
             Repo.transaction(fn -> Store.claim(target, request_b) end)

    assert pending_b.operation_hash == request_b.operation_hash
  end

  @tag operation_hash_cleanup_mutation: true
  test "cleanup delete keeps operation identity when hash partitions share an id", %{
    prefix: prefix,
    target: target
  } do
    shared_id = Ecto.UUID.generate()
    partition_date = Date.utc_today()
    payload = "shared-cleanup-response"

    for operation <- ["cleanup-operation-a", "cleanup-operation-b"] do
      insert_complete_claim!(
        prefix,
        shared_id,
        hash(operation),
        hash("cleanup-scope"),
        hash("cleanup-key"),
        hash("fingerprint:" <> operation),
        partition_date,
        payload
      )
    end

    insert_payload(prefix, partition_date, shared_id, payload)

    assert {:ok, %{idempotency: 1, nonce: 0}} = Store.cleanup(target, 1)

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
               [Ecto.UUID.dump!(shared_id)]
             )
  end

  test "a completed claim replays a zero-byte payload from DEFAULT", %{
    prefix: prefix,
    target: target
  } do
    request = idempotency_request("default-replay")
    claim_id = Ecto.UUID.generate()
    partition_date = ~D[2100-01-01]
    digest = :crypto.hash(:sha256, <<>>)

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         response_partition, response_codec, response_digest,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'complete', $6, 'test', $7,
              transaction_timestamp(), transaction_timestamp() + interval '1 hour',
              transaction_timestamp())
      """,
      [
        Ecto.UUID.dump!(claim_id),
        request.operation_hash,
        request.scope_hash,
        request.key_hash,
        request.fingerprint,
        partition_date,
        digest
      ]
    )

    insert_payload(prefix, partition_date, claim_id, <<>>)

    assert {:ok, %Result{status: :complete, payload: <<>>, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert claim.id == claim_id
    assert payload_partition(prefix, claim_id) =~ "ash_onetime_response_payloads_default"
  end

  defp requests_by_child(prefix, target, table, strategy, expected_children) do
    Enum.reduce_while(1..2_000, %{}, fn index, found ->
      request =
        case strategy do
          :idempotency -> idempotency_request("partition-idempotency-route-#{index}")
          :nonce -> nonce_request("partition-nonce-route-#{index}")
        end

      assert %Result{status: :admitted} =
               Repo.transaction(fn -> Store.claim(target, request) end) |> elem(1)

      child = routed_child(prefix, table, request.operation_hash, request.id)
      found = Map.put_new(found, child, request)

      if map_size(found) == length(expected_children), do: {:halt, found}, else: {:cont, found}
    end)
  end

  defp routed_child(prefix, table, operation_hash, id) do
    %{rows: [[name]]} =
      SQL.query!(
        Repo,
        """
        SELECT tableoid::regclass::text
        FROM #{relation(prefix, table)}
        WHERE operation_hash = $1 AND id = $2::uuid
        LIMIT 1
        """,
        [operation_hash, Ecto.UUID.dump!(id)]
      )

    name |> String.split(".") |> List.last()
  end

  defp partition_children(prefix, parent) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT child.relname
        FROM pg_inherits inheritance
        JOIN pg_class parent ON parent.oid = inheritance.inhparent
        JOIN pg_namespace namespace ON namespace.oid = parent.relnamespace
        JOIN pg_class child ON child.oid = inheritance.inhrelid
        WHERE namespace.nspname = $1 AND parent.relname = $2
        ORDER BY child.relname
        """,
        [prefix, parent]
      )

    Enum.map(rows, &hd/1)
  end

  defp constraint_columns(prefix, table, type) do
    %{rows: [[columns]]} =
      SQL.query!(
        Repo,
        """
        SELECT array_agg(attribute.attname ORDER BY key.ordinality)
        FROM pg_constraint constraint_record
        JOIN pg_class table_record ON table_record.oid = constraint_record.conrelid
        JOIN pg_namespace namespace ON namespace.oid = table_record.relnamespace
        JOIN unnest(constraint_record.conkey) WITH ORDINALITY AS key(attnum, ordinality) ON true
        JOIN pg_attribute attribute
          ON attribute.attrelid = table_record.oid AND attribute.attnum = key.attnum
        WHERE namespace.nspname = $1 AND table_record.relname = $2
          AND constraint_record.contype = $3::"char"
        GROUP BY constraint_record.oid
        """,
        [prefix, table, type]
      )

    columns
  end

  defp boundary_claims_by_child(prefix, table, strategy, expected_children) do
    Enum.reduce_while(1..2_000, %{}, fn index, found ->
      id = Ecto.UUID.generate()
      operation_hash = hash("boundary-operation:#{strategy}:#{index}")

      case strategy do
        :idempotency ->
          insert_processing_claim!(
            prefix,
            id,
            operation_hash,
            hash("boundary-scope:#{strategy}:#{index}"),
            hash("boundary-key:#{strategy}:#{index}"),
            hash("boundary-fingerprint:#{index}"),
            :equal
          )

        :nonce ->
          insert_nonce_claim!(
            prefix,
            id,
            operation_hash,
            hash("boundary-scope:#{strategy}:#{index}"),
            hash("boundary-key:#{strategy}:#{index}"),
            :equal
          )
      end

      child = routed_child(prefix, table, operation_hash, id)
      found = Map.put_new(found, child, {id, operation_hash})

      if map_size(found) == length(expected_children), do: {:halt, found}, else: {:cont, found}
    end)
  end

  defp insert_processing_claim!(
         prefix,
         id,
         operation_hash,
         scope_hash,
         key_hash,
         fingerprint,
         boundary
       ) do
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
      [Ecto.UUID.dump!(id), operation_hash, scope_hash, key_hash, fingerprint]
    )
  end

  defp insert_complete_claim!(
         prefix,
         id,
         operation_hash,
         scope_hash,
         key_hash,
         fingerprint,
         partition_date,
         payload
       ) do
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
        Ecto.UUID.dump!(id),
        operation_hash,
        scope_hash,
        key_hash,
        fingerprint,
        partition_date,
        digest
      ]
    )
  end

  defp insert_nonce_claim!(prefix, id, operation_hash, scope_hash, key_hash, boundary) do
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
      [Ecto.UUID.dump!(id), operation_hash, scope_hash, key_hash]
    )
  end

  defp triggered_tables(prefix, trigger_name) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT c.relname
        FROM pg_trigger trigger
        JOIN pg_class c ON c.oid = trigger.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND trigger.tgname = $2 AND NOT trigger.tgisinternal
        ORDER BY c.relname
        """,
        [prefix, trigger_name]
      )

    Enum.map(rows, &hd/1)
  end

  defp assert_guarded_delete(prefix, table, operation_hash, id) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.transaction(fn ->
               case delete_claim(prefix, table, operation_hash, id) do
                 {:error, error} -> Repo.rollback(error)
                 result -> result
               end
             end)
  end

  defp expire_claim!(prefix, table, operation_hash, id) do
    SQL.query!(
      Repo,
      """
      UPDATE #{relation(prefix, table)}
      SET retain_until = transaction_timestamp() - interval '1 microsecond'
      WHERE operation_hash = $1 AND id = $2::uuid
      """,
      [operation_hash, Ecto.UUID.dump!(id)]
    )
  end

  defp delete_claim!(prefix, table, operation_hash, id) do
    {:ok, result} = delete_claim(prefix, table, operation_hash, id)
    result
  end

  defp delete_claim(prefix, table, operation_hash, id) do
    SQL.query(
      Repo,
      "DELETE FROM #{relation(prefix, table)} WHERE operation_hash = $1 AND id = $2::uuid",
      [operation_hash, Ecto.UUID.dump!(id)]
    )
  end

  defp boundary_expression(:equal), do: "transaction_timestamp()"
  defp boundary_expression(:after), do: "transaction_timestamp() - interval '1 microsecond'"

  defp insert_payload(prefix, date, id, payload) do
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

  defp payload_partition(prefix, id) do
    %{rows: [[name]]} =
      SQL.query!(
        Repo,
        """
        SELECT tableoid::regclass::text
        FROM #{relation(prefix, "ash_onetime_response_payloads")}
        WHERE claim_id = $1::uuid
        """,
        [Ecto.UUID.dump!(id)]
      )

    name
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
