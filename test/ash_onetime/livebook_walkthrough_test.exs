defmodule AshOnetime.LivebookWalkthroughTest do
  @moduledoc """
  Pins the runnable code shape shared by the per-concern Livebook notebooks
  (documentation/livebooks/{idempotency,nonces,external-recovery}.livemd).

  The consumer modules live in `test/support/livebook_examples.ex` (mirroring the livebook).
  This test installs the store via the same render/2 path the livebook documents, then asserts
  every livebook cell: fresh idempotent execution, replay, fingerprint conflict, one-time nonce
  spend, nonce reuse rejection, and telemetry emission.

  If the livebook's code stops running, this test fails — a non-running livebook is worse than
  none, so the walkthrough is regression-protected.
  """

  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.LivebookExamples.Charge
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS "#{prefix}"."demo_charges" (
        id uuid PRIMARY KEY,
        account_id uuid NOT NULL,
        amount bigint NOT NULL
      )
      """,
      []
    )

    :ok
  end

  describe "idempotency (livebook Part 1)" do
    test "fresh execution stamps replayed?: false", %{prefix: prefix} do
      account_id = "00000000-0000-0000-0000-000000000001"

      assert {:ok, fresh} =
               charge(prefix, %{
                 account_id: account_id,
                 amount: 10,
                 idempotency_key: "key-1"
               })

      assert fresh.amount == 10
      assert AshOnetime.replayed?(fresh) == false
    end

    test "retry with the same key replays the stored result", %{prefix: prefix} do
      account_id = "00000000-0000-0000-0000-000000000001"
      input = %{account_id: account_id, amount: 10, idempotency_key: "key-1"}

      assert {:ok, first} = charge(prefix, input)
      assert {:ok, replayed} = charge(prefix, input)

      assert replayed.id == first.id
      assert AshOnetime.replayed?(replayed) == true
      assert table_count(prefix, "demo_charges") == 1
    end

    test "same key with a changed amount is a terminal conflict", %{prefix: prefix} do
      account_id = "00000000-0000-0000-0000-000000000001"

      assert {:ok, _} =
               charge(prefix, %{account_id: account_id, amount: 10, idempotency_key: "conflict"})

      assert {:error, error} =
               charge(prefix, %{account_id: account_id, amount: 99, idempotency_key: "conflict"})

      assert AshOnetime.Error.code(error) == :key_reused_with_different_request
      assert table_count(prefix, "demo_charges") == 1
    end
  end

  describe "one-time nonce (livebook Part 2)" do
    test "a verified proof admits one spend then rejects reuse", %{prefix: prefix} do
      assert {:ok, 7} =
               Charge
               |> Ash.ActionInput.for_action(:redeem, %{value: 7, proof: "proof-once"})
               |> Ash.ActionInput.set_tenant(prefix)
               |> Ash.run_action()

      assert {:error, error} =
               Charge
               |> Ash.ActionInput.for_action(:redeem, %{value: 7, proof: "proof-once"})
               |> Ash.ActionInput.set_tenant(prefix)
               |> Ash.run_action()

      assert AshOnetime.Error.code(error) == :nonce_already_used
    end
  end

  describe "telemetry (livebook Part 3)" do
    test "admissions and conflicts emit the value-free metadata shape", %{prefix: prefix} do
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          "livebook-walkthrough-telemetry",
          [[:ash_onetime, :admission], [:ash_onetime, :conflict]],
          fn event, _measurements, metadata, _config ->
            send(test_pid, {:event, event, metadata})
          end,
          nil
        )

      assert {:ok, _} =
               charge(prefix, %{
                 account_id: "00000000-0000-0000-0000-000000000002",
                 amount: 5,
                 idempotency_key: "key-telemetry"
               })

      assert {:ok, _} =
               Charge
               |> Ash.ActionInput.for_action(:redeem, %{value: 1, proof: "proof-telemetry"})
               |> Ash.ActionInput.set_tenant(prefix)
               |> Ash.run_action()

      assert {:error, _} =
               Charge
               |> Ash.ActionInput.for_action(:redeem, %{value: 1, proof: "proof-telemetry"})
               |> Ash.ActionInput.set_tenant(prefix)
               |> Ash.run_action()

      :telemetry.detach("livebook-walkthrough-telemetry")

      events = flush_events()

      # An :admitted admission fired for the fresh charge...
      assert Enum.any?(events, fn
               {[:ash_onetime, :admission], %{result_class: :admitted, action: :charge}} -> true
               _other -> false
             end)

      # ...and a :nonce_used conflict fired for the reused proof. Metadata is value-free:
      # strategy/resource/action/result_class only, never the proof or payload.
      assert Enum.any?(events, fn
               {[:ash_onetime, :conflict], %{result_class: :nonce_used, action: :redeem}} -> true
               _other -> false
             end)

      for {_event, meta} <- events do
        assert Map.keys(meta) |> Enum.sort() == [:action, :resource, :result_class, :strategy]
      end
    end
  end

  defp charge(prefix, input) do
    Charge
    |> Ash.Changeset.for_create(:charge, input)
    |> Ash.Changeset.set_tenant(prefix)
    |> Ash.create()
  end

  defp table_count(prefix, table) do
    %{rows: [[count]]} = SQL.query!(Repo, ~s{SELECT COUNT(*) FROM "#{prefix}"."#{table}"}, [])
    count
  end

  defp flush_events do
    # Give telemetry handlers a moment to flush, then drain the mailbox of event messages.
    Process.sleep(50)
    flush_events([])
  end

  defp flush_events(acc) do
    receive do
      {:event, event, meta} -> flush_events(acc ++ [{event, meta}])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
