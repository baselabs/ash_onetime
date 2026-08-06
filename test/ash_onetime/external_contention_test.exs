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
    assert table_count(context.prefix, "ash_onetime_response_payloads") == 1
    assert_append_only!(context.prefix)
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

  defp table_count(prefix, table) do
    with_observer(fn observer ->
      %{rows: [[count]]} =
        Postgrex.query!(observer, "SELECT count(*) FROM \"#{prefix}\".\"#{table}\"", [])

      count
    end)
  end

  defp with_observer(callback) do
    options = [
      hostname: "127.0.0.1",
      port: 18_841,
      username: "postgres",
      password: "postgres",
      database: "ash_onetime_test"
    ]

    {:ok, observer} = Postgrex.start_link(options)
    Process.unlink(observer)

    try do
      callback.(observer)
    after
      if Process.alive?(observer), do: GenServer.stop(observer, :normal, 5_000)
    end
  end
end
