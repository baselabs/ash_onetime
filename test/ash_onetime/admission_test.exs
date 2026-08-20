defmodule AshOnetime.AdmissionTest do
  use ExUnit.Case, async: true

  # ROADMAP H31: Admission is the most security-critical module and is exercised mostly
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

  describe "bounded callback context (M1)" do
    # M1: verifier/mint/scope callbacks receive ONLY %{resource:, action:} — the trusted
    # local facts the admission path derives itself (AGENTS.md: "verification callbacks
    # return trusted local facts; action input cannot supply pre-verified facts"). Caller-
    # supplied actor/tenant/keys/now are NOT forwarded (least-privilege). The prior code
    # threaded trusted_context into bounded_callback_context/2 and ran a dead
    # Map.take(trusted_context, [:keys, :now]) that always returned %{} (no producer of
    # :keys/:now exists); the fix collapsed it to bounded_callback_context/1 (subject only),
    # removing both dead paths.
    #
    # The behavioral tripwire lives in ActionTransactionTest — "the bounded callback context
    # carries exactly resource and action (M1)" — which drives the real verifier with the
    # bounded context directly (deterministic, no DB) and asserts the keys are exactly
    # [:action, :resource]. This unit suite cannot drive the verifier; the contract is pinned
    # there.
  end

  describe "the test seam is default-off in every build (gate tripwire)" do
    # The Process-dictionary store redirect is compiled only when a build explicitly sets
    # config :ash_onetime, allow_admission_override: true (mirroring Token's
    # @allow_clock_override gate; see the gate comment in Admission). Two tripwires pin
    # that property: a source-shape assertion (the gate is Application.compile_env on the
    # named key, and Mix.env() never appears in the module — the deployment-fragile
    # pattern Token abandoned), and a dev-build subprocess proving the seam functions are
    # COMPILED OUT of a build that has not opted in (config/test.exs opts the suite in, so
    # only an out-of-suite build can observe the off branch).
    test "the gate is compile_env on the named key and Mix.env is absent from the module" do
      source = File.read!(Path.join(__DIR__, "../../lib/ash_onetime/admission.ex"))

      assert source =~ "@allow_admission_override Application.compile_env("
      assert source =~ ":allow_admission_override,"
      assert source =~ "if @allow_admission_override do"
      refute source =~ "Mix.env()"
    end

    test "the seam functions are absent from a dev build without the opt-in" do
      # The dev subprocess inherits a clean env: config/config.exs imports test.exs ONLY
      # for the test env, so in MIX_ENV=dev the allow_admission_override config is unset
      # and the gate freezes to false at the dev build's compile time — the seam must be
      # absent there.
      script = ~s'''
      seam =
        {function_exported?(AshOnetime.Admission, :put_test_store, 1),
         function_exported?(AshOnetime.Admission, :reset_test_store, 0),
         function_exported?(AshOnetime.Admission, :put_test_state, 2)}

      IO.inspect(seam, label: "admission_seam")
      '''

      build_path =
        Path.join([
          File.cwd!(),
          "_build",
          "ash-onetime-seam-off-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
        ])

      on_exit(fn -> File.rm_rf!(build_path) end)
      link_dependency_builds!(Mix.Project.build_path(), build_path)

      {output, status} =
        try do
          System.cmd("mix", ["run", "--no-start", "--no-deps-check", "-e", script],
            env: [{"MIX_BUILD_PATH", build_path}, {"MIX_ENV", "dev"}],
            stderr_to_stdout: true
          )
        after
          File.rm_rf!(build_path)
        end

      refute File.exists?(build_path)
      assert status == 0
      assert output =~ "admission_seam: {false, false, false}"
    end
  end

  # Mirrors TokenTest's private helper of the same shape: links dependency builds into an
  # isolated build path so the subprocess compiles only ash_onetime fresh.
  defp link_dependency_builds!(source_build_path, target_build_path) do
    target_lib_path = Path.join(target_build_path, "lib")
    File.mkdir_p!(target_lib_path)

    source_build_path
    |> Path.join("lib/*")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "ash_onetime"))
    |> Enum.each(fn dependency_path ->
      File.ln_s!(dependency_path, Path.join(target_lib_path, Path.basename(dependency_path)))
    end)
  end
end
