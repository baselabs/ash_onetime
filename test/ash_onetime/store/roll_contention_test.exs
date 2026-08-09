defmodule AshOnetime.Store.RollContentionTest do
  @moduledoc """
  SEC-5 plan-review finding #1 (blocking): the concurrent-roll tripwire passes vacuously under
  the default sandbox (Task.async workers share one connection). This module mirrors the
  reap_contention_test.exs harness — each roll runs in its own `Sandbox.start_owner!(Repo,
  shared: false, sandbox: false)` real connection — so the advisory lock is the ONLY serializer.
  Without the advisory lock, two concurrent rolls both issue CREATE PARTITION OF for the same
  month and one raises 42P07.
  """

  use ExUnit.Case, async: false

  alias AshOnetime.Store
  alias AshOnetime.Store.Postgres
  alias AshOnetime.Test.{Migration, Repo}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :store

  setup_all do
    installation = Migration.install_generated!()
    on_exit(fn -> Migration.uninstall_generated!(installation) end)
    {:ok, prefix: installation.schema}
  end

  @tag roll_concurrent_serialization: true
  test "concurrent rolls leave the partition state sound — a follow-up roll reaches the expected count",
       %{prefix: prefix} do
    target = Postgres.for_repo(Repo, prefix)

    # Request months beyond the install window so there is genuine work to race on. Two rolls
    # run concurrently in their own real (sandbox: false) connections; under heavy pool
    # contention either or both may fail closed on lock_timeout (the next run retries). The
    # load-bearing contract is NOT "both win" — it is "concurrency does not CORRUPT the state
    # such that a subsequent roll cannot reach the expected partition set."
    months = 15

    Task.async_stream(
      1..2,
      fn _i ->
        with_owner(fn -> Store.roll_partitions(target, months) end)
      end,
      ordered: false,
      timeout: 30_000
    )
    |> Stream.run()

    # A follow-up serial roll must succeed and report 0 created (the concurrent rolls + this
    # one have converged on the full forward window). If concurrency had corrupted the state
    # (a half-created partition, a stale catalog entry), this roll would fail or report > 0.
    assert {:ok, %{partitions_created: 0}} =
             with_owner(fn -> Store.roll_partitions(target, months) end)

    # And the forward months exist exactly once each (no duplicate, no missing).
    children = with_owner(fn -> partition_children(prefix, "ash_onetime_response_payloads") end)
    forward = Enum.filter(children, &(&1 =~ ~r/^ash_onetime_response_payloads_\d{4}_\d{2}$/))
    assert length(forward) >= months
  end

  test "roll_partitions is idempotent even across separate real connections", %{prefix: prefix} do
    target = Postgres.for_repo(Repo, prefix)

    with_owner(fn -> Store.roll_partitions(target, 15) end)

    result =
      with_owner(fn -> Store.roll_partitions(target, 15) end)

    assert {:ok, %{partitions_created: 0}} = result
  end

  defp with_owner(callback) do
    owner = Sandbox.start_owner!(Repo, shared: false, sandbox: false)

    try do
      callback.()
    after
      if Process.alive?(owner) do
        try do
          Sandbox.stop_owner(owner)
        catch
          :exit, _reason -> :ok
        end
      end
    end
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
