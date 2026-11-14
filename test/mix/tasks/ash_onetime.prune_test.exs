defmodule Mix.Tasks.AshOnetime.PruneTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.ExternalPeer
  alias Mix.Tasks.AshOnetime.Prune

  @moduletag :store
  @moduletag :payload_partition_mutation

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  @tag unboxed: true
  test "manual cleanup retains the exact database-date boundary and drops only older empty partitions",
       %{prefix: prefix, target: target} do
    today = database_date()
    eligible_to = Date.add(today, -1)
    eligible_from = Date.add(today, -2)
    exact_from = Date.add(today, -1)

    detach_generated_partitions(prefix, today, ["eligible", "exact"])
    create_partition(prefix, "eligible", eligible_from, eligible_to)
    create_partition(prefix, "exact", exact_from, today)

    assert {:ok, %{idempotency: 0, nonce: 0, payload_partitions: 1}} =
             Store.cleanup(target, 100, 10)

    refute partition_exists?(prefix, "eligible")
    assert partition_exists?(prefix, "exact")
  end

  @tag unboxed: true
  test "cleanup never drops a partition that still contains a live payload", %{
    prefix: prefix,
    target: target
  } do
    today = database_date()
    from = Date.add(today, -4)
    until_date = Date.add(today, -3)
    detach_generated_partitions(prefix, today, ["live"])
    create_partition(prefix, "live", from, until_date)
    insert_live_complete(prefix, from)

    assert {:ok, %{idempotency: 0, nonce: 0, payload_partitions: 0}} =
             Store.cleanup(target, 100, 10)

    assert partition_exists?(prefix, "live")
  end

  @tag unboxed: true
  @tag payload_partition_lock_mutation: true
  test "a child held by a direct reader is skipped without waiting and its sibling still drops",
       %{prefix: prefix, target: target} do
    baseline_started = System.monotonic_time(:millisecond)
    assert {:ok, _} = Store.cleanup(target, 100, 10)
    baseline_elapsed = System.monotonic_time(:millisecond) - baseline_started
    today = database_date()
    detach_generated_partitions(prefix, today, ["held", "sibling"])
    create_partition(prefix, "held", Date.add(today, -8), Date.add(today, -7))
    create_partition(prefix, "sibling", Date.add(today, -6), Date.add(today, -5))

    # The child lock is requested while the parent ACCESS EXCLUSIVE is held, so
    # any wait would stall every tenant: a child-only holder must be skipped.
    holder = connection!()
    relation = relation(prefix, "ash_onetime_response_payloads_held")
    Postgrex.query!(holder, "BEGIN", [])
    Postgrex.query!(holder, "SELECT 1 FROM #{relation}", [])

    started = System.monotonic_time(:millisecond)
    result = Store.cleanup(target, 100, 10)
    elapsed = System.monotonic_time(:millisecond) - started

    assert {:ok, %{payload_partitions: 1, payload_partitions_refused: %{lock_unavailable: 1}}} =
             result

    assert elapsed < baseline_elapsed + 1_000
    assert partition_exists?(prefix, "held")
    refute partition_exists?(prefix, "sibling")

    # The holder then reaches the parent and commits: no lock cycle remains.
    Postgrex.query!(
      holder,
      "SELECT 1 FROM #{relation(prefix, "ash_onetime_response_payloads")} LIMIT 1",
      []
    )

    Postgrex.query!(holder, "COMMIT", [])
  end

  test "Mix task validates inputs and invokes bounded pruning", %{prefix: prefix} do
    Mix.Task.reenable("ash_onetime.prune")

    assert :ok =
             Prune.run([
               "--repo",
               inspect(Repo),
               "--prefix",
               prefix,
               "--batch-size",
               "20",
               "--partition-limit",
               "2"
             ])

    Mix.Task.reenable("ash_onetime.prune")
    assert_raise Mix.Error, ~r/--repo is required/, fn -> Prune.run([]) end
  end

  defp database_date do
    %{rows: [[date]]} = SQL.query!(Repo, "SELECT current_date", [])
    date
  end

  defp detach_generated_partitions(prefix, today, temporary_suffixes) do
    current = detach_current_month(prefix, today)

    on_exit(fn ->
      {:ok, connection} =
        Postgrex.start_link(
          ExternalPeer.database_options(System.get_env("ASH_ONETIME_EXPECTED_TEST_DATABASE"))
        )

      Process.unlink(connection)

      try do
        Enum.each(temporary_suffixes, fn suffix ->
          Postgrex.query!(
            connection,
            "DROP TABLE IF EXISTS #{relation(prefix, "ash_onetime_response_payloads_#{suffix}")}",
            []
          )
        end)

        Postgrex.query!(
          connection,
          "ALTER TABLE #{relation(prefix, "ash_onetime_response_payloads")} ATTACH PARTITION #{relation(prefix, current.name)} FOR VALUES FROM ('#{current.from}') TO ('#{current.until_date}')",
          []
        )
      after
        GenServer.stop(connection, :normal, 5_000)
      end
    end)
  end

  defp detach_current_month(prefix, today) do
    suffix = "#{today.year}_#{today.month |> Integer.to_string() |> String.pad_leading(2, "0")}"
    name = "ash_onetime_response_payloads_#{suffix}"

    SQL.query!(
      Repo,
      "ALTER TABLE #{relation(prefix, "ash_onetime_response_payloads")} DETACH PARTITION #{relation(prefix, name)}",
      []
    )

    from = Date.beginning_of_month(today)
    month_index = from.year * 12 + from.month
    until_date = Date.new!(div(month_index, 12), rem(month_index, 12) + 1, 1)
    %{name: name, from: from, until_date: until_date}
  end

  defp create_partition(prefix, suffix, from, until_date) do
    SQL.query!(
      Repo,
      "CREATE TABLE #{relation(prefix, "ash_onetime_response_payloads_#{suffix}")} PARTITION OF #{relation(prefix, "ash_onetime_response_payloads")} FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(until_date)}')",
      []
    )

    SQL.query!(
      Repo,
      "SELECT #{relation(Postgres.routine_schema(prefix), "ash_onetime_maintenance_copy_policy")}($1::text::regclass::oid)",
      [relation(prefix, "ash_onetime_response_payloads_#{suffix}")]
    )

    SQL.query!(
      Repo,
      "SELECT #{relation(Postgres.routine_schema(prefix), "ash_onetime_maintenance_reset_acl")}($1::text::regclass::oid,true)",
      [relation(prefix, "ash_onetime_response_payloads_#{suffix}")]
    )
  end

  defp partition_exists?(prefix, suffix) do
    %{rows: [[exists?]]} =
      SQL.query!(
        Repo,
        "SELECT to_regclass($1) IS NOT NULL",
        ["#{prefix}.ash_onetime_response_payloads_#{suffix}"]
      )

    exists?
  end

  defp insert_live_complete(prefix, partition_date) do
    id = Ecto.UUID.generate()
    payload = "live"

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state, response_partition,
         response_codec, response_digest, admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'complete', $6, 'test', $7,
              transaction_timestamp(), transaction_timestamp() + interval '1 hour',
              transaction_timestamp())
      """,
      [
        Ecto.UUID.dump!(id),
        hash("operation:" <> id),
        hash("scope:" <> id),
        hash("key:" <> id),
        hash("fingerprint:" <> id),
        partition_date,
        :crypto.hash(:sha256, payload)
      ]
    )

    SQL.query!(
      Repo,
      "INSERT INTO #{relation(prefix, "ash_onetime_response_payloads")} (partition_date, claim_id, encoded_response) VALUES ($1, $2::uuid, $3)",
      [partition_date, Ecto.UUID.dump!(id), payload]
    )

    on_exit(fn ->
      {:ok, connection} =
        Postgrex.start_link(
          ExternalPeer.database_options(System.get_env("ASH_ONETIME_EXPECTED_TEST_DATABASE"))
        )

      Process.unlink(connection)

      try do
        Postgrex.query!(
          connection,
          "UPDATE #{relation(prefix, "ash_onetime_idempotency_claims")} SET admitted_at=now()-interval '2 hours', inserted_at=now()-interval '2 hours', retain_until=now()-interval '1 hour' WHERE id=$1::uuid",
          [Ecto.UUID.dump!(id)]
        )

        Postgrex.query!(
          connection,
          "DELETE FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
          [Ecto.UUID.dump!(id)]
        )
      after
        GenServer.stop(connection, :normal, 5_000)
      end
    end)
  end

  defp connection! do
    {:ok, connection} =
      Postgrex.start_link(
        ExternalPeer.database_options(System.get_env("ASH_ONETIME_EXPECTED_TEST_DATABASE"))
      )

    Process.unlink(connection)

    on_exit(fn ->
      if Process.alive?(connection), do: GenServer.stop(connection, :normal, 5_000)
    end)

    connection
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
