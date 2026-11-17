defmodule AshOnetime.Store.CommittedWorkerUncertaintyTest do
  # How the committed-claim worker reports a store failure, each case reached on its real path
  # through a protected external-effect action: a backend terminated mid-statement
  # (:disconnected), a statement that outlives the worker's 30-second deadline
  # (:worker_timeout), and every SQLSTATE class the store classifier names, raised by
  # PostgreSQL on the worker's claim INSERT. Each case checks the caller's error code, the
  # store_uncertainty event (or its absence) and that the peer was never called.
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Error
  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.ExternalPeer

  # {SQLSTATE, the caller's error code, the store_uncertainty class or nil for none}.
  # Transient server conditions roll the statement back: a definite, retryable :store_failure.
  # A lost session or an unknown completion is uncertainty. Everything else is a fault.
  @sqlstate_cases [
    {"57014", :store_failure, nil},
    {"40001", :store_failure, nil},
    {"40P01", :store_failure, nil},
    {"53300", :store_failure, nil},
    {"58030", :store_failure, nil},
    {"40003", :dispatched_unknown, :unknown},
    {"08003", :disconnected, :disconnected},
    {"08006", :disconnected, :disconnected},
    {"25P03", :disconnected, :disconnected},
    {"57P01", :disconnected, :disconnected},
    {"57P02", :disconnected, :disconnected},
    {"57P05", :disconnected, :disconnected},
    {"23514", :store_invariant, nil},
    {"XX001", :store_invariant, nil}
  ]

  @moduletag unboxed: true

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    ExternalPeer.install!(prefix)
    handler = "committed-worker-uncertainty-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ash_onetime, :store_uncertainty],
        fn _event, measurements, metadata, _config ->
          send(parent, {:store_uncertainty, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, external_repo: start_unboxed_repo!()}
  end

  test "a terminated worker backend reports :disconnected and never reaches the peer", context do
    parent = self()

    with_observer(fn holder ->
      Postgrex.query!(holder, "BEGIN", [])

      try do
        Postgrex.query!(
          holder,
          ~s(LOCK TABLE "#{context.prefix}".ash_onetime_idempotency_claims IN ACCESS EXCLUSIVE MODE),
          []
        )

        {caller, _monitor} =
          start_monitored_worker(fn ->
            send(parent, {:done, self(), run_external(context, "terminated-worker")})
          end)

        worker_backend = wait_for_waiting_insert(context.prefix, "Lock")

        with_observer(fn killer ->
          assert %{rows: [[true]]} =
                   Postgrex.query!(killer, "SELECT pg_terminate_backend($1)", [worker_backend])
        end)

        assert_receive {:done, ^caller, {:error, _error}}, 10_000
      after
        Postgrex.query!(holder, "ROLLBACK", [])
      end
    end)

    assert_receive {:store_uncertainty, %{count: 1},
                    %{
                      strategy: :idempotency,
                      resource: Resource,
                      action: :external_redeem,
                      result_class: :disconnected
                    }}

    refute_received {:store_uncertainty, _measurements, _metadata}
    assert ExternalPeer.calls(context.prefix) == []
  end

  @tag timeout: 120_000
  test "a worker statement past the 30-second deadline reports :worker_timeout", context do
    # A BEFORE INSERT trigger sleeps past the worker's deadline. Lock waits cannot reach it:
    # every claim lock timeout is bounded at 25 seconds, below the 30-second worker kill.
    # The repo keeps Ecto's default 15-second timeout, so the worker's own bound, not the
    # host's, has to govern its transaction.
    install_insert_trigger!(context.prefix, "PERFORM pg_catalog.pg_sleep(40);")
    on_exit(fn -> remove_insert_trigger!(context.prefix) end)
    parent = self()

    {caller, _monitor} =
      start_monitored_worker(fn ->
        send(parent, {:done, self(), run_external(context, "deadline-worker")})
      end)

    _sleeping_backend = wait_for_waiting_insert(context.prefix, "Timeout")
    assert_receive {:done, ^caller, {:error, _error}}, 45_000

    assert_receive {:store_uncertainty, %{count: 1},
                    %{
                      strategy: :idempotency,
                      resource: Resource,
                      action: :external_redeem,
                      result_class: :worker_timeout
                    }}

    refute_received {:store_uncertainty, _measurements, _metadata}
    assert ExternalPeer.calls(context.prefix) == []
  end

  for {sqlstate, code, uncertainty} <- @sqlstate_cases do
    test "SQLSTATE #{sqlstate} on the worker's claim reports #{inspect(code)}", context do
      sqlstate = unquote(sqlstate)
      install_insert_trigger!(context.prefix, "RAISE EXCEPTION USING ERRCODE = '#{sqlstate}';")
      on_exit(fn -> remove_insert_trigger!(context.prefix) end)

      assert {:error, error} = run_external(context, "sqlstate-#{sqlstate}")
      assert Error.code(error) == unquote(code)

      case unquote(uncertainty) do
        nil ->
          refute_received {:store_uncertainty, _measurements, _metadata}

        class ->
          assert_received {:store_uncertainty, %{count: 1},
                           %{action: :external_redeem, result_class: ^class}}

          refute_received {:store_uncertainty, _measurements, _metadata}
      end

      assert ExternalPeer.calls(context.prefix) == []
    end
  end

  defp run_external(context, request_key) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(context.external_repo)

    try do
      Resource
      |> Ash.ActionInput.for_action(:external_redeem, %{
        value: 23,
        request_key: request_key,
        proof: "proof-#{request_key}"
      })
      |> Ash.ActionInput.set_tenant(context.prefix)
      |> Ash.run_action()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  # A BEFORE INSERT trigger on the claims table whose plpgsql body is `body`.
  defp install_insert_trigger!(prefix, body) do
    with_observer(fn observer ->
      Postgrex.query!(
        observer,
        """
        CREATE FUNCTION "#{prefix}".committed_worker_trigger() RETURNS trigger
        LANGUAGE plpgsql AS $$ BEGIN #{body} RETURN NEW; END $$
        """,
        []
      )

      Postgrex.query!(
        observer,
        """
        CREATE TRIGGER committed_worker_trigger
        BEFORE INSERT ON "#{prefix}".ash_onetime_idempotency_claims
        FOR EACH ROW EXECUTE FUNCTION "#{prefix}".committed_worker_trigger()
        """,
        []
      )
    end)
  end

  defp remove_insert_trigger!(prefix) do
    with_observer(fn observer ->
      # A killed worker's backend may still be asleep in the trigger.
      Postgrex.query!(
        observer,
        """
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event = 'PgSleep' AND query LIKE $1
        """,
        ["%#{prefix}%ash_onetime_idempotency_claims%"]
      )

      Postgrex.query!(
        observer,
        ~s|DROP TRIGGER IF EXISTS committed_worker_trigger ON "#{prefix}".ash_onetime_idempotency_claims|,
        []
      )

      Postgrex.query!(
        observer,
        ~s|DROP FUNCTION IF EXISTS "#{prefix}".committed_worker_trigger()|,
        []
      )
    end)
  end

  # The worker's claim statement, waiting on `wait_event_type`.
  defp wait_for_waiting_insert(prefix, wait_event_type) do
    Enum.reduce_while(1..2_000, nil, fn _attempt, _last ->
      case waiting_insert(prefix, wait_event_type) do
        nil ->
          Process.sleep(5)
          {:cont, nil}

        pid ->
          {:halt, pid}
      end
    end) || flunk("the committed-claim worker's INSERT never waited on #{wait_event_type}")
  end

  defp waiting_insert(prefix, wait_event_type) do
    with_observer(fn observer ->
      %{rows: rows} =
        Postgrex.query!(
          observer,
          """
          SELECT pid FROM pg_stat_activity
          WHERE datname = current_database()
            AND wait_event_type = $1
            AND query LIKE $2
          ORDER BY pid
          """,
          [wait_event_type, "%#{prefix}%ash_onetime_idempotency_claims%"]
        )

      case rows do
        [[pid] | _rest] -> pid
        [] -> nil
      end
    end)
  end

  defp with_observer(callback) do
    {:ok, observer} = Postgrex.start_link(ExternalPeer.database_options())
    Process.unlink(observer)

    try do
      callback.(observer)
    after
      if Process.alive?(observer), do: GenServer.stop(observer, :normal, 30_000)
    end
  end
end
