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
  test "concurrent rolls never leak a 42P07 or produce duplicate partitions — the advisory lock serializes",
       %{prefix: prefix} do
    target = Postgres.for_repo(Repo, prefix)

    # Request months beyond the install window so there is genuine work to race on.
    months = 15

    # Each roll in its own real (sandbox: false) connection. Without the advisory lock, the two
    # CREATE PARTITION OF statements for the same forward month race and one raises 42P07. With
    # the lock, rolls serialize: both may succeed, or under heavy pool contention one may fail
    # closed on lock_timeout — but NEVER a 42P07 leak and NEVER a duplicate partition.
    results =
      Task.async_stream(
        1..2,
        fn _i ->
          with_owner(fn -> Store.roll_partitions(target, months) end)
        end,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == 2

    for result <- results do
      # A roll either succeeds or fails closed with a Result (e.g. lock_timeout under contention,
      # which the next scheduled run retries). It must NEVER raise/leak a 42P07 to the caller.
      assert match?({:ok, %{partitions_created: _}}, result) or
               match?(%AshOnetime.Store.Result{}, result),
             "a concurrent roll returned an unexpected shape: #{inspect(result)}"
    end

    # The load-bearing invariant: no forward month has a duplicate partition. Serialization +
    # idempotency guarantee at most one named partition per month regardless of which rolls won.
    children = with_owner(fn -> partition_children(prefix, "ash_onetime_response_payloads") end)
    names = Enum.filter(children, &(&1 =~ ~r/^ash_onetime_response_payloads_\d{4}_\d{2}$/))

    assert names == Enum.uniq(names),
           "concurrent rolls created duplicate partitions: #{inspect(names -- Enum.uniq(names))}"

    # At least one roll made progress (the common case; under contention both may, or one may).
    total_created =
      results
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> Enum.map(& &1.partitions_created)
      |> Enum.sum()

    assert total_created >= 1
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
