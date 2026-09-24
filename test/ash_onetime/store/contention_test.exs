defmodule AshOnetime.Store.ContentionTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Store
  alias AshOnetime.Store.{Claim, Postgres, Result}
  alias AshOnetime.Test.{ExternalPeer, Migration, RealConnection, Repo}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :store

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

  test "an expired processing claim remains authoritative and cannot be deleted", %{
    prefix: prefix
  } do
    request = idempotency_request("processing-recovery-point")
    old_id = Ecto.UUID.generate()
    insert_expired_conflict!(prefix, old_id, request)
    observer = observer!()

    assert {:ok, %Result{status: :processing, claim: claim}} =
             RealConnection.with_connection(fn ->
               Repo.transaction(fn -> Store.claim(Postgres.for_repo(Repo, prefix), request) end)
             end)

    assert claim.id == old_id

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Postgrex.query(
               observer,
               "DELETE FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE operation_hash = $1 AND id = $2::uuid",
               [request.operation_hash, Ecto.UUID.dump!(old_id)]
             )

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

    result =
      RealConnection.with_connection(fn ->
        winner_transaction(parent, prefix, request, ledger?)
      end)

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

    result = RealConnection.with_connection(fn -> loser_transaction(parent, prefix, request) end)

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

    result =
      RealConnection.with_connection(fn -> timeout_transaction(parent, prefix, request) end)

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

    RealConnection.with_connection(fn ->
      _result =
        Repo.transaction(fn ->
          send(parent, {:loser_started, self(), backend_pid!()})
          result = Store.claim(Postgres.for_repo(Repo, prefix), request)
          send(parent, {:store_result, self(), result})
          result
        end)
    end)
  end

  defp observer! do
    {:ok, observer} = Postgrex.start_link(ExternalPeer.database_options())
    Process.unlink(observer)

    on_exit(fn ->
      if Process.alive?(observer), do: GenServer.stop(observer, :normal, 5_000)
    end)

    observer
  end

  defp waiting_observation(observer, loser_backend) do
    # ~10s deadline: generous for a loaded CI runner; halts as soon as the wait is observed.
    Enum.reduce_while(1..2_000, nil, fn _attempt, _last ->
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
    RealConnection.with_connection(fn ->
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
  # ADR-0010 pre-peer claim lock: store-level behavior against a foreign row holder and
  # against a row whose id no longer matches the logical key (reaped-and-reinserted shape).
  # The contended shape mirrors production: the row is COMMITTED (processing) and its lock
  # is held by another caller's open transaction — a FOR UPDATE select does not block on an
  # uncommitted insert, it misses it.
  test "lock_for_effect times out against a foreign row holder and reports lock_timeout", %{
    prefix: prefix
  } do
    request = idempotency_request("effect-lock-timeout")
    target = Postgres.for_repo(Repo, prefix)
    parent = self()

    assert_admitted_worker!(parent, prefix, request)

    holder =
      spawn(fn ->
        result =
          RealConnection.with_connection(fn ->
            Repo.transaction(fn ->
              claim = claim_from_request(request, prefix)

              case Store.lock_for_effect(target, claim, lock_timeout_ms: 250) do
                %Result{status: :failure} = failure ->
                  Repo.rollback(failure)

                locked ->
                  send(parent, {:holder_ready, self()})
                  receive do: (:release -> locked)
              end
            end)
          end)

        send(parent, {:holder_done, self(), result})
      end)

    assert_receive {:holder_ready, ^holder}, 5_000

    loser =
      spawn(fn ->
        result =
          RealConnection.with_connection(fn ->
            Repo.transaction(fn ->
              claim = claim_from_request(request, prefix)

              case Store.lock_for_effect(target, claim, lock_timeout_ms: 250) do
                %Result{status: :failure} = failure -> Repo.rollback(failure)
                other -> other
              end
            end)
          end)

        send(parent, {:lock_done, self(), result})
      end)

    assert_receive {:lock_done, ^loser,
                    {:error,
                     %Result{
                       status: :failure,
                       reason: :lock_timeout,
                       admission_dispatch: :sent,
                       transaction: :rolled_back
                     }}},
                   5_000

    send(holder, :release)
    assert_receive {:holder_done, ^holder, {:ok, %Result{status: :processing}}}, 5_000
  end

  @tag effect_lock_generation_mutation: true
  test "lock_for_effect refuses a row whose id no longer matches the logical key", %{
    prefix: prefix
  } do
    request = idempotency_request("effect-lock-generation")
    target = Postgres.for_repo(Repo, prefix)
    parent = self()

    assert_admitted_worker!(parent, prefix, request)

    # Same logical key, a different claim id: the shape of a row reaped and re-inserted
    # between the committed claim and the lock. The id bind makes the lock miss (fail
    # closed) instead of adopting another generation's claim.
    stranger = %{claim_from_request(request, prefix) | id: Ecto.UUID.generate()}

    stranger_result =
      RealConnection.with_connection(fn ->
        Repo.transaction(fn ->
          case Store.lock_for_effect(target, stranger, lock_timeout_ms: 250) do
            %Result{status: :failure} = failure -> Repo.rollback(failure)
            other -> other
          end
        end)
      end)

    assert {:error,
            %Result{
              status: :failure,
              reason: :store_invariant,
              admission_dispatch: :sent,
              transaction: :open
            }} = stranger_result
  end

  defp assert_admitted_worker!(parent, prefix, request) do
    worker = spawn(fn -> admit_committed(parent, prefix, request) end)
    assert_receive {:admitted, ^worker, {:ok, %Result{status: :admitted}}}, 5_000
  end

  defp admit_committed(parent, prefix, request) do
    result = RealConnection.with_connection(fn -> admit_transaction(prefix, request) end)
    send(parent, {:admitted, self(), result})
  end

  defp admit_transaction(prefix, request) do
    Repo.transaction(fn ->
      case Store.claim(Postgres.for_repo(Repo, prefix), request) do
        %Result{status: :admitted} = admitted -> admitted
        %Result{} = failure -> Repo.rollback(failure)
      end
    end)
  end

  defp claim_from_request(request, prefix) do
    now = DateTime.utc_now()

    %Claim{
      strategy: :idempotency,
      id: request.id,
      logical_partition: Postgres.for_repo(Repo, prefix).logical_partition,
      operation_hash: request.operation_hash,
      scope_hash: request.scope_hash,
      key_hash: request.key_hash,
      fingerprint: request.fingerprint,
      state: :processing,
      admitted_at: now,
      retain_until: DateTime.add(now, request.retention_seconds, :second),
      inserted_at: now
    }
  end
end
