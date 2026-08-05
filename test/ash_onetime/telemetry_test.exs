defmodule AshOnetime.TelemetryTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Telemetry
  alias AshOnetime.Test.ActionExamples.Resource

  @events [
    [:ash_onetime, :admission],
    [:ash_onetime, :conflict],
    [:ash_onetime, :replay],
    [:ash_onetime, :fingerprint_mismatch],
    [:ash_onetime, :verification],
    [:ash_onetime, :encoding],
    [:ash_onetime, :store_uncertainty],
    [:ash_onetime, :untracked_execution]
  ]

  @tag task5_telemetry_builder_mutation: true
  test "every event emits exact closed measurements and metadata" do
    handler = "ash-onetime-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler,
        @events,
        fn event, measurements, metadata, _config ->
          send(parent, {:event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Telemetry.admission(1, :idempotency, Resource, :redeem, :admitted)
    assert :ok = Telemetry.conflict(:idempotency, Resource, :redeem, :complete)
    assert :ok = Telemetry.replay(2, :idempotency, Resource, :redeem, :returned)
    assert :ok = Telemetry.fingerprint_mismatch(:idempotency, Resource, :redeem)
    assert :ok = Telemetry.verification(3, :idempotency, Resource, :redeem, :verified)
    assert :ok = Telemetry.encoding(4, :idempotency, Resource, :redeem, :stored)
    assert :ok = Telemetry.store_uncertainty(:idempotency, Resource, :redeem, :sent)
    assert :ok = Telemetry.untracked_execution(:idempotency, Resource, :redeem)

    for event <- @events do
      assert_receive {:event, ^event, measurements, metadata}
      assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :result_class, :strategy]
      assert metadata.resource == Resource
      assert metadata.action == :redeem
      assert metadata.strategy == :idempotency
      assert Map.keys(measurements) in [[:count], [:duration]]
    end
  end

  test "invalid internal telemetry values fail closed without emission" do
    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.admission(
               -1,
               :idempotency,
               Resource,
               :redeem,
               :admitted
             )

    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.admission(
               1,
               :invalid_strategy,
               Resource,
               :redeem,
               :admitted
             )
  end

  test "public telemetry API exposes no caller-owned metadata map" do
    refute function_exported?(Telemetry, :admission, 3)
    refute function_exported?(Telemetry, :conflict, 2)
    refute function_exported?(Telemetry, :replay, 3)
    refute function_exported?(Telemetry, :fingerprint_mismatch, 1)
    refute function_exported?(Telemetry, :verification, 3)
    refute function_exported?(Telemetry, :encoding, 3)
    refute function_exported?(Telemetry, :store_uncertainty, 2)
    refute function_exported?(Telemetry, :untracked_execution, 1)
  end
end
