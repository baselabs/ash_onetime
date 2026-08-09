defmodule AshOnetime.AdmissionTest do
  use ExUnit.Case, async: true

  # ROADMAP H31: the 1,165-line most security-critical module (Admission) is exercised only
  # transitively via integration tests. These are focused unit tests for the pure decision
  # functions that are independent of a live Postgres — the replay marker, the state
  # propagation, the replayed/fresh stamp, and the complete/2 short-circuits — so a
  # regression in stamp_replay, put_replay, or the untracked-transparency invariant surfaces
  # directly, not via an integration failure.

  alias AshOnetime.Admission
  alias AshOnetime.Admission.State

  # A minimal Ash struct that carries the private context the admission functions read/write.
  # Both Ash.Changeset and Ash.ActionInput expose set_context/2 and a context field, so a
  # changeset is the lightest vehicle for the round-trip tests.
  defp subject, do: Ash.Changeset.for_create(AshOnetime.Test.ActionExamples.Resource, :charge)

  defp state(class) do
    %State{
      class: class,
      strategy: :idempotency,
      resource: AshOnetime.Test.ActionExamples.Resource,
      action: :charge
    }
  end

  describe "replay?/1 and the replay marker" do
    test "a fresh subject is not a replay" do
      refute Admission.replay?(subject())
    end

    test "put_replay marks the subject and replay? observes it" do
      marked = Admission.put_replay(subject(), state(:replay))
      assert Admission.replay?(marked)
    end

    test "put_state alone does not set the replay marker" do
      # put_state propagates the admission state but does NOT set replayed? — only put_replay
      # does (it is the replay path). This is the marker-propagation invariant the
      # generic-action replay path depends on.
      with_state = Admission.put_state(subject(), state(:execute))
      refute Admission.replay?(with_state)
    end
  end

  describe "state/1 round-trip" do
    test "put_state then state returns the same state" do
      st = state(:execute)
      with_state = Admission.put_state(subject(), st)
      assert {:ok, ^st} = Admission.state(with_state)
    end

    test "a subject without state returns :error" do
      assert :error = Admission.state(subject())
    end

    test "put_replay carries the state too (state is observable through a replay marker)" do
      st = state(:replay)
      marked = Admission.put_replay(subject(), st)
      assert {:ok, ^st} = Admission.state(marked)
    end
  end

  describe "stamp_replay/2" do
    # stamp_replay stamps __metadata__[:ash_onetime][:replayed] onto a resource record so the
    # outer caller can observe fresh-vs-replayed after Ash.create/run_action returns.

    test "an :execute class stamps replayed: false" do
      record = %AshOnetime.Test.ActionExamples.Resource{}
      stamped = Admission.stamp_replay(state(:execute), record)
      assert stamped.__metadata__[:ash_onetime][:replayed] == false
    end

    test "a :replay class stamps replayed: true" do
      record = %AshOnetime.Test.ActionExamples.Resource{}
      stamped = Admission.stamp_replay(state(:replay), record)
      assert stamped.__metadata__[:ash_onetime][:replayed] == true
    end

    test "an :external_execute class stamps replayed: false" do
      record = %AshOnetime.Test.ActionExamples.Resource{}
      stamped = Admission.stamp_replay(state(:external_execute), record)
      assert stamped.__metadata__[:ash_onetime][:replayed] == false
    end

    test "a :nonce class stamps replayed: false" do
      record = %AshOnetime.Test.ActionExamples.Resource{}
      stamped = Admission.stamp_replay(state(:nonce), record)
      assert stamped.__metadata__[:ash_onetime][:replayed] == false
    end

    test "an :untracked class leaves the record untouched (transparency invariant)" do
      # ADR-0001 "Failure and safe cleanup": an untracked execution must remain observationally
      # indistinguishable from an unprotected action. stamp_replay returns the record unchanged
      # for :untracked, so no :ash_onetime metadata is added and replayed? reports nil.
      record = %AshOnetime.Test.ActionExamples.Resource{}
      stamped = Admission.stamp_replay(state(:untracked), record)
      assert stamped == record
      refute Map.has_key?(stamped.__metadata__ || %{}, :ash_onetime)
    end

    test "a non-struct result (primitive generic-action return) is returned unchanged" do
      # A primitive return (integer, :ok, etc.) carries no __metadata__ and is returned as-is.
      assert Admission.stamp_replay(state(:execute), 42) == 42
      assert Admission.stamp_replay(state(:replay), :ok) == :ok
    end
  end

  describe "complete/2 short-circuits" do
    # complete/2 for :nonce/:untracked/:replay returns {:ok, result} directly — no response
    # encoding, no payload persistence. These are the classes that do not own a stored
    # response, so completion is a pure pass-through.

    test ":nonce returns the result without encoding" do
      assert {:ok, :the_result} = Admission.complete(state(:nonce), :the_result)
    end

    test ":untracked returns the result without encoding" do
      assert {:ok, :the_result} = Admission.complete(state(:untracked), :the_result)
    end

    test ":replay returns the result without encoding" do
      assert {:ok, :the_result} = Admission.complete(state(:replay), :the_result)
    end
  end

  describe "replayed?/1 (the caller-visible signal)" do
    # AshOnetime.replayed?/1 is the public observation of the stamp_replay marker. It reports
    # true/false for a stamped struct and nil for an unstamped/untracked one.
    test "reports false for a fresh-execute stamp, true for a replay stamp" do
      record = %AshOnetime.Test.ActionExamples.Resource{}

      fresh = Admission.stamp_replay(state(:execute), record)
      assert AshOnetime.replayed?(fresh) == false

      replayed = Admission.stamp_replay(state(:replay), record)
      assert AshOnetime.replayed?(replayed) == true
    end

    test "reports nil for an untracked (unstamped) record" do
      record = %AshOnetime.Test.ActionExamples.Resource{}
      unstamped = Admission.stamp_replay(state(:untracked), record)
      assert AshOnetime.replayed?(unstamped) == nil
    end
  end
end
