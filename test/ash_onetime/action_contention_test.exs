defmodule AshOnetime.ActionContentionTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.{Migration, Repo}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @database_options [
    hostname: "127.0.0.1",
    port: 18_841,
    username: "postgres",
    password: "postgres",
    database: "ash_onetime_test"
  ]

  setup_all do
    installation = Migration.install_generated!()
    barrier_key = :erlang.phash2(installation.schema, 2_000_000_000)
    install_action_tables!(installation.schema, barrier_key)
    on_exit(fn -> Migration.uninstall_generated!(installation) end)
    {:ok, prefix: installation.schema, barrier_key: barrier_key}
  end

  @tag ledger_tamper_mutation: true
  test "two protected Ash actions serialize at the authoritative claim and append one effect", %{
    prefix: prefix,
    barrier_key: barrier_key
  } do
    observer = observer!()
    Postgrex.query!(observer, "BEGIN", [])
    Postgrex.query!(observer, "SELECT pg_advisory_xact_lock($1)", [barrier_key])
    %{rows: [[observer_pid]]} = Postgrex.query!(observer, "SELECT pg_backend_pid()", [])

    input = %{
      account_id: Ecto.UUID.generate(),
      amount: 10,
      request_key: "contended",
      natural_key: "natural-contended",
      external_key: "external-contended"
    }

    parent = self()
    winner = spawn(fn -> action_worker(parent, :winner, prefix, input) end)
    refute_receive {:action_done, :winner, ^winner, _early_result}, 100

    winner_wait = wait_for_blocked_query(observer, observer_pid)
    assert {winner_pid, winner_blockers, winner_query} = winner_wait
    assert observer_pid in winner_blockers
    assert is_binary(winner_query)

    loser = spawn(fn -> action_worker(parent, :loser, prefix, input) end)
    loser_wait = wait_for_blocked_query(observer, winner_pid, winner_pid)
    assert {loser_pid, loser_blockers, loser_query} = loser_wait
    assert winner_pid in loser_blockers
    assert loser_pid != winner_pid
    assert is_binary(loser_query)
    assert count(observer, prefix, "ash_onetime_action_effect_ledger") == 0

    Postgrex.query!(observer, "COMMIT", [])

    assert_receive {:action_done, :winner, ^winner, {:ok, winner_result}}, 5_000
    assert_receive {:action_done, :loser, ^loser, {:ok, loser_result}}, 5_000
    assert loser_result.id == winner_result.id
    assert loser_result.account_id == winner_result.account_id
    assert loser_result.amount == winner_result.amount

    assert count(observer, prefix, "ash_onetime_action_examples") == 1
    assert count(observer, prefix, "ash_onetime_action_effect_ledger") == 1
    assert count(observer, prefix, "ash_onetime_idempotency_claims") == 1
    assert count(observer, prefix, "ash_onetime_response_payloads") == 1

    assert_append_only!(observer, prefix)
  end

  defp action_worker(parent, label, prefix, input) do
    result =
      with_owner(fn ->
        Resource
        |> Ash.Changeset.for_create(:charge, input)
        |> Ash.Changeset.set_tenant(prefix)
        |> Ash.create()
      end)

    send(parent, {:action_done, label, self(), result})
  end

  defp wait_for_blocked_query(observer, expected_blocker, excluded_pid \\ nil) do
    # ~10s deadline: generous for a loaded CI runner; halts as soon as the wait is observed.
    Enum.reduce_while(1..2_000, nil, fn _attempt, _last ->
      case blocked_query(observer, expected_blocker, excluded_pid) do
        [pid, blockers, query] ->
          {:halt, {pid, blockers, query}}

        nil ->
          Process.sleep(5)
          {:cont, nil}
      end
    end)
  end

  defp blocked_query(observer, expected_blocker, excluded_pid) do
    %{rows: rows} =
      Postgrex.query!(
        observer,
        """
        SELECT pid, pg_blocking_pids(pid), query
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND pid <> pg_backend_pid()
          AND wait_event_type = 'Lock'
        ORDER BY pid
        """,
        []
      )

    Enum.find(rows, fn [pid, blockers, _query] ->
      expected_blocker in blockers and pid != excluded_pid
    end)
  end

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
      if Process.alive?(owner), do: Sandbox.stop_owner(owner)
    end
  end

  defp count(observer, prefix, table) do
    %{rows: [[count]]} =
      Postgrex.query!(observer, "SELECT count(*) FROM #{relation(prefix, table)}", [])

    count
  end

  defp assert_append_only!(observer, prefix) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Postgrex.query(
               observer,
               "UPDATE #{relation(prefix, "ash_onetime_action_effect_ledger")} SET record_id = record_id",
               []
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Postgrex.query(
               observer,
               "DELETE FROM #{relation(prefix, "ash_onetime_action_effect_ledger")}",
               []
             )
  end

  defp install_action_tables!(prefix, barrier_key) do
    Sandbox.mode(Repo, :auto)

    try do
      SQL.query!(
        Repo,
        """
        CREATE TABLE #{relation(prefix, "ash_onetime_action_examples")} (
          id uuid PRIMARY KEY,
          account_id uuid NOT NULL,
          amount bigint NOT NULL
        )
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TABLE #{relation(prefix, "ash_onetime_action_effect_ledger")} (
          event_id bigserial NOT NULL,
          record_id uuid NOT NULL,
          backend_pid integer NOT NULL,
          transaction_id bigint NOT NULL
        )
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE FUNCTION #{relation(prefix, "guard_action_effect_ledger")}()
        RETURNS trigger LANGUAGE plpgsql AS $guard$
        BEGIN
          RAISE EXCEPTION 'action effect ledger is append-only' USING ERRCODE = '23514';
        END
        $guard$
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TRIGGER action_effect_ledger_immutable
        BEFORE UPDATE OR DELETE ON #{relation(prefix, "ash_onetime_action_effect_ledger")}
        FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "guard_action_effect_ledger")}()
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE FUNCTION #{relation(prefix, "barrier_and_record_action_effect")}()
        RETURNS trigger LANGUAGE plpgsql AS $barrier$
        BEGIN
          PERFORM pg_advisory_xact_lock(#{barrier_key});
          INSERT INTO #{relation(prefix, "ash_onetime_action_effect_ledger")}
            (record_id, backend_pid, transaction_id)
          VALUES (NEW.id, pg_backend_pid(), txid_current());
          RETURN NEW;
        END
        $barrier$
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TRIGGER barrier_and_record_action_effect
        BEFORE INSERT ON #{relation(prefix, "ash_onetime_action_examples")}
        FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "barrier_and_record_action_effect")}()
        """,
        []
      )
    after
      Sandbox.mode(Repo, :manual)
    end
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
