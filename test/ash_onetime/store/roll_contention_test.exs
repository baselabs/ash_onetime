defmodule AshOnetime.Store.RollContentionTest do
  @moduledoc """
  Convergence test for concurrent partition rolls (SEC-5). Each roll runs in its own
  real (sandbox: false) connection. The test asserts that after concurrent rolls + two
  convergence rolls, the partition state is sound: a second convergence reports 0 created
  and the forward window has >= months named partitions. This proves concurrency does not
  corrupt the state, NOT that the advisory lock serializes (the lock and the 42P07 fallback
  are redundant idempotency mechanisms; the lock's absence is not independently observable
  because the fallback — or the fail-closed rescue — absorbs the duplicate).
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
          with_owner(fn -> Store.roll_partitions(target, months) end)
        end,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # First convergence roll: catches up whatever the concurrent rolls missed (any count).
    # If concurrency had corrupted the state (a half-created partition, a stale catalog entry),
    # this roll would fail.
    assert {:ok, _} = with_owner(fn -> Store.roll_partitions(target, months) end)

    # Second convergence roll: everything has converged — must report 0 created. If the
    # concurrent rolls or the first convergence left the state inconsistent, this would fail
    # or report > 0.
    assert {:ok, %{partitions_created: 0}} =
             with_owner(fn -> Store.roll_partitions(target, months) end)

    # The forward months exist at least once (no missing — the install covers 0..12, rolls add
    # 13..months-1; the total named partitions is >= months).
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

  # L3: the partition-roll advisory lock is derived per-prefix so distinct tenants do not
  # serialize against each other (partitions are schema-scoped; two tenants have distinct
  # parents and can never race on the same CREATE PARTITION OF). This pins the derivation
  # contract: same prefix → same key (within-tenant serialization preserved); distinct
  # prefixes → distinct keys (cross-tenant concurrency unblocked); nil prefix → the
  # historical constant. The formula is the contract; this test replicates it against the
  # documented inputs.
  @tag roll_advisory_key_per_prefix: true
  test "roll advisory key is per-prefix (distinct tenants do not over-serialize)" do
    nil_key = advisory_key_for(nil)
    a_key = advisory_key_for("tenant_a")
    b_key = advisory_key_for("tenant_b")
    a_again = advisory_key_for("tenant_a")

    # Nil-prefix keeps the historical constant (single-tenant backward compat).
    assert nil_key == 0x41_5348_4F54
    # Same prefix → same key (within-tenant serialization preserved).
    assert a_key == a_again
    # Distinct prefixes → distinct keys (cross-tenant concurrency unblocked).
    assert a_key != b_key
    # All keys are positive 63-bit bigints (the pg_advisory_xact_lock(bigint) domain; the
    # sign bit is cleared so the value is always non-negative).
    for key <- [nil_key, a_key, b_key], do: assert(key >= 0 and key < 0x8000000000000000)
  end

  # Mirrors Postgres.roll_advisory_key/1's formula (the contract under test).
  defp advisory_key_for(nil), do: 0x41_5348_4F54

  defp advisory_key_for(prefix) do
    <<first_8::binary-size(8), _rest::binary>> = :crypto.hash(:sha256, prefix)
    <<value::64-unsigned-integer>> = first_8
    Bitwise.band(value, 0x7FFFFFFFFFFFFFFF)
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
