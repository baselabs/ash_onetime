defmodule Mix.Tasks.AshOnetime.PruneTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.RealConnection
  alias Mix.Tasks.AshOnetime.Prune

  @moduletag :store
  @moduletag :payload_partition_mutation
  @database_options [
    hostname: "127.0.0.1",
    port: 18_841,
    username: "postgres",
    password: "postgres",
    database: System.get_env("ASH_ONETIME_EXPECTED_TEST_DATABASE", "ash_onetime_test")
  ]

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
  test "cleanup locks an empty partition before deciding to drop it", %{
    prefix: prefix,
    target: target
  } do
    today = database_date()
    from = Date.add(today, -6)
    until_date = Date.add(today, -5)
    detach_generated_partitions(prefix, today, ["race"])
    create_partition(prefix, "race", from, until_date)

    holder = connection!()
    observer = connection!()
    relation = relation(prefix, "ash_onetime_response_payloads_race")
    Postgrex.query!(holder, "BEGIN", [])
    Postgrex.query!(holder, "LOCK TABLE #{relation} IN ROW EXCLUSIVE MODE", [])

    parent = self()

    worker =
      spawn(fn ->
        result = RealConnection.with_connection(fn -> Store.cleanup(target, 100, 10) end)
        send(parent, {:prune_done, self(), result})
      end)

    assert waiting_partition_prune(observer, prefix)
    insert_live_complete(holder, prefix, from)
    Postgrex.query!(holder, "COMMIT", [])

    assert_receive {:prune_done, ^worker,
                    {:ok, %{idempotency: 0, nonce: 0, payload_partitions: 0}}},
                   2_000

    assert partition_exists?(prefix, "race")
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
    detach_default(prefix)
    current = detach_current_month(prefix, today)

    on_exit(fn ->
      {:ok, connection} = Postgrex.start_link(@database_options)
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

        Postgrex.query!(
          connection,
          "ALTER TABLE #{relation(prefix, "ash_onetime_response_payloads")} ATTACH PARTITION #{relation(prefix, "ash_onetime_response_payloads_default")} DEFAULT",
          []
        )
      after
        GenServer.stop(connection, :normal, 5_000)
      end
    end)
  end

  defp detach_default(prefix) do
    SQL.query!(
      Repo,
      "ALTER TABLE #{relation(prefix, "ash_onetime_response_payloads")} DETACH PARTITION #{relation(prefix, "ash_onetime_response_payloads_default")}",
      []
    )
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
  end

  defp insert_live_complete(connection, prefix, partition_date) do
    id = Ecto.UUID.generate()
    payload = "concurrent-live"

    Postgrex.query!(
      connection,
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

    Postgrex.query!(
      connection,
      "INSERT INTO #{relation(prefix, "ash_onetime_response_payloads")} (partition_date, claim_id, encoded_response) VALUES ($1, $2::uuid, $3)",
      [partition_date, Ecto.UUID.dump!(id), payload]
    )
  end

  defp connection! do
    {:ok, connection} = Postgrex.start_link(@database_options)
    Process.unlink(connection)

    on_exit(fn ->
      if Process.alive?(connection), do: GenServer.stop(connection, :normal, 5_000)
    end)

    connection
  end

  defp waiting_partition_prune(observer, _prefix) do
    # Observe the pruning worker blocked on the race partition. `pg_locks.granted = false`
    # is a *durable* signal — it persists for the entire time the request is blocked — so a
    # single snapshot cannot miss the wait the way the transient pg_stat_activity.wait_event
    # can under battery load. The worker blocks either taking SHARE (correct) or, once the
    # lock is weakened, ACCESS EXCLUSIVE for the DROP; both are lock requests on the partition,
    # so either mode is caught. ~30s deadline is far beyond any scheduling delay yet halts the
    # instant the wait appears.
    Enum.reduce_while(1..6_000, false, fn _attempt, _last ->
      %{rows: rows} =
        Postgrex.query!(
          observer,
          """
          SELECT 1
          FROM pg_locks l
          JOIN pg_class c ON c.oid = l.relation
          WHERE l.granted = false
            AND l.pid <> pg_backend_pid()
            AND c.relname LIKE 'ash_onetime_response_payloads_race%'
          LIMIT 1
          """,
          []
        )

      if rows == [] do
        Process.sleep(5)
        {:cont, false}
      else
        {:halt, true}
      end
    end)
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
