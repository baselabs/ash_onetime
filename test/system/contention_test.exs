defmodule AshOnetime.System.ContentionTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.{Migration, Repo}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup_all do
    installation = Migration.install_generated!()
    barrier = :erlang.phash2(installation.schema, 2_000_000_000)
    install_effect_tables!(installation.schema, barrier)
    on_exit(fn -> Migration.uninstall_generated!(installation) end)
    {:ok, prefix: installation.schema, barrier: barrier}
  end

  @tag unique_constraint_mutation: true
  test "a contended real action commits one append-only effect", %{
    prefix: prefix,
    barrier: barrier
  } do
    observer = observer!()
    claims_before = count(observer, prefix, "ash_onetime_idempotency_claims")
    Postgrex.query!(observer, "BEGIN", [])
    Postgrex.query!(observer, "SELECT pg_advisory_xact_lock($1)", [barrier])

    input = %{
      account_id: Ecto.UUID.generate(),
      amount: 10,
      request_key: "system-contention",
      natural_key: "system-natural",
      external_key: "system-external"
    }

    parent = self()
    first = spawn(fn -> run_charge(parent, :first, prefix, input) end)
    refute_receive {:charge_done, :first, ^first, _result}, 100
    second = spawn(fn -> run_charge(parent, :second, prefix, input) end)
    refute_receive {:charge_done, :second, ^second, _result}, 100

    assert count(observer, prefix, "ash_onetime_system_effects") == 0
    Postgrex.query!(observer, "COMMIT", [])

    assert_receive {:charge_done, :first, ^first, {:ok, first_result}}, 5_000
    assert_receive {:charge_done, :second, ^second, {:ok, second_result}}, 5_000
    assert first_result.id == second_result.id
    assert count(observer, prefix, "ash_onetime_system_effects") == 1
    assert count(observer, prefix, "ash_onetime_idempotency_claims") == claims_before + 1

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Postgrex.query(
               observer,
               "DELETE FROM #{relation(prefix, "ash_onetime_system_effects")}",
               []
             )
  end

  @tag action_replay_mutation: true
  test "typed replay and action and scope namespaces remain independent", %{prefix: prefix} do
    owner = Sandbox.start_owner!(Repo, shared: false, sandbox: false)
    on_exit(fn -> if Process.alive?(owner), do: Sandbox.stop_owner(owner) end)
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :observer}, self())
    on_exit(fn -> Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :observer}) end)
    claims_before = table_count(prefix, "ash_onetime_idempotency_claims")

    base = %{value: 42, request_key: "system-namespace"}

    assert {:ok, 42} = run_generic(prefix, :redeem, base)
    assert {:ok, 42} = run_generic(prefix, :redeem, base)
    assert {:ok, 42} = run_generic(prefix, :redeem_other, base)
    assert {:ok, 42} = run_generic(prefix, :scoped_redeem, Map.put(base, :scope_key, "a"))
    assert {:ok, 42} = run_generic(prefix, :scoped_redeem, Map.put(base, :scope_key, "b"))

    assert_receive {:generic_run, _}
    assert_receive {:generic_run, _}
    assert_receive {:generic_run, _}
    assert_receive {:generic_run, _}
    refute_receive {:generic_run, _}
    assert table_count(prefix, "ash_onetime_idempotency_claims") == claims_before + 4
  end

  defp run_charge(parent, label, prefix, input) do
    owner = Sandbox.start_owner!(Repo, shared: false, sandbox: false)

    result =
      Resource
      |> Ash.Changeset.for_create(:charge, input)
      |> Ash.Changeset.set_tenant(prefix)
      |> Ash.create()

    Sandbox.stop_owner(owner)
    send(parent, {:charge_done, label, self(), result})
  end

  defp run_generic(prefix, action, arguments) do
    Resource
    |> Ash.ActionInput.for_action(action, arguments)
    |> Ash.ActionInput.set_tenant(prefix)
    |> Ash.run_action()
  end

  defp observer! do
    options =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_options])

    {:ok, observer} = Postgrex.start_link(options)
    Process.unlink(observer)
    on_exit(fn -> stop_observer(observer) end)
    observer
  end

  defp stop_observer(observer) do
    if Process.alive?(observer) do
      monitor = Process.monitor(observer)
      Process.exit(observer, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^observer, _reason} -> :ok
      after
        5_000 -> raise "system observer did not stop"
      end
    end
  end

  defp count(connection, prefix, table) do
    %{rows: [[count]]} =
      Postgrex.query!(connection, "SELECT count(*) FROM #{relation(prefix, table)}", [])

    count
  end

  defp table_count(prefix, table) do
    %{rows: [[count]]} = SQL.query!(Repo, "SELECT count(*) FROM #{relation(prefix, table)}", [])
    count
  end

  defp install_effect_tables!(prefix, barrier) do
    Sandbox.mode(Repo, :auto)

    try do
      SQL.query!(
        Repo,
        """
        CREATE TABLE #{relation(prefix, "ash_onetime_action_examples")} (
          id uuid PRIMARY KEY, account_id uuid NOT NULL, amount bigint NOT NULL
        )
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TABLE #{relation(prefix, "ash_onetime_system_effects")} (
          event_id bigserial NOT NULL, record_id uuid NOT NULL
        )
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE FUNCTION #{relation(prefix, "guard_system_effects")}()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'append only' USING ERRCODE = '23514'; END
        $$
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TRIGGER system_effects_immutable
        BEFORE UPDATE OR DELETE ON #{relation(prefix, "ash_onetime_system_effects")}
        FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "guard_system_effects")}()
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE FUNCTION #{relation(prefix, "record_system_effect")}()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          PERFORM pg_advisory_xact_lock(#{barrier});
          INSERT INTO #{relation(prefix, "ash_onetime_system_effects")} (record_id) VALUES (NEW.id);
          RETURN NEW;
        END
        $$
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TRIGGER record_system_effect
        BEFORE INSERT ON #{relation(prefix, "ash_onetime_action_examples")}
        FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "record_system_effect")}()
        """,
        []
      )
    after
      Sandbox.mode(Repo, :manual)
    end
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
