defmodule AshOnetime.ExternalContentionTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.{ExternalEffectSupport, ExternalPeer}

  @moduletag unboxed: true

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    ExternalPeer.install!(prefix)
    {:ok, external_repo: start_unboxed_repo!()}
  end

  @tag external_operation_key_mutation: true
  test "concurrent finalizers use one peer key and one local effect while a row lock blocks the loser",
       context do
    reference = make_ref()
    parent = self()

    {winner, winner_monitor} =
      spawn_monitor(fn ->
        ExternalEffectSupport.put_mode({:pause_local, parent, reference})
        send(parent, {:external_done, self(), run_generic(context)})
      end)

    assert_receive {:external_pause, ^reference, :local_finalize, operation_key, ^winner}, 5_000
    assert [["execute", ^operation_key]] = ExternalPeer.calls(context.prefix)
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 0

    {loser, loser_monitor} =
      spawn_monitor(fn -> send(parent, {:external_done, self(), run_generic(context)}) end)

    assert {_blocked_pid, blockers, query} = wait_for_blocked_query(context.prefix)
    assert blockers != []
    assert String.contains?(String.downcase(query), "ash_onetime_idempotency_claims")

    send(winner, {:external_continue, reference})

    assert_receive {:external_done, ^winner, {:ok, winner_result}}, 5_000
    assert_receive {:DOWN, ^winner_monitor, :process, ^winner, :normal}, 5_000
    assert_receive {:external_done, ^loser, {:ok, loser_result}}, 5_000
    assert_receive {:DOWN, ^loser_monitor, :process, ^loser, :normal}, 5_000
    assert winner_result == loser_result

    calls = ExternalPeer.calls(context.prefix)
    assert Enum.uniq(Enum.map(calls, &List.last/1)) == [operation_key]
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_peer_operations") == 1
    assert payload_count(context.prefix, operation_key) == 1
    assert_append_only!(context.prefix)
  end

  @tag external_operation_key_mutation: true
  test "an in-flight retry truthfully recovers absence and both callers execute under one operation key",
       context do
    reference = make_ref()
    parent = self()

    {first, first_monitor} =
      spawn_monitor(fn ->
        ExternalEffectSupport.put_mode({:pause_before_execute, parent, reference})
        send(parent, {:external_done, self(), run_unguarded(context, "unguarded-window")})
      end)

    assert_receive {:external_pause, ^reference, :before_execute, operation_key, ^first}, 5_000

    # The first caller sits inside the unguarded window: its claim is committed, every lock
    # from the independent claim transaction is released, and the peer has not been called.
    # A retry of the same logical key recovers first; the peer genuinely has no record yet,
    # so an honest adapter returns :absent and the retry executes under the SAME operation
    # key — no caller death, no lying adapter.
    {second, second_monitor} =
      spawn_monitor(fn ->
        send(parent, {:external_done, self(), run_unguarded(context, "unguarded-window")})
      end)

    assert_receive {:external_done, ^second, {:ok, second_result}}, 5_000
    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 5_000

    send(first, {:external_continue, reference})

    assert_receive {:external_done, ^first, {:ok, first_result}}, 5_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 5_000
    assert first_result == second_result

    # Two execute calls reached the peer bearing one operation key. The finalize row lock
    # kept the LOCAL effect single (one payload, one local effect, identical results); only
    # the peer stands between the redundant execute and a duplicate effect — and only an
    # atomic insert-on-key dedup absorbs it, which is why the adapter contract requires one.
    calls = ExternalPeer.calls(context.prefix)
    assert Enum.count(calls, fn [kind, _key] -> kind == "execute" end) == 2
    assert Enum.uniq(Enum.map(calls, &List.last/1)) == [operation_key]
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_peer_operations") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
    assert payload_count(context.prefix, operation_key) == 1
  end

  test "the adapter callbacks run inside the caller's open transaction", context do
    reference = make_ref()
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        ExternalEffectSupport.put_mode({:pause_execute_probe, parent, reference})
        send(parent, {:external_done, self(), run_unguarded(context, "execution-environment")})
      end)

    # The probe reports the caller's own transaction state from inside the callback: the
    # action transaction is open on the caller's connection while the adapter executes, so
    # an unbounded peer call holds a pooled connection and an idle-in-transaction backend.
    assert_receive {:external_pause, ^reference, :execute_probe, _operation_key, ^caller, true},
                   5_000

    send(caller, {:external_continue, reference})

    assert_receive {:external_done, ^caller, {:ok, _result}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5_000
  end

  @tag external_operation_key_mutation: true
  test "a retry's execute overlaps the original's in-flight execute and only the atomic key claim absorbs it",
       context do
    reference = make_ref()
    parent = self()

    {first, first_monitor} =
      spawn_monitor(fn ->
        ExternalEffectSupport.put_mode({:hold_execute, parent, reference})
        send(parent, {:external_done, self(), run_unguarded(context, "held-execute")})
      end)

    # The first caller's peer transaction holds the operation-key row uncommitted: the
    # effect is genuinely in flight, invisible to any other connection.
    assert_receive {:external_pause, ^reference, :held_execute, operation_key, ^first}, 5_000

    {second, second_monitor} =
      spawn_monitor(fn ->
        send(parent, {:external_done, self(), run_unguarded(context, "held-execute")})
      end)

    # The retry recovers truthfully (:absent — the held transaction is invisible) and
    # executes; its atomic insert-on-key claim BLOCKS on the in-flight key row. That
    # blocking is the deterministic overlap: the second execute is inside the peer while
    # the first is still in flight — the exact window in which a check-then-act peer
    # (SELECT then INSERT) would race past the check and double-apply the effect.
    assert {_pid, blockers, query} = wait_for_blocked_insert(context.prefix)
    assert blockers != []
    assert String.contains?(String.downcase(query), "external_peer_operations")

    send(first, {:external_continue, reference})

    assert_receive {:external_done, ^first, {:ok, first_result}}, 5_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 5_000
    assert_receive {:external_done, ^second, {:ok, second_result}}, 5_000
    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 5_000
    assert first_result == second_result

    calls = ExternalPeer.calls(context.prefix)
    assert Enum.count(calls, fn [kind, _key] -> kind == "execute" end) == 2
    assert Enum.uniq(Enum.map(calls, &List.last/1)) == [operation_key]
    # The atomic insert-on-key claim absorbed the overlapping execute: one operation,
    # one effect, one local effect, one stored payload.
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_peer_operations") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
    assert payload_count(context.prefix, operation_key) == 1
  end

  test "recover runs inside the retry caller's open transaction", context do
    parent = self()
    settled = make_ref()

    {abandoned, abandoned_monitor} =
      spawn_monitor(fn ->
        ExternalEffectSupport.put_mode({:pause_before_execute, parent, settled})
        send(parent, {:external_done, self(), run_unguarded(context, "recover-environment")})
      end)

    assert_receive {:external_pause, ^settled, :before_execute, operation_key, ^abandoned},
                   5_000

    Process.exit(abandoned, :kill)
    assert_receive {:DOWN, ^abandoned_monitor, :process, ^abandoned, :killed}, 5_000

    # The abandoned caller leaves a processing claim; the retry recovers it from inside
    # its own open transaction.
    reference = make_ref()

    {retry, retry_monitor} =
      spawn_monitor(fn ->
        ExternalEffectSupport.put_mode({:pause_recover_probe, parent, reference})
        send(parent, {:external_done, self(), run_unguarded(context, "recover-environment")})
      end)

    assert_receive {:external_pause, ^reference, :recover_probe, ^operation_key, ^retry, true},
                   5_000

    send(retry, {:external_continue, reference})

    assert_receive {:external_done, ^retry, {:ok, _result}}, 5_000
    assert_receive {:DOWN, ^retry_monitor, :process, ^retry, :normal}, 5_000
  end

  defp run_generic(context) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(context.external_repo)

    try do
      Resource
      |> Ash.ActionInput.for_action(:external_redeem, %{
        value: 19,
        request_key: "contended-external",
        proof: "proof-contended-external"
      })
      |> Ash.ActionInput.set_tenant(context.prefix)
      |> Ash.run_action()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp run_unguarded(context, request_key) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(context.external_repo)

    try do
      Resource
      |> Ash.ActionInput.for_action(:external_redeem, %{
        value: 19,
        request_key: request_key,
        proof: "proof-#{request_key}"
      })
      |> Ash.ActionInput.set_tenant(context.prefix)
      |> Ash.run_action()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp wait_for_blocked_query(prefix) do
    # ~10s deadline: generous for a loaded CI runner; halts as soon as the wait is observed.
    Enum.reduce_while(1..2_000, nil, fn _attempt, _last ->
      case blocked_query(prefix) do
        nil ->
          Process.sleep(5)
          {:cont, nil}

        blocked ->
          {:halt, blocked}
      end
    end)
  end

  defp wait_for_blocked_insert(prefix) do
    Enum.reduce_while(1..2_000, nil, fn _attempt, _last ->
      case blocked_insert(prefix) do
        nil ->
          Process.sleep(5)
          {:cont, nil}

        blocked ->
          {:halt, blocked}
      end
    end)
  end

  defp blocked_insert(prefix) do
    with_observer(fn observer ->
      %{rows: rows} =
        Postgrex.query!(
          observer,
          """
          SELECT pid, pg_blocking_pids(pid), query
          FROM pg_stat_activity
          WHERE datname = current_database()
            AND wait_event_type = 'Lock'
            AND query LIKE $1
          ORDER BY pid
          """,
          ["%#{prefix}%external_peer_operations%"]
        )

      case rows do
        [[pid, blockers, query] | _rest] -> {pid, blockers, query}
        [] -> nil
      end
    end)
  end

  defp blocked_query(prefix) do
    with_observer(fn observer ->
      %{rows: rows} =
        Postgrex.query!(
          observer,
          """
          SELECT pid, pg_blocking_pids(pid), query
          FROM pg_stat_activity
          WHERE datname = current_database()
            AND wait_event_type = 'Lock'
            AND query LIKE $1
          ORDER BY pid
          """,
          ["%#{prefix}%ash_onetime_idempotency_claims%"]
        )

      case rows do
        [[pid, blockers, query] | _rest] -> {pid, blockers, query}
        [] -> nil
      end
    end)
  end

  defp assert_append_only!(prefix) do
    for table <- ["external_peer_calls", "external_peer_effects", "external_local_effects"] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               with_observer(fn observer ->
                 Postgrex.query!(observer, "BEGIN", [])

                 result =
                   Postgrex.query(
                     observer,
                     "UPDATE \"#{prefix}\".\"#{table}\" SET event_id = event_id",
                     []
                   )

                 Postgrex.query!(observer, "ROLLBACK", [])
                 result
               end)
    end
  end

  # Payload rows are counted per claim: the module shares one store installation across
  # tests, so a whole-table count would include unrelated tests' claims.
  defp payload_count(prefix, claim_id) do
    with_observer(fn observer ->
      %{rows: [[count]]} =
        Postgrex.query!(
          observer,
          "SELECT count(*) FROM \"#{prefix}\".\"ash_onetime_response_payloads\" WHERE claim_id = $1::uuid",
          [Ecto.UUID.dump!(claim_id)]
        )

      count
    end)
  end

  defp with_observer(callback) do
    # Observer sessions derive host/port from the Repo URL — never a pinned
    # port (per-machine PGPORT via .env).
    {:ok, observer} = Postgrex.start_link(ExternalPeer.database_options())
    Process.unlink(observer)

    try do
      callback.(observer)
    after
      if Process.alive?(observer), do: GenServer.stop(observer, :normal, 5_000)
    end
  end
end
