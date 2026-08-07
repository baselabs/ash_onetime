defmodule AshOnetime.ReplayMetadataTest do
  @moduledoc """
  ARCH-2 — caller-visible replayed-vs-fresh signal.

  A protected action's result carries `__metadata__[:ash_onetime][:replayed]` so a caller
  can distinguish a fresh execution (201) from a stored replay (200 + Idempotent-Replayed)
  AFTER `Ash.create/2` / `Ash.run_action/2` returns. The signal is tri-state:

    true  — tracked replay (stored result returned)
    false — tracked fresh execution
    nil   — carrier absent (:untracked execution, OR primitive-return action, OR unprotected)

  `:untracked` executions carry NO `:ash_onetime` metadata (preserving ADR 0001's
  untracked-transparency goal), so `replayed?/1` returns `nil` there — indistinguishable
  from a primitive return.
  """
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Store.Result
  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.FaultStore
  alias Ecto.Adapters.SQL

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS #{relation(prefix, "ash_onetime_action_examples")} (
        id uuid PRIMARY KEY,
        account_id uuid NOT NULL,
        amount bigint NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE TABLE IF NOT EXISTS #{relation(prefix, "ash_onetime_generic_effect_ledger")} (value bigint NOT NULL)",
      []
    )

    :ok
  end

  defp charge_input(account_id, amount, key) do
    %{
      account_id: account_id,
      amount: amount,
      request_key: key,
      natural_key: "natural-#{key}",
      external_key: "external-#{key}"
    }
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")

  describe "resource create (idempotency, record return)" do
    @tag :replay_metadata_mutation
    test "fresh create stamps replayed: false; retry stamps replayed: true", %{prefix: prefix} do
      input =
        charge_input(
          Ecto.UUID.generate(),
          10,
          "replay-signal-#{System.unique_integer([:positive])}"
        )

      assert {:ok, fresh} =
               Resource
               |> Ash.Changeset.for_create(:charge, input)
               |> Ash.Changeset.set_tenant(prefix)
               |> Ash.create()

      assert {:ok, replayed} =
               Resource
               |> Ash.Changeset.for_create(:charge, input)
               |> Ash.Changeset.set_tenant(prefix)
               |> Ash.create()

      assert replayed.id == fresh.id

      # RED today: no :ash_onetime metadata is ever stamped.
      # GREEN: fresh execution -> replayed == false; retry (replay) -> replayed == true.
      assert AshOnetime.replayed?(fresh) == false
      assert AshOnetime.replayed?(replayed) == true

      assert fresh.__metadata__[:ash_onetime][:replayed] == false
      assert replayed.__metadata__[:ash_onetime][:replayed] == true
    end
  end

  describe "generic action (idempotency, primitive integer return)" do
    @tag :replay_metadata_primitive_mutation
    test "primitive-return replay yields replayed? nil (no metadata carrier)", %{prefix: prefix} do
      key = "generic-replay-#{System.unique_integer([:positive])}"

      assert {:ok, 42} =
               Resource
               |> Ash.ActionInput.for_action(:redeem, %{value: 42, request_key: key})
               |> Ash.ActionInput.set_tenant(prefix)
               |> Ash.run_action()

      assert {:ok, 42} =
               Resource
               |> Ash.ActionInput.for_action(:redeem, %{value: 42, request_key: key})
               |> Ash.ActionInput.set_tenant(prefix)
               |> Ash.run_action()

      # The result is a bare integer (no __metadata__), so replayed?/1 returns nil — NOT a
      # silent false. The caller can tell "I cannot observe replay on this primitive return"
      # (nil) apart from "this was a tracked fresh execution" (false). (Reconciled C3.)
      assert AshOnetime.replayed?(42) == nil
    end
  end

  describe "replayed?/1 on unprotected / non-record values" do
    test "returns nil for atoms, tuples, and records without the metadata" do
      assert AshOnetime.replayed?(:ok) == nil
      assert AshOnetime.replayed?({:ok, 1}) == nil
      assert AshOnetime.replayed?(nil) == nil
    end
  end

  describe ":untracked transparency (ADR 0001)" do
    @tag :untracked_transparency_mutation
    test "an untracked execution carries no :ash_onetime metadata (replayed? nil)" do
      # The :untracked admission class must be observationally indistinguishable from an
      # unprotected action (ADR 0001 "Failure and safe cleanup"). stamp_replay/2 therefore
      # does NOT stamp :untracked results — a record returned from an untracked execution
      # carries no :ash_onetime metadata, so replayed?/1 reports nil.
      record_with_metadata = %{
        __struct__: AshOnetime.Test.ActionExamples.Resource,
        __metadata__: %{},
        id: Ecto.UUID.generate()
      }

      untracked_state = %AshOnetime.Admission.State{
        class: :untracked,
        strategy: :idempotency,
        resource: AshOnetime.Test.ActionExamples.Resource,
        action: :charge
      }

      stamped = AshOnetime.Admission.stamp_replay(untracked_state, record_with_metadata)

      # The record is unchanged — no :ash_onetime key stamped.
      assert stamped.__metadata__ == %{}
      assert AshOnetime.replayed?(stamped) == nil
    end

    @tag :untracked_transparency_mutation
    test "a tracked fresh execution stamps replayed: false (contrast with untracked)" do
      record_with_metadata = %{
        __struct__: AshOnetime.Test.ActionExamples.Resource,
        __metadata__: %{},
        id: Ecto.UUID.generate()
      }

      execute_state = %AshOnetime.Admission.State{
        class: :execute,
        strategy: :idempotency,
        resource: AshOnetime.Test.ActionExamples.Resource,
        action: :charge
      }

      stamped = AshOnetime.Admission.stamp_replay(execute_state, record_with_metadata)

      assert stamped.__metadata__[:ash_onetime][:replayed] == false
      assert AshOnetime.replayed?(stamped) == false
    end
  end

  describe ":execute_untracked end-to-end (ADR 0001 transparency + telemetry)" do
    setup do
      # Drive the whole Ash pipeline against a store that reports a definite, no-dispatch
      # checkout failure, so a :charge_untracked create actually takes the :execute_untracked
      # branch — not a direct stamp_replay/2 call.
      AshOnetime.Admission.put_test_store(FaultStore)

      FaultStore.put_result(Result.failure(:checkout_unavailable, :not_started, :not_applicable))

      parent = self()
      handler_id = {__MODULE__, :untracked_telemetry}

      :telemetry.attach(
        handler_id,
        [:ash_onetime, :untracked_execution],
        fn _event, measurements, metadata, _config ->
          send(parent, {:untracked_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        FaultStore.reset()
        AshOnetime.Admission.reset_test_store()
      end)

      :ok
    end

    @tag :untracked_transparency_mutation
    test "a definite checkout failure runs the effect untracked, stamps no metadata, and emits telemetry",
         %{prefix: prefix} do
      account_id = Ecto.UUID.generate()
      key = "untracked-e2e-#{System.unique_integer([:positive])}"

      assert {:ok, record} =
               Resource
               |> Ash.Changeset.for_create(:charge_untracked, charge_input(account_id, 7, key))
               |> Ash.Changeset.set_tenant(prefix)
               |> Ash.create()

      # The effect executed: the record landed in the real data layer even though the
      # authoritative store was unavailable — the untracked branch proceeds.
      assert record.account_id == account_id
      assert record.amount == 7

      assert %{rows: [[1]]} =
               SQL.query!(
                 Repo,
                 "SELECT count(*) FROM \"#{prefix}\".\"ash_onetime_action_examples\" WHERE id = $1",
                 [Ecto.UUID.dump!(record.id)]
               )

      # Untracked transparency (ADR 0001): observationally indistinguishable from an
      # unprotected action — NO :ash_onetime metadata, so replayed?/1 is nil, not false.
      assert AshOnetime.replayed?(record) == nil
      refute Map.has_key?(record.__metadata__, :ash_onetime)

      # ...but the condition is surfaced through value-free telemetry (AGENTS.md boundary).
      assert_receive {:untracked_telemetry, %{count: 1}, metadata}
      assert metadata.strategy == :idempotency
      assert metadata.resource == Resource
      assert metadata.action == :charge_untracked
      assert metadata.result_class == :checkout_unavailable
    end
  end
end
