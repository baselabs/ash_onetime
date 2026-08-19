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
    [:ash_onetime, :external_recovery],
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

    assert :ok =
             Telemetry.external_recovery(5, :idempotency, Resource, :redeem, :execute_succeeded)

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

  test "uncertain_exception emits the store-internal diagnosis event (L6)" do
    # L6: a store-transaction exception (committed_claim_transaction rescue) emits
    # [:ash_onetime, :uncertain_exception] with the exception CLASS (not struct, to avoid
    # leaking request material) before collapsing to :dispatched_unknown. This event bypasses
    # emit/6 (it is store-internal, not admission-shaped) and carries %{strategy:, phase:,
    # exception:}. A fresh application sees nothing unless it attaches a handler.
    handler = "ash-onetime-uncertain-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:ash_onetime, :uncertain_exception],
      fn event, measurements, metadata, _config ->
        send(parent, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Telemetry.uncertain_exception(:idempotency,
               phase: :committed_claim,
               exception: Postgrex.Error
             )

    assert_receive {:event, [:ash_onetime, :uncertain_exception], %{count: 1}, metadata}
    assert metadata.strategy == :idempotency
    assert metadata.phase == :committed_claim
    assert metadata.exception == Postgrex.Error
  end

  test "uncertain_exception enforces its closed metadata shape — no caller-owned values" do
    # Cross-vendor review (codex blocking + claude should-fix, both observed live): the raw
    # event accepted arbitrary opts, and routing through attach/0 widened the unvalidated
    # metadata onto the default :metric stream. The closed shape is enforced at the emitter
    # exactly as emit/6 enforces the admission shape — an atom cannot carry request material.
    handler = "ash-onetime-uncertain-guard-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:ash_onetime, :uncertain_exception],
      fn event, measurements, metadata, _config ->
        send(parent, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # Extra keys (a secret-carrying token), invalid strategy, missing key, non-atom phase,
    # exception struct instead of module, duplicate keys: every leg fails WITHOUT emission.
    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.uncertain_exception(:idempotency,
               phase: :committed_claim,
               exception: Postgrex.Error,
               token: "classified-secret"
             )

    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.uncertain_exception(:anything,
               phase: :committed_claim,
               exception: Postgrex.Error
             )

    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.uncertain_exception(:idempotency, phase: :committed_claim)

    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.uncertain_exception(:idempotency,
               phase: "claim",
               exception: Postgrex.Error
             )

    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.uncertain_exception(:idempotency,
               phase: :committed_claim,
               exception: %{message: "request material"}
             )

    assert {:error, %AshOnetime.Error{code: :telemetry_invalid}} =
             Telemetry.uncertain_exception(:idempotency,
               phase: :claim,
               exception: Postgrex.Error,
               phase: :committed_claim
             )

    refute_receive {:event, _, _, _}
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

    test "attach/0 routes the diagnosis event :uncertain_exception as a :metric event" do
      # D3 (#4): attach/0 must cover the full closed surface — all 13 events, no silent
      # drops. The diagnosis event fires precisely when the store is sick; unrouted, a
      # consumer's diagnosis stream looks empty at the worst moment. The router forwards
      # the result-class-less metadata unchanged and normalizes to count: 1.
      observer = "h21-uncertain-observer-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach(
          observer,
          [:ash_onetime, :uncertain_exception, :metric],
          fn event, measurements, metadata, _config ->
            send(parent, {:metric, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(observer) end)

      default = "h21-uncertain-default-#{System.unique_integer([:positive])}"
      assert :ok = Telemetry.attach(name: default)
      on_exit(fn -> Telemetry.detach(name: default) end)

      assert :ok =
               Telemetry.uncertain_exception(:idempotency,
                 phase: :committed_claim,
                 exception: Postgrex.Error
               )

      assert_receive {:metric, [:ash_onetime, :uncertain_exception, :metric], measurements,
                      metadata}

      # Count-normalized like every non-duration event; the diagnosis metadata shape
      # passes through unchanged (no result_class by design).
      assert measurements == %{count: 1}
      assert metadata.strategy == :idempotency
      assert metadata.phase == :committed_claim
      assert metadata.exception == Postgrex.Error
      refute Map.has_key?(metadata, :result_class)
    end

    test "attach/0 leaves no closed event unattached — the full 13-event surface is covered" do
      # The coverage contract itself (D3: "all 13 events, no silent drops") as a gate: after
      # attach/0, every closed event name has the default handler registered. The next event
      # emitted outside emit/6 and missed in the attach list reds here instead of dropping
      # silently. @events is the 12 admission/business events; the diagnosis event rides with it.
      default = "h21-coverage-#{System.unique_integer([:positive])}"
      assert :ok = Telemetry.attach(name: default)
      on_exit(fn -> Telemetry.detach(name: default) end)

      expected_id = Telemetry.handler_id(default)

      for event <- @events ++ [[:ash_onetime, :uncertain_exception]] do
        assert Enum.any?(:telemetry.list_handlers(event), fn %{id: id} -> id == expected_id end),
               "attach/0 did not cover #{inspect(event)}"
      end
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
