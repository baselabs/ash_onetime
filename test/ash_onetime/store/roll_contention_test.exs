defmodule AshOnetime.Store.RollContentionTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Store
  alias AshOnetime.Store.Postgres
  alias AshOnetime.Test.{Migration, RealConnection, Repo}
  alias Ecto.Adapters.SQL

  @moduletag :store

  setup_all do
    installation = Migration.install_generated!()
    on_exit(fn -> Migration.uninstall_generated!(installation) end)
    {:ok, prefix: installation.schema}
  end

  @tag roll_concurrent_serialization: true
  test "concurrent rolls converge — the partition state is sound after the window is fully rolled",
       %{prefix: prefix} do
    target = Postgres.for_repo(Repo, prefix)
    months = 15

    # Two rolls run concurrently in their own real connections. Results are observed but not
    # asserted on shape — under contention either may fail closed (lock_timeout/checkout).
    _concurrent_results =
      Task.async_stream(
        1..2,
        fn _i ->
          RealConnection.with_connection(fn -> Store.roll_partitions(target, months) end)
        end,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # First convergence roll: catches up whatever the concurrent rolls missed (any count).
    # If concurrency had corrupted the state (a half-created partition, a stale catalog entry),
    # this roll would fail.
    assert {:ok, _} =
             RealConnection.with_connection(fn -> Store.roll_partitions(target, months) end)

    # Second convergence roll: everything has converged — must report 0 created. If the
    # concurrent rolls or the first convergence left the state inconsistent, this would fail
    # or report > 0.
    assert {:ok, %{partitions_created: 0}} =
             RealConnection.with_connection(fn -> Store.roll_partitions(target, months) end)

    # The forward months exist at least once (no missing — the install covers 0..12, rolls add
    # 13..months-1; the total named partitions is >= months).
    children =
      RealConnection.with_connection(fn ->
        partition_children(prefix, "ash_onetime_response_payloads")
      end)

    forward = Enum.filter(children, &(&1 =~ ~r/^ash_onetime_response_payloads_\d{4}_\d{2}$/))
    assert length(forward) >= months
  end

  test "roll_partitions is idempotent even across separate real connections", %{prefix: prefix} do
    target = Postgres.for_repo(Repo, prefix)

    RealConnection.with_connection(fn -> Store.roll_partitions(target, 15) end)

    result =
      RealConnection.with_connection(fn -> Store.roll_partitions(target, 15) end)

    assert {:ok, %{partitions_created: 0}} = result
  end

  test "back-to-back real connections in one process never collide on stale allowance" do
    for _ <- 1..100 do
      assert :ok = RealConnection.with_connection(fn -> :ok end)
    end
  end

  @tag unboxed: true
  test "roll advisory lock identifies the physical parent OID", %{prefix: prefix} do
    RealConnection.with_connection(fn ->
      Repo.transaction(fn ->
        assert %{rows: [[_]]} =
                 SQL.query!(
                   Repo,
                   ~s|SELECT "#{Postgres.routine_schema(prefix)}".ash_onetime_roll_payload_partitions(1::integer)|,
                   []
                 )

        assert %{rows: [[true]]} =
                 SQL.query!(
                   Repo,
                   "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=1095717452 AND objid=$1::text::regclass::oid AND pid=pg_backend_pid())",
                   [~s("#{prefix}".ash_onetime_response_payloads)]
                 )
      end)
    end)
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
end
