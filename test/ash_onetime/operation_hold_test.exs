defmodule AshOnetime.OperationHoldTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.{Error, Transaction}
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "complete/3 atomically places a hold and an expired held claim still replays", ctx do
    id = complete!(ctx.prefix, "replay")
    expire!(ctx.prefix, id)
    assert row(ctx.prefix, id) |> hd() == "operation"

    assert {:ok, {:replay, "response"}} =
             Repo.transaction(fn ->
               Transaction.idempotency(Repo, options(ctx.prefix, "replay"))
             end)
  end

  @tag :hold_cleanup_mutation
  test "cleanup excludes held rows before the guard; the guard is not invoked", ctx do
    id = complete!(ctx.prefix, "cleanup")
    expire!(ctx.prefix, id)
    assert {:ok, %{idempotency: 0}} = Store.cleanup(ctx.target, 100)
    assert row(ctx.prefix, id) != [], "cleanup must leave the held row without asking the guard"
  end

  test "reap never selects complete rows; the held-row guard is not invoked", ctx do
    id = complete!(ctx.prefix, "reap")
    expire!(ctx.prefix, id)
    assert {:ok, 0} = Store.reap(ctx.target, 100, 86_400)
    assert row(ctx.prefix, id) != [], "reap selects processing rows only"
  end

  @tag :hold_guard_mutation
  test "the delete guard stops a direct DELETE by the table owner before retention checks", ctx do
    id = complete!(ctx.prefix, "owner-delete")

    assert {:error,
            %Postgrex.Error{postgres: %{code: :check_violation, message: initial_message}}} =
             SQL.query(Repo, "DELETE FROM #{claims(ctx.prefix)} WHERE id = $1", [uuid(id)],
               mode: :savepoint
             )

    assert initial_message =~ "held idempotency claim"
    expire!(ctx.prefix, id)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, message: message}}} =
             SQL.query(Repo, "DELETE FROM #{claims(ctx.prefix)} WHERE id = $1", [uuid(id)],
               mode: :savepoint
             )

    assert message =~ "held idempotency claim"
    assert row(ctx.prefix, id) != [], "the guard must stop the owner's DELETE"
  end

  test "roll-forward DEFAULT drain excludes held rows; the guard is not invoked", ctx do
    id = complete!(ctx.prefix, "drain")
    expire!(ctx.prefix, id)

    SQL.query!(
      Repo,
      "UPDATE #{payloads(ctx.prefix)} SET partition_date = '2100-01-01' WHERE claim_id = $1",
      [uuid(id)]
    )

    SQL.query!(
      Repo,
      "UPDATE #{claims(ctx.prefix)} SET response_partition = '2100-01-01' WHERE id = $1",
      [uuid(id)]
    )

    source =
      Generator.render_roll_forward(Repo,
        partition_start: Date.beginning_of_month(Date.utc_today()),
        months: 1
      )

    # Execute the actual rendered migration, substituting only its Ecto command runner.
    source =
      source
      |> String.replace(
        "use Ecto.Migration",
        "def prefix, do: Process.get({__MODULE__, :prefix}, #{inspect(ctx.prefix)})\n def repo, do: AshOnetime.Test.Repo\n def execute(sql), do: Ecto.Adapters.SQL.query!(AshOnetime.Test.Repo, sql, [])"
      )

    module = Module.concat(__MODULE__, "Drain")

    source =
      String.replace(
        source,
        inspect(Repo) <> ".Migrations.RollForwardAshOnetime",
        inspect(module)
      )

    Code.compile_string(source)

    try do
      module.up()
      assert row(ctx.prefix, id) != [], "the drain must not invoke the held-row guard"
    after
      :code.purge(module)
      :code.delete(module)
    end
  end

  test "release restarts the full retention window, and cleanup later removes the claim", ctx do
    id = complete!(ctx.prefix, "release")
    expire!(ctx.prefix, id)

    assert {:ok, deadline} =
             Repo.transaction(fn ->
               before_release =
                 SQL.query!(Repo, "SELECT statement_timestamp()", []).rows |> hd() |> hd()

               assert {:ok, 1} =
                        Transaction.release(Repo,
                          prefix: ctx.prefix,
                          partition: "global",
                          reference: "operation"
                        )

               assert [nil, deadline] = row(ctx.prefix, id)

               after_release =
                 SQL.query!(Repo, "SELECT statement_timestamp()", []).rows |> hd() |> hd()

               assert DateTime.compare(deadline, DateTime.add(before_release, 86_400)) != :lt
               assert DateTime.compare(deadline, DateTime.add(after_release, 86_400)) != :gt
               deadline
             end)

    assert %DateTime{} = deadline
    assert {:ok, %{idempotency: 0}} = Store.cleanup(ctx.target, 100)
    expire!(ctx.prefix, id)
    assert {:ok, %{idempotency: 1}} = Store.cleanup(ctx.target, 100)
    assert row(ctx.prefix, id) == []
  end

  test "hold reference bounds count UTF-8 bytes and accept exactly 255 bytes", ctx do
    reference = String.duplicate("é", 127) <> "x"
    assert byte_size(reference) == 255
    id = complete!(ctx.prefix, "utf8", "global", reference)
    assert [^reference, _deadline] = row(ctx.prefix, id)
    assert {:ok, {:ok, 1}} = release(ctx.prefix, reference)
  end

  test "release never shortens an existing deadline", ctx do
    id = complete!(ctx.prefix, "future-admission")

    SQL.query!(
      Repo,
      "UPDATE #{claims(ctx.prefix)} SET admitted_at = statement_timestamp() + interval '1 hour', inserted_at = statement_timestamp() + interval '1 hour', retain_until = statement_timestamp() + interval '2 hours' WHERE id = $1",
      [uuid(id)]
    )

    assert ["operation", deadline] = row(ctx.prefix, id)
    assert {:ok, {:ok, 1}} = release(ctx.prefix)
    assert [nil, ^deadline] = row(ctx.prefix, id)
  end

  test "release rollback preserves the hold; unknown references release zero", ctx do
    id = complete!(ctx.prefix, "rollback")

    assert {:error, :settle_failed} =
             Repo.transaction(fn ->
               assert {:ok, 1} =
                        Transaction.release(Repo,
                          prefix: ctx.prefix,
                          partition: "global",
                          reference: "operation"
                        )

               Repo.rollback(:settle_failed)
             end)

    assert ["operation", _] = row(ctx.prefix, id)
    assert {:ok, {:ok, 0}} = release(ctx.prefix, "unknown")
  end

  test "release addresses all claims with a reference in exactly one logical partition", ctx do
    ids = for key <- ["first", "second"], do: complete!(ctx.prefix, key)
    other = complete!(ctx.prefix, "other", "other-partition")
    assert {:ok, {:ok, 2}} = release(ctx.prefix)
    for id <- ids, do: assert([nil, _] = row(ctx.prefix, id))
    assert ["operation", _] = row(ctx.prefix, other)
  end

  test "hold placement and release reject malformed references and exact-option violations",
       ctx do
    for ref <- [nil, "", <<255>>, <<0>>, String.duplicate("x", 256), :invalid, 123] do
      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 assert {:execute, admission} =
                          Transaction.idempotency(Repo, options(ctx.prefix, inspect(ref)))

                 assert {:error, %Error{code: :invalid_request}} =
                          Transaction.complete(admission, "response", hold: ref)

                 assert {:error, %Error{code: :invalid_request}} =
                          Transaction.release(Repo,
                            prefix: ctx.prefix,
                            partition: "global",
                            reference: ref
                          )

                 :ok
               end)
    end

    assert {:error, %Error{code: :invalid_request}} =
             Transaction.release(Repo, partition: "global", reference: "x", extra: true)

    assert {:error, %Error{code: :invalid_request}} =
             Transaction.release(Repo, partition: "global", reference: "x", reference: "y")
  end

  @tag unboxed: true
  test "release requires a caller-owned READ COMMITTED transaction", ctx do
    assert {:error, %Error{code: :not_in_transaction}} =
             Transaction.release(Repo,
               prefix: ctx.prefix,
               partition: "global",
               reference: "operation"
             )

    assert {:ok, {:error, %Error{code: :unsupported_isolation}}} =
             Repo.transaction(fn ->
               SQL.query!(Repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])

               Transaction.release(Repo,
                 prefix: ctx.prefix,
                 partition: "global",
                 reference: "operation"
               )
             end)
  end

  test "external completion writes the hold in its completing transaction", ctx do
    request = idempotency_request("external")

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert %Result{claim: claim} = Store.claim(ctx.target, request)

               assert %Result{status: :complete, claim: %{hold_reference: "external-operation"}} =
                        Postgres.complete_external(
                          ctx.target,
                          claim,
                          "test",
                          hash("response"),
                          "response",
                          "external-operation"
                        )

               :ok
             end)
  end

  test "CHECK refuses a hold on a processing row", ctx do
    assert {:ok, {:execute, admission}} =
             Repo.transaction(fn ->
               Transaction.idempotency(Repo, options(ctx.prefix, "processing"))
             end)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "UPDATE #{claims(ctx.prefix)} SET hold_reference = 'operation' WHERE id = $1",
               [uuid(Transaction.claim_id(admission))],
               mode: :savepoint
             )
  end

  test "held_backlog reports the held count and oldest admission age", ctx do
    assert {:ok, %{held_count: 0, oldest_age_seconds: nil}} = Store.held_backlog(ctx.target)
    id = complete!(ctx.prefix, "oldest")
    expire!(ctx.prefix, id)
    complete!(ctx.prefix, "newer")
    assert {:ok, %{held_count: 2, oldest_age_seconds: age}} = Store.held_backlog(ctx.target)
    assert age in 172_799..172_830
  end

  test "EXPLAIN uses the partial cleanup, release, and processing indexes", ctx do
    SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])

    for {query, index} <- [
          {"SELECT logical_partition, operation_hash, id FROM #{claims(ctx.prefix)} WHERE state = 'complete' AND hold_reference IS NULL AND \"#{ctx.prefix}\".ash_onetime_cleanup_eligible(retain_until) ORDER BY retain_until, logical_partition, operation_hash, id FOR UPDATE SKIP LOCKED LIMIT 100",
           "ash_onetime_idempotency_claims_cleanup_index"},
          {"UPDATE #{claims(ctx.prefix)} SET hold_reference = NULL WHERE logical_partition = 'global' AND hold_reference = 'operation'",
           "ash_onetime_idempotency_claims_hold_index"},
          {"SELECT logical_partition, operation_hash, id FROM #{claims(ctx.prefix)} WHERE state = 'processing' AND inserted_at < now() - interval '1 day' AND \"#{ctx.prefix}\".ash_onetime_cleanup_eligible(retain_until) ORDER BY inserted_at, logical_partition, operation_hash, id FOR UPDATE SKIP LOCKED LIMIT 100",
           "ash_onetime_idempotency_claims_processing_index"}
        ] do
      %{rows: plan} = SQL.query!(Repo, "EXPLAIN " <> query, [])
      assert inspect(plan) =~ index
    end

    assert %{rows: [[false]]} =
             SQL.query!(Repo, "SELECT to_regclass($1) IS NOT NULL", [
               ctx.prefix <> ".ash_onetime_idempotency_claims_retain_until_index"
             ])
  end

  test "prune keeps an old payload month while a held row references it", ctx do
    SQL.query!(
      Repo,
      "CREATE TABLE #{~s("#{ctx.prefix}"."ash_onetime_response_payloads_2001_01")} PARTITION OF #{payloads(ctx.prefix)} FOR VALUES FROM ('2001-01-01') TO ('2001-02-01')",
      []
    )

    id = complete!(ctx.prefix, "prune")
    expire!(ctx.prefix, id)

    SQL.query!(
      Repo,
      "UPDATE #{payloads(ctx.prefix)} SET partition_date = '2001-01-01' WHERE claim_id = $1",
      [uuid(id)]
    )

    SQL.query!(
      Repo,
      "UPDATE #{claims(ctx.prefix)} SET response_partition = '2001-01-01' WHERE id = $1",
      [uuid(id)]
    )

    assert {:ok, %{payload_partitions: 0, payload_partitions_kept: kept}} =
             Store.cleanup(ctx.target, 100, 100)

    assert kept >= 1

    assert %{rows: [[true]]} =
             SQL.query!(Repo, "SELECT to_regclass($1) IS NOT NULL", [
               ctx.prefix <> ".ash_onetime_response_payloads_2001_01"
             ])
  end

  defp complete!(prefix, key, partition \\ "global", reference \\ "operation") do
    {:ok, id} =
      Repo.transaction(fn ->
        assert {:execute, admission} =
                 Transaction.idempotency(
                   Repo,
                   Keyword.put(options(prefix, key), :partition, partition)
                 )

        assert :ok = Transaction.complete(admission, "response", hold: reference)
        Transaction.claim_id(admission)
      end)

    id
  end

  defp options(prefix, key),
    do: [
      operation: {__MODULE__, :open},
      prefix: prefix,
      partition: "global",
      scope: "scope",
      key: key,
      fingerprint: hash("request"),
      retention_seconds: 86_400,
      codec: "test"
    ]

  defp release(prefix, reference \\ "operation"),
    do:
      Repo.transaction(fn ->
        Transaction.release(Repo, prefix: prefix, partition: "global", reference: reference)
      end)

  defp expire!(prefix, id),
    do:
      SQL.query!(
        Repo,
        "UPDATE #{claims(prefix)} SET admitted_at = transaction_timestamp() - interval '2 days', inserted_at = transaction_timestamp() - interval '2 days', retain_until = transaction_timestamp() - interval '1 day' WHERE id = $1",
        [uuid(id)]
      )

  defp row(prefix, id) do
    case SQL.query!(
           Repo,
           "SELECT hold_reference, retain_until FROM #{claims(prefix)} WHERE id = $1",
           [uuid(id)]
         ).rows do
      [row] -> row
      [] -> []
    end
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
  defp claims(prefix), do: ~s("#{prefix}"."ash_onetime_idempotency_claims")
  defp payloads(prefix), do: ~s("#{prefix}"."ash_onetime_response_payloads")
end
