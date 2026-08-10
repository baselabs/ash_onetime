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
    [:ash_onetime, :cache],
    [:ash_onetime, :cleanup],
    [:ash_onetime, :reap],
    [:ash_onetime, :store_uncertainty],
    [:ash_onetime, :untracked_execution]
  ]

  @tag telemetry_builder_mutation: true
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
    assert :ok = Telemetry.cache(:idempotency, Resource, :redeem, :hit)
    assert :ok = Telemetry.cleanup(:idempotency, Resource, :redeem, 2, :claims_deleted)
    assert :ok = Telemetry.reap(:idempotency, Resource, :redeem, 2, :claims_reaped)
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

  test "store_uncertainty distinguishes worker timeout from disconnect and unknown dispatch" do
    # ROADMAP H11: the committed-claim worker's 30s timeout must surface as a distinct
    # result_class (:worker_timeout) so an operator can triage it as pool/lock contention
    # rather than a network partition (:disconnected) or an unspecified dispatch failure
    # (:unknown). Each class is an accepted closed-class atom; the three are distinct.
    assert :ok = Telemetry.store_uncertainty(:idempotency, Resource, :redeem, :worker_timeout)
    assert :ok = Telemetry.store_uncertainty(:idempotency, Resource, :redeem, :disconnected)
    assert :ok = Telemetry.store_uncertainty(:idempotency, Resource, :redeem, :unknown)

    # An unknown class is rejected — the closed-class surface did not widen silently.
    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.store_uncertainty(:idempotency, Resource, :redeem, :not_a_real_class)
  end

  describe "default metrics handler (H21)" do
    # ROADMAP H21: the library emits but attaches nothing — a fresh consumer sees nothing
    # until they hand-roll a handler. attach/1 is the opt-in helper.

    test "attach/0 routes events as downstream :metric events with normalized measurements" do
      # Attach a SECOND handler on the :metric suffix to observe what the default router emits.
      observer = "h21-observer-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach_many(
          observer,
          [
            [:ash_onetime, :admission, :metric],
            [:ash_onetime, :store_uncertainty, :metric]
          ],
          fn event, measurements, metadata, _config ->
            send(parent, {:metric, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(observer) end)

      # Attach the default handler (scoped so it does not collide with other tests).
      default = "h21-default-#{System.unique_integer([:positive])}"
      assert :ok = Telemetry.attach(name: default)
      on_exit(fn -> Telemetry.detach(name: default) end)

      assert :ok = Telemetry.admission(42, :idempotency, Resource, :redeem, :admitted)
      assert :ok = Telemetry.store_uncertainty(:idempotency, Resource, :redeem, :worker_timeout)

      assert_receive {:metric, [:ash_onetime, :admission, :metric], admission_meas,
                      admission_meta}

      # A duration-event carries :duration; the metadata is the closed atoms-only shape.
      assert Map.keys(admission_meas) == [:duration]
      assert admission_meas.duration == 42

      assert Map.keys(admission_meta) |> Enum.sort() ==
               [:action, :resource, :result_class, :strategy]

      assert admission_meta.result_class == :admitted

      assert_receive {:metric, [:ash_onetime, :store_uncertainty, :metric], count_meas,
                      count_meta}

      # A count-event carries :count; the metadata is the closed atoms-only shape.
      assert Map.keys(count_meas) == [:count]
      assert count_meta.result_class == :worker_timeout
    end

    test "attach is idempotent per name and detach removes the handler" do
      name = "h21-idempotent-#{System.unique_integer([:positive])}"
      assert :ok = Telemetry.attach(name: name)
      assert {:error, :already_exists} = Telemetry.attach(name: name)
      assert :ok = Telemetry.detach(name: name)
      # Detaching twice returns not_found — the handler is gone.
      assert {:error, :not_found} = Telemetry.detach(name: name)
    end

    test "the default handler preserves the value-free guarantee — no forbidden field" do
      # The router passes metadata through unchanged. The closed-class validator upstream
      # already rejects forbidden fields (the forbidden-telemetry mutation fixture pins it);
      # this test confirms the router does not ADD anything. The :metric event's metadata
      # keys are exactly the closed 4-field shape.
      default = "h21-valuefree-#{System.unique_integer([:positive])}"
      observer = "h21-vf-observer-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        observer,
        [:ash_onetime, :conflict, :metric],
        fn _event, _meas, metadata, _config -> send(parent, {:vf, metadata}) end,
        nil
      )

      assert :ok = Telemetry.attach(name: default)
      on_exit(fn -> Telemetry.detach(name: default) end)
      on_exit(fn -> :telemetry.detach(observer) end)

      assert :ok = Telemetry.conflict(:idempotency, Resource, :redeem, :complete)
      assert_receive {:vf, metadata}
      assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :result_class, :strategy]
    end
  end

  test "public telemetry API exposes no caller-owned metadata map" do
    refute function_exported?(Telemetry, :admission, 3)
    refute function_exported?(Telemetry, :conflict, 2)
    refute function_exported?(Telemetry, :replay, 3)
    refute function_exported?(Telemetry, :fingerprint_mismatch, 1)
    refute function_exported?(Telemetry, :verification, 3)
    refute function_exported?(Telemetry, :encoding, 3)
    refute function_exported?(Telemetry, :cache, 2)
    refute function_exported?(Telemetry, :cleanup, 3)
    refute function_exported?(Telemetry, :reap, 4)
    refute function_exported?(Telemetry, :store_uncertainty, 2)
    refute function_exported?(Telemetry, :untracked_execution, 1)
  end
end
