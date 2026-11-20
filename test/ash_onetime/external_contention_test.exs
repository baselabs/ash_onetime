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

  @tag defects_batch: true
  @tag complete_mutation: true
  test "external completion bounds its payload insert and reports request in progress", context do
    parent = self()

    with_observer(fn holder ->
      Postgrex.query!(holder, "BEGIN", [])

      try do
        reference = make_ref()

        {caller, monitor} =
          start_monitored_worker(fn ->
            ExternalEffectSupport.put_mode({:pause_after_execute, parent, reference})
            send(parent, {:completion_done, self(), run_quick_lock(context, "completion-bound")})
          end)

        assert_receive {:external_pause, ^reference, :after_execute, operation_key, ^caller},
                       5_000

        Postgrex.query!(
          holder,
          ~s(LOCK TABLE "#{context.prefix}".ash_onetime_response_payloads IN SHARE MODE),
          []
        )

        send(caller, {:external_continue, reference})

        assert_receive {:completion_done, ^caller,
                        {:error,
                         %Ash.Error.Invalid{
                           errors: [%AshOnetime.Error{code: :request_in_progress}]
                         }}},
                       2_000

        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000

        [["execute", ^operation_key]] = ExternalPeer.calls(context.prefix)

        assert %{rows: [["processing"]]} =
                 Postgrex.query!(
                   holder,
                   ~s|SELECT state FROM "#{context.prefix}".ash_onetime_idempotency_claims WHERE id=$1|,
                   [Ecto.UUID.dump!(operation_key)]
                 )
      after
        Postgrex.query!(holder, "ROLLBACK", [])
      end
    end)
  end

  @tag external_replay_lock_timeout_mutation: true
  test "immediate replay bounds its first claim lock and reports request in progress", context do
    assert {:ok, _result} = run_quick_lock(context, "replay-lock-bound")
    reference = make_ref()
    parent = self()
    handler = {__MODULE__, reference}
    cold_repo = start_cold_replay_repo!(context.prefix)
    context = %{context | external_repo: cold_repo}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:ash_onetime, :replay], [:ash_onetime, :conflict]],
        &__MODULE__.replay_lock_barrier/4,
        {parent, reference}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    with_observer(fn holder ->
      Postgrex.query!(holder, "BEGIN", [])

      try do
        {caller, monitor} =
          start_monitored_worker(fn ->
            Process.put(:replay_lock_barrier, reference)
            send(parent, {:external_done, self(), run_quick_lock(context, "replay-lock-bound")})
          end)

        # Admission emits replay only after the grant worker committed. Pause that caller
        # before its first FOR NO KEY UPDATE, then acquire the conflicting lock on another session.
        assert_receive {:replay_lock_ready, ^reference, ^caller}, 30_000

        Postgrex.query!(
          holder,
          ~s(SELECT id FROM "#{context.prefix}".ash_onetime_idempotency_claims FOR UPDATE),
          []
        )

        started = System.monotonic_time(:millisecond)
        send(caller, {:replay_lock_continue, reference})
        assert {backend_pid, [_ | _], query} = wait_for_blocked_query(context.prefix)
        assert String.starts_with?(String.downcase(query), "select claims.id")

        assert %{rows: [[true]]} =
                 Postgrex.query!(
                   holder,
                   "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid=$1 AND NOT granted)",
                   [backend_pid]
                 )

        # The protection is 1000ms; the independent deadline makes unfixed code fail
        # while the holder is still locked, rather than hanging until ExUnit kills it.
        assert_receive {:external_done, ^caller,
                        {:error,
                         %Ash.Error.Invalid{
                           errors: [%AshOnetime.Error{code: :request_in_progress}]
                         }}},
                       2_000

        elapsed = System.monotonic_time(:millisecond) - started
        assert elapsed < 2_000
        assert_receive {:replay_lock_conflict, ^reference, :processing}, 1_000
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000

        IO.puts(
          "REPLAY_LOCK_BOUND pg_locks_wait=true elapsed_ms=#{elapsed} bound_ms=1000 margin_ms=1000"
        )
      after
        Postgrex.query!(holder, "ROLLBACK", [])
      end
    end)
  end

  def replay_lock_barrier(event, _measurements, metadata, {parent, reference}) do
    if Process.get(:replay_lock_barrier) == reference do
      case event do
        [:ash_onetime, :replay] ->
          send(parent, {:replay_lock_ready, reference, self()})
          receive do: ({:replay_lock_continue, ^reference} -> :ok)

        [:ash_onetime, :conflict] ->
          send(parent, {:replay_lock_conflict, reference, metadata.result_class})
      end
    end
  end

  defp start_cold_replay_repo!(prefix) do
    role = "ao_replay_#{System.unique_integer([:positive])}"
    password = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    SQL.query!(
      Repo,
      "CREATE ROLE #{role} LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '#{password}'",
      [],
      log: false
    )

    on_exit(fn ->
      with_observer(fn admin ->
        Postgrex.query!(admin, "DROP OWNED BY #{role}", [])
        Postgrex.query!(admin, "DROP ROLE #{role}", [])
      end)
    end)

    SQL.query!(Repo, ~s(GRANT USAGE ON SCHEMA "#{prefix}" TO #{role}), [])

    SQL.query!(
      Repo,
      ~s(GRANT SELECT, INSERT, UPDATE ON "#{prefix}".ash_onetime_idempotency_claims TO #{role}),
      []
    )

    SQL.query!(
      Repo,
      ~s(GRANT SELECT ON "#{prefix}".ash_onetime_response_payloads, "#{prefix}".ash_onetime_effect_outcomes TO #{role}),
      []
    )

    url =
      System.fetch_env!("DATABASE_URL")
      |> URI.parse()
      |> Map.put(:userinfo, role <> ":" <> password)
      |> URI.to_string()

    {:ok, repo} =
      Repo.start_link(name: nil, url: url, pool: DBConnection.ConnectionPool, pool_size: 2)

    Process.unlink(repo)
    on_exit(fn -> GenServer.stop(repo) end)

    assert SQL.query!(
             repo,
             "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname=session_user",
             []
           ).rows == [[false, false]]

    repo
  end

  @tag external_operation_key_mutation: true
  test "concurrent finalizers use one peer key and one local effect while a row lock blocks the loser",
       context do
    reference = make_ref()
    parent = self()

    {winner, winner_monitor} =
      start_monitored_worker(fn ->
        ExternalEffectSupport.put_mode({:pause_local, parent, reference})
        send(parent, {:external_done, self(), run_generic(context)})
      end)

    assert_receive {:external_pause, ^reference, :local_finalize, operation_key, ^winner}, 30_000
    assert [["execute", ^operation_key]] = ExternalPeer.calls(context.prefix)
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 0

    {loser, loser_monitor} =
      start_monitored_worker(fn ->
        send(parent, {:external_done, self(), run_generic(context)})
      end)

    assert {_blocked_pid, blockers, query} = wait_for_blocked_query(context.prefix)
    assert blockers != []
    assert String.contains?(String.downcase(query), "ash_onetime_idempotency_claims")

    send(winner, {:external_continue, reference})

    assert_receive {:external_done, ^winner, {:ok, winner_result}}, 30_000
    assert_receive {:DOWN, ^winner_monitor, :process, ^winner, :normal}, 30_000
    assert_receive {:external_done, ^loser, {:ok, loser_result}}, 30_000
    assert_receive {:DOWN, ^loser_monitor, :process, ^loser, :normal}, 30_000
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
  @tag pre_peer_lock_mutation: true
  test "an in-flight retry is refused while the original holds the pre-peer claim lock",
       context do
    reference = make_ref()
    parent = self()

    {first, first_monitor} =
      start_monitored_worker(fn ->
        ExternalEffectSupport.put_mode({:pause_before_execute, parent, reference})
        send(parent, {:external_done, self(), run_quick_lock(context, "unguarded-window")})
      end)

    assert_receive {:external_pause, ^reference, :before_execute, operation_key, ^first}, 30_000

    # The first caller holds the pre-peer claim lock in its open transaction.
    # A same-key retry must wait on that claim rather than reach the peer.
    # A bounded lock timeout returns the concurrent-retry error.
    # Only the admitted caller executes the peer operation.
    {second, second_monitor} =
      start_monitored_worker(fn ->
        send(parent, {:external_done, self(), run_quick_lock(context, "unguarded-window")})
      end)

    assert {_pid, blockers, query} = wait_for_blocked_query(context.prefix)
    assert blockers != []
    assert String.contains?(String.downcase(query), "ash_onetime_idempotency_claims")

    assert_receive {:external_done, ^second,
                    {:error,
                     %Ash.Error.Invalid{
                       errors: [%AshOnetime.Error{code: :request_in_progress}]
                     }}},
                   30_000

    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 30_000

    send(first, {:external_continue, reference})

    assert_receive {:external_done, ^first, {:ok, _first_result}}, 30_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 30_000

    calls = ExternalPeer.calls(context.prefix)
    assert Enum.count(calls, fn [kind, _key] -> kind == "execute" end) == 1
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
      start_monitored_worker(fn ->
        ExternalEffectSupport.put_mode({:pause_execute_probe, parent, reference})
        send(parent, {:external_done, self(), run_unguarded(context, "execution-environment")})
      end)

    # The callback runs inside the caller's open transaction.
    # Its backend pid lets the observer inspect pg_stat_activity while paused.
    # A peer wait leaves that backend idle in transaction.
    assert_receive {:external_pause, ^reference, :execute_probe, _operation_key, ^caller, true,
                    backend_pid},
                   30_000

    assert %{rows: [["idle in transaction", true]]} =
             with_observer(fn observer ->
               Postgrex.query!(
                 observer,
                 "SELECT state, xact_start IS NOT NULL FROM pg_stat_activity WHERE pid = $1",
                 [backend_pid]
               )
             end)

    send(caller, {:external_continue, reference})

    assert_receive {:external_done, ^caller, {:ok, _result}}, 30_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 30_000
  end

  @tag external_operation_key_mutation: true
  test "the pre-peer claim lock holds across the peer call, so an overlapping retry never reaches the peer",
       context do
    reference = make_ref()
    parent = self()

    {first, first_monitor} =
      start_monitored_worker(fn ->
        ExternalEffectSupport.put_mode({:hold_execute, parent, reference})
        send(parent, {:external_done, self(), run_quick_lock(context, "held-execute")})
      end)

    # The first caller's peer transaction holds the operation-key row uncommitted: the
    # effect is genuinely in flight, invisible to any other connection — the exact state
    # in which, pre-lock, an honest retry recovered :absent and its execute BLOCKED on
    # the in-flight key claim (the observed overlap). With the claim lock held across
    # the peer call, the retry never reaches the peer at all.
    assert_receive {:external_pause, ^reference, :held_execute, operation_key, ^first}, 30_000

    {second, second_monitor} =
      start_monitored_worker(fn ->
        send(parent, {:external_done, self(), run_quick_lock(context, "held-execute")})
      end)

    assert {_pid, blockers, query} = wait_for_blocked_query(context.prefix)
    assert blockers != []
    assert String.contains?(String.downcase(query), "ash_onetime_idempotency_claims")

    assert_receive {:external_done, ^second,
                    {:error,
                     %Ash.Error.Invalid{
                       errors: [%AshOnetime.Error{code: :request_in_progress}]
                     }}},
                   30_000

    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 30_000

    send(first, {:external_continue, reference})

    assert_receive {:external_done, ^first, {:ok, _first_result}}, 30_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 30_000

    calls = ExternalPeer.calls(context.prefix)
    assert Enum.count(calls, fn [kind, _key] -> kind == "execute" end) == 1
    assert Enum.uniq(Enum.map(calls, &List.last/1)) == [operation_key]
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_peer_operations") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
    assert payload_count(context.prefix, operation_key) == 1
  end

  test "recover runs inside the retry caller's open transaction", context do
    parent = self()
    settled = make_ref()

    {abandoned, abandoned_monitor} =
      start_monitored_worker(fn ->
        ExternalEffectSupport.put_mode({:pause_before_execute, parent, settled})
        send(parent, {:external_done, self(), run_unguarded(context, "recover-environment")})
      end)

    assert_receive {:external_pause, ^settled, :before_execute, operation_key, ^abandoned},
                   30_000

    Process.exit(abandoned, :kill)
    assert_receive {:DOWN, ^abandoned_monitor, :process, ^abandoned, :killed}, 30_000

    # The abandoned caller leaves a processing claim; the retry recovers it from inside
    # its own open transaction.
    reference = make_ref()

    {retry, retry_monitor} =
      start_monitored_worker(fn ->
        ExternalEffectSupport.put_mode({:pause_recover_probe, parent, reference})
        send(parent, {:external_done, self(), run_unguarded(context, "recover-environment")})
      end)

    assert_receive {:external_pause, ^reference, :recover_probe, ^operation_key, ^retry, true},
                   30_000

    send(retry, {:external_continue, reference})

    assert_receive {:external_done, ^retry, {:ok, _result}}, 30_000
    assert_receive {:DOWN, ^retry_monitor, :process, ^retry, :normal}, 30_000
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

  defp run_quick_lock(context, request_key) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(context.external_repo)

    try do
      Resource
      |> Ash.ActionInput.for_action(:external_redeem_quick_lock, %{
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
      if Process.alive?(observer), do: GenServer.stop(observer, :normal, 30_000)
    end
  end
end
