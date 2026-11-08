defmodule AshOnetime.BoundaryContentionTest do
  @moduledoc """
  Concurrency proofs for the context boundary on real PostgreSQL connections
  (no sandbox): an overlapping context admits exactly one append per read epoch
  with no phantom admission, a writer on tags held by an open transaction
  blocks, disjoint contexts never block each other, and writers of one context
  commit in seq order.
  """
  use ExUnit.Case, async: false

  alias AshOnetime.Boundary
  alias AshOnetime.Test.{RealConnection, Repo}
  alias AshOnetime.Test.Support.BoundaryResource

  @writers 12
  @max_retries 40

  # Wall-clock time keeps tenants unique across test-RUN restarts; the unique
  # integer keeps them unique within one run.
  defp unique_tenant(prefix),
    do: "#{prefix}-#{System.system_time()}-#{System.unique_integer([:positive])}"

  defp spawn_append(tenant, query, cutoff, facts) do
    parent = self()

    Task.async(fn ->
      result = append_in_transaction(tenant, query, cutoff, facts)
      send(parent, {self(), result})
      result
    end)
  end

  defp append_in_transaction(tenant, query, cutoff, facts) do
    RealConnection.with_connection(fn ->
      Repo.transaction(fn ->
        Boundary.append_if(BoundaryResource, query, cutoff, facts, tenant: tenant)
      end)
    end)
  end

  @tag boundary_check_mutation: true
  test "overlapping contexts admit exactly one append per read epoch" do
    tenant = unique_tenant("boundary-overlap")
    query = {:all, [tag: "cart:overlap", type: "hold"]}

    tasks =
      for _ <- 1..@writers,
          do: spawn_append(tenant, query, 0, [%{type: "hold", tags: ["cart:overlap"]}])

    results = Enum.map(tasks, &Task.await(&1, 10_000))

    {admitted, refused} =
      Enum.reduce(results, {0, 0}, fn
        {:ok, {:ok, [_fact]}}, {a, r} -> {a + 1, r}
        {:ok, {:error, {:context_changed, _seq}}}, {a, r} -> {a, r + 1}
        other, {_a, _r} -> flunk("unexpected append result: #{inspect(other)}")
      end)

    assert admitted == 1
    assert refused == @writers - 1

    assert {:ok, %{facts: [fact], cutoff: cutoff}} =
             RealConnection.with_connection(fn ->
               Boundary.read(BoundaryResource, query, tenant: tenant)
             end)

    assert cutoff == fact.seq
  end

  test "disjoint contexts never block; a blocked writer refuses only after the holder commits" do
    tenant = unique_tenant("boundary-disjoint")

    parent = self()

    holder =
      Task.async(fn ->
        RealConnection.with_connection(fn ->
          {:ok, holder_result} =
            Repo.transaction(fn ->
              # Appends, then holds the transaction (and the tag's advisory
              # lock) open until released.
              {:ok, _} =
                Boundary.append_if(
                  BoundaryResource,
                  {:tag, "cart:held"},
                  0,
                  [
                    %{type: "hold", tags: ["cart:held"]}
                  ],
                  tenant: tenant
                )

              send(parent, {:holder_locking, self()})

              receive do
                :release -> :ok
              end
            end)

          holder_result
        end)
      end)

    assert_receive {:holder_locking, holder_task} when is_pid(holder_task), 5_000

    tasks =
      for index <- 1..@writers do
        tag = "cart:free#{index}"
        spawn_append(tenant, {:tag, tag}, 0, [%{type: "hold", tags: [tag]}])
      end

    # Writers on disjoint tags complete while the holder's transaction is open.
    Enum.each(tasks, fn task ->
      assert {:ok, {:ok, [_fact]}} = Task.await(task, 5_000)
    end)

    # A writer on the HELD tag blocks while the holder's fact is uncommitted —
    # its check cannot miss the holder's append (no phantom admission) — and
    # refuses once the holder commits.
    blocked = spawn_append(tenant, {:tag, "cart:held"}, 0, [%{type: "hold", tags: ["cart:held"]}])
    blocked_pid = blocked.pid
    refute_receive {^blocked_pid, _result}, 300

    send(holder_task, :release)
    assert {:ok, {:error, {:context_changed, changed_to}}} = Task.await(blocked, 5_000)
    assert :ok = Task.await(holder, 5_000)

    assert {:ok, %{facts: [fact]}} =
             RealConnection.with_connection(fn ->
               Boundary.read(BoundaryResource, {:tag, "cart:held"}, tenant: tenant)
             end)

    assert changed_to == fact.seq
  end

  test "writers of one context commit in seq order: completion order equals seq order" do
    tenant = unique_tenant("boundary-order")
    tag = "cart:order"

    parent = self()

    tasks =
      for index <- 1..@writers do
        Task.async(fn ->
          retry_append(parent, index, tenant, tag)
        end)
      end

    admissions = collect_admissions(@writers, [])
    Enum.each(tasks, &Task.await(&1, 20_000))

    seqs = Enum.map(admissions, & &1.seq)
    assert length(seqs) == @writers
    assert Enum.uniq(seqs) == seqs
    assert Enum.sort(seqs) == seqs, "admitted facts did not complete in seq order"

    assert {:ok, %{facts: facts}} =
             RealConnection.with_connection(fn ->
               Boundary.read(BoundaryResource, {:tag, tag}, tenant: tenant, limit: 1000)
             end)

    assert length(facts) == @writers
  end

  defp collect_admissions(0, acc), do: Enum.reverse(acc)

  defp collect_admissions(remaining, acc) do
    receive do
      {:admitted, seq} -> collect_admissions(remaining - 1, [%{seq: seq} | acc])
    after
      10_000 -> flunk("timed out waiting for admissions")
    end
  end

  # One checkout carries the whole retry loop: a back-to-back second checkout
  # in one process races the ownership manager's teardown (see RealConnection's
  # moduledoc), so re-checking-out per retry is not an option.
  defp retry_append(parent, round, tenant, tag) do
    RealConnection.with_connection(fn ->
      retry_round(parent, round, tenant, tag, 0)
    end)
  end

  defp retry_round(parent, round, tenant, tag, attempts) when attempts < @max_retries do
    {:ok, %{cutoff: cutoff}} = Boundary.read(BoundaryResource, {:tag, tag}, tenant: tenant)

    case Repo.transaction(fn ->
           Boundary.append_if(
             BoundaryResource,
             {:tag, tag},
             cutoff,
             [
               %{type: "hold:#{round}", tags: [tag]}
             ],
             tenant: tenant
           )
         end) do
      {:ok, {:ok, [%{seq: seq}]}} ->
        send(parent, {:admitted, seq})

      {:ok, {:error, {:context_changed, _}}} ->
        retry_round(parent, round, tenant, tag, attempts + 1)

      other ->
        exit({:unexpected_append_result, other})
    end
  end

  defp retry_round(_parent, _round, _tenant, _tag, _attempts), do: exit(:retry_exhausted)
end
