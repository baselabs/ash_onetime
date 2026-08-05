defmodule AshOnetime.Store.ContentionTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Store
  alias AshOnetime.Store.{Claim, Postgres, Result}
  alias AshOnetime.Test.{Migration, Repo}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :store
  @database_options [
    hostname: "127.0.0.1",
    port: 18_841,
    username: "postgres",
    password: "postgres",
    database: "ash_onetime_test"
  ]

  setup_all do
    installation = Migration.install_generated!()
    create_effect_ledger!(installation.schema)
    on_exit(fn -> Migration.uninstall_generated!(installation) end)
    {:ok, prefix: installation.schema}
  end

  @tag unique_constraint_mutation: true
  test "idempotency collision waits on the committed winner and appends one effect", %{
    prefix: prefix
  } do
    request = idempotency_request("idempotency-contention")
    assert_contention(prefix, request, :processing)
  end

  test "nonce collision waits on the committed winner and appends one effect", %{prefix: prefix} do
    request = nonce_request("nonce-contention")
    assert_contention(prefix, request, :collision)
  end

  test "a server lock timeout is sent and rolled back, never not-started", %{prefix: prefix} do
    request = idempotency_request("lock-timeout")
    observer = observer!()
    parent = self()

    winner_worker =
      spawn(fn -> winner_worker(parent, prefix, request, nil) end)

    loser_worker =
      spawn(fn -> timeout_worker(parent, prefix, request) end)

    send(winner_worker, :start)
    assert_receive {:winner_ready, ^winner_worker, _winner_backend}, 2_000
    send(loser_worker, :start)
    assert_receive {:loser_started, ^loser_worker, loser_backend}, 2_000
    observation = waiting_observation(observer, loser_backend)
    assert_waiting!(observation)

    assert_receive {:loser_done, ^loser_worker,
                    {:error,
                     %Result{
                       status: :failure,
                       reason: :lock_timeout,
                       admission_dispatch: :sent,
                       transaction: :rolled_back
                     }}},
                   2_000

    send(winner_worker, :release)
    assert_receive {:winner_done, ^winner_worker, {:ok, %Result{status: :admitted}}}, 2_000
  end

  test "terminating a blocked backend after dispatch returns unknown, never not-started", %{
    prefix: prefix
  } do
    request = idempotency_request("terminated-backend")
    observer = observer!()
    parent = self()
    winner_worker = spawn(fn -> winner_worker(parent, prefix, request, nil) end)
    loser_worker = spawn(fn -> terminated_worker(parent, prefix, request) end)

    send(winner_worker, :start)
    assert_receive {:winner_ready, ^winner_worker, _winner_backend}, 2_000
    send(loser_worker, :start)
    assert_receive {:loser_started, ^loser_worker, loser_backend}, 2_000
    assert_waiting!(waiting_observation(observer, loser_backend))

    assert %{rows: [[true]]} =
             Postgrex.query!(observer, "SELECT pg_terminate_backend($1)", [loser_backend])

    assert_receive {:store_result, ^loser_worker, store_result}, 2_000
    send(winner_worker, :release)
    assert_receive {:winner_done, ^winner_worker, {:ok, %Result{status: :admitted}}}, 2_000

    assert %Result{
             status: :failure,
             reason: :disconnected,
             admission_dispatch: :unknown,
             transaction: :unknown
           } = store_result
  end

  test "a committed cleanup between command one and command two permits exactly one retry", %{
    prefix: prefix
  } do
    request = idempotency_request("vanished-row-retry")
    old_id = Ecto.UUID.generate()
    insert_expired_conflict!(prefix, old_id, request)
    observer = observer!()
    parent = self()
    claimant = spawn(fn -> vanished_claim_worker(parent, prefix, request) end)

    assert_receive {:vanished_claim_backend, ^claimant, claimant_backend}, 2_000
    assert_receive {:command_one_conflict, ^claimant}, 2_000
    cleaner = spawn(fn -> cleanup_conflict_worker(parent, prefix, old_id) end)
    assert_receive {:cleanup_delete_ready, ^cleaner, cleaner_backend}, 2_000
    send(claimant, :continue_to_command_two)

    observation = waiting_observation(observer, claimant_backend)
    assert {blockers, query} = observation
    assert cleaner_backend in blockers
    assert query =~ "SELECT id, operation_hash"
    assert query =~ "FOR UPDATE"

    send(cleaner, :commit_cleanup)
    assert_receive {:cleanup_done, ^cleaner, {:ok, :deleted}}, 2_000

    assert_receive {:vanished_claim_done, ^claimant,
                    {:ok, %Result{status: :admitted, claim: claim}}},
                   2_000

    assert claim.id == request.id
    assert claim.id != old_id

    assert %{rows: [[1]]} =
             Postgrex.query!(
               observer,
               """
               SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")}
               WHERE operation_hash = $1 AND scope_hash = $2 AND key_hash = $3
               """,
               [request.operation_hash, request.scope_hash, request.key_hash]
             )
  end

  defp assert_contention(prefix, request, expected_loser_status) do
    observer = observer!()
    parent = self()
    loser_request = %{request | id: Ecto.UUID.generate()}

    winner_worker = spawn(fn -> winner_worker(parent, prefix, request, :ledger) end)
    loser_worker = spawn(fn -> loser_worker(parent, prefix, loser_request) end)
    send(winner_worker, :start)
    assert_receive {:winner_ready, ^winner_worker, winner_backend}, 2_000
    send(loser_worker, :start)
    assert_receive {:loser_started, ^loser_worker, loser_backend}, 2_000
    observation = waiting_observation(observer, loser_backend)

    send(winner_worker, :release)
    assert_receive {:winner_done, ^winner_worker, {:ok, %Result{status: :admitted}}}, 2_000

    assert_receive {:loser_done, ^loser_worker, {:ok, loser_result}}, 2_000
    assert ledger_count(observer, prefix, request) == 1
    assert_ledger_immutable!(observer, prefix, request)
    assert %Result{status: ^expected_loser_status, claim: authoritative} = loser_result

    assert_waiting!(observation, winner_backend)
    assert authoritative.operation_hash == request.operation_hash
  end

  defp winner_worker(parent, prefix, request, ledger?) do
    receive do
      :start -> :ok
    end

    result = with_owner(fn -> winner_transaction(parent, prefix, request, ledger?) end)

    send(parent, {:winner_done, self(), result})
  end

  defp winner_transaction(parent, prefix, request, ledger?) do
    Repo.transaction(fn ->
      backend = backend_pid!()
      result = Store.claim(Postgres.for_repo(Repo, prefix), request)
      assert_admitted!(result)
      if ledger?, do: append_effect!(prefix, request)
      send(parent, {:winner_ready, self(), backend})

      receive do
        :release -> result
      end
    end)
  end

  defp loser_worker(parent, prefix, request) do
    receive do
      :start -> :ok
    end

    result = with_owner(fn -> loser_transaction(parent, prefix, request) end)

    send(parent, {:loser_done, self(), result})
  end

  defp loser_transaction(parent, prefix, request) do
    Repo.transaction(fn ->
      send(parent, {:loser_started, self(), backend_pid!()})
      result = Store.claim(Postgres.for_repo(Repo, prefix), request)
      if result.status == :admitted, do: append_effect!(prefix, request)
      result
    end)
  end

  defp timeout_worker(parent, prefix, request) do
    receive do
      :start -> :ok
    end

    result = with_owner(fn -> timeout_transaction(parent, prefix, request) end)

    send(parent, {:loser_done, self(), result})
  end

  defp timeout_transaction(parent, prefix, request) do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SET LOCAL lock_timeout = '250ms'", [])
      send(parent, {:loser_started, self(), backend_pid!()})

      case Store.claim(Postgres.for_repo(Repo, prefix), request) do
        %Result{status: :failure} = failure -> Repo.rollback(failure)
        other -> other
      end
    end)
  end

  defp terminated_worker(parent, prefix, request) do
    receive do
      :start -> :ok
    end

    with_owner(fn ->
      _result =
        Repo.transaction(fn ->
          send(parent, {:loser_started, self(), backend_pid!()})
          result = Store.claim(Postgres.for_repo(Repo, prefix), request)
          send(parent, {:store_result, self(), result})
          result
        end)
    end)
  end

  defp vanished_claim_worker(parent, prefix, request) do
    worker = self()
    handler_id = {__MODULE__, :vanished_claim, worker, make_ref()}
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, {notify, claimant} ->
          if self() == claimant and command_one_conflict?(metadata) do
            send(notify, {:command_one_conflict, claimant})

            receive do
              :continue_to_command_two -> :ok
            end
          end
        end,
        {parent, worker}
      )

    result =
      try do
        with_owner(fn ->
          Repo.transaction(fn ->
            send(parent, {:vanished_claim_backend, self(), backend_pid!()})
            Store.claim(Postgres.for_repo(Repo, prefix), request)
          end)
        end)
      after
        :telemetry.detach(handler_id)
      end

    send(parent, {:vanished_claim_done, self(), result})
  end

  defp cleanup_conflict_worker(parent, prefix, old_id) do
    result =
      with_owner(fn ->
        Repo.transaction(fn ->
          backend = backend_pid!()

          %{num_rows: 1} =
            SQL.query!(
              Repo,
              "DELETE FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
              [Ecto.UUID.dump!(old_id)]
            )

          send(parent, {:cleanup_delete_ready, self(), backend})

          receive do
            :commit_cleanup -> :deleted
          end
        end)
      end)

    send(parent, {:cleanup_done, self(), result})
  end

  defp command_one_conflict?(%{query: query, result: {:ok, %{num_rows: 0}}}) do
    query =~ "INSERT INTO" and query =~ "ash_onetime_idempotency_claims"
  end

  defp command_one_conflict?(_metadata), do: false

  defp observer! do
    {:ok, observer} = Postgrex.start_link(@database_options)
    Process.unlink(observer)

    on_exit(fn ->
      if Process.alive?(observer), do: GenServer.stop(observer, :normal, 5_000)
    end)

    observer
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

  defp waiting_observation(observer, loser_backend) do
    Enum.reduce_while(1..200, nil, fn _attempt, _last ->
      %{rows: rows} =
        Postgrex.query!(
          observer,
          "SELECT pg_blocking_pids(pid), query FROM pg_stat_activity WHERE pid = $1",
          [loser_backend]
        )

      case rows do
        [[blockers, query]] when blockers != [] ->
          {:halt, {blockers, query}}

        _other ->
          Process.sleep(5)
          {:cont, nil}
      end
    end)
  end

  defp assert_waiting!(observation, expected_blocker \\ nil) do
    assert {blockers, query} = observation
    assert query =~ "INSERT INTO"
    assert query =~ "ash_onetime_"
    if expected_blocker, do: assert(expected_blocker in blockers)
  end

  defp ledger_count(observer, prefix, request) do
    %{rows: [[count]]} =
      Postgrex.query!(
        observer,
        """
        SELECT count(*) FROM #{relation(prefix, "ash_onetime_effect_ledger")}
        WHERE operation_hash = $1 AND scope_hash = $2 AND key_hash = $3
        """,
        [request.operation_hash, request.scope_hash, request.key_hash]
      )

    count
  end

  defp assert_ledger_immutable!(observer, prefix, request) do
    parameters = [request.operation_hash, request.scope_hash, request.key_hash]

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Postgrex.query(
               observer,
               """
               UPDATE #{relation(prefix, "ash_onetime_effect_ledger")}
               SET strategy = 'tampered'
               WHERE operation_hash = $1 AND scope_hash = $2 AND key_hash = $3
               """,
               parameters
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Postgrex.query(
               observer,
               """
               DELETE FROM #{relation(prefix, "ash_onetime_effect_ledger")}
               WHERE operation_hash = $1 AND scope_hash = $2 AND key_hash = $3
               """,
               parameters
             )
  end

  defp append_effect!(prefix, request) do
    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_effect_ledger")}
        (strategy, operation_hash, scope_hash, key_hash)
      VALUES ($1, $2, $3, $4)
      """,
      [
        Atom.to_string(request.strategy),
        request.operation_hash,
        request.scope_hash,
        request.key_hash
      ]
    )
  end

  defp backend_pid! do
    %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp assert_admitted!(%Result{status: :admitted}), do: :ok
  defp assert_admitted!(other), do: raise("winner was not admitted: #{inspect(other)}")

  defp create_effect_ledger!(prefix) do
    Sandbox.mode(Repo, :auto)

    try do
      SQL.query!(
        Repo,
        """
        CREATE TABLE #{relation(prefix, "ash_onetime_effect_ledger")} (
          event_id bigserial NOT NULL,
          strategy text NOT NULL,
          operation_hash bytea NOT NULL,
          scope_hash bytea NOT NULL,
          key_hash bytea NOT NULL
        )
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE FUNCTION #{relation(prefix, "ash_onetime_guard_effect_ledger")}()
        RETURNS trigger LANGUAGE plpgsql AS $guard$
        BEGIN
          RAISE EXCEPTION 'effect ledger is append-only' USING ERRCODE = '23514';
        END
        $guard$
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TRIGGER ash_onetime_effect_ledger_immutable
        BEFORE UPDATE OR DELETE ON #{relation(prefix, "ash_onetime_effect_ledger")}
        FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "ash_onetime_guard_effect_ledger")}()
        """,
        []
      )
    after
      Sandbox.mode(Repo, :manual)
    end
  end

  defp insert_expired_conflict!(prefix, old_id, request) do
    with_owner(fn ->
      Repo.transaction(fn ->
        SQL.query!(
          Repo,
          """
          INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
            (id, operation_hash, scope_hash, key_hash, fingerprint, state,
             admitted_at, retain_until, inserted_at)
          VALUES ($1::uuid, $2, $3, $4, $5, 'processing',
                  transaction_timestamp() - interval '2 hours',
                  transaction_timestamp() - interval '1 hour',
                  transaction_timestamp() - interval '2 hours')
          """,
          [
            Ecto.UUID.dump!(old_id),
            request.operation_hash,
            request.scope_hash,
            request.key_hash,
            request.fingerprint
          ]
        )
      end)
    end)
  end

  defp idempotency_request(label) do
    {:ok, request} =
      Claim.idempotency(
        operation_hash: hash("operation:" <> label),
        scope_hash: hash("scope:" <> label),
        key_hash: hash("key:" <> label),
        fingerprint: hash("fingerprint:" <> label),
        retention_seconds: 3_600
      )

    request
  end

  defp nonce_request(label) do
    now = DateTime.utc_now()

    verified = %AshOnetime.Verified{
      key: "nonce:" <> label,
      issued_at: now,
      verifier_id: "contention-verifier"
    }

    {:ok, request} =
      Claim.nonce(
        operation_hash: hash("operation:" <> label),
        scope_hash: hash("scope:" <> label),
        key_hash: hash("key:" <> label),
        verified: [verified],
        max_age: 60,
        clock_skew: 1
      )

    request
  end

  defp hash(value), do: :crypto.hash(:sha256, value)
  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
