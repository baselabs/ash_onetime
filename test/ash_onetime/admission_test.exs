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
  alias AshOnetime.Resource.Info, as: ResourceInfo
  alias AshOnetime.Store.{Claim, Postgres, Result}
  alias AshOnetime.Verified

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

  test "an admitted claim from another logical partition fails closed" do
    now = DateTime.utc_now()

    {:ok, request} =
      Claim.idempotency(
        operation_hash: :crypto.hash(:sha256, "operation"),
        scope_hash: :crypto.hash(:sha256, "scope"),
        key_hash: :crypto.hash(:sha256, "key"),
        fingerprint: :crypto.hash(:sha256, "fingerprint"),
        retention_seconds: 60
      )

    target = %Postgres.Target{
      repo_module: AshOnetime.Test.Repo,
      dynamic_repo: AshOnetime.Test.Repo,
      logical_partition: "tenant-a"
    }

    claim = %Claim{
      strategy: :idempotency,
      id: request.id,
      logical_partition: "tenant-b",
      operation_hash: request.operation_hash,
      scope_hash: request.scope_hash,
      key_hash: request.key_hash,
      fingerprint: request.fingerprint,
      state: :processing,
      admitted_at: now,
      retain_until: DateTime.add(now, 60),
      inserted_at: now
    }

    state = %State{
      class: :pending,
      strategy: :idempotency,
      resource: AshOnetime.Test.ActionExamples.Resource,
      action: :charge,
      request: request,
      target: target
    }

    result = Result.success(:admitted, claim: claim)

    assert {:error, %AshOnetime.Error{code: :store_invariant}} =
             Admission.resolve(
               result,
               state,
               %{strategy: :idempotency},
               System.monotonic_time(),
               :local_claim
             )
  end

  describe "sanitize_request/1 (the stripping seam)" do
    # H31: the nonce request carries trusted verification facts (the Verified components and
    # the clock module) only as far as the store claim; the state that survives into the
    # admission decision must not carry them. These tests pin the pure stripping directly.

    test "a one_time_nonce request loses verified and clock, everything else survives" do
      {:ok, request} =
        Claim.nonce(
          operation_hash: :crypto.hash(:sha256, "operation"),
          scope_hash: :crypto.hash(:sha256, "scope"),
          key_hash: :crypto.hash(:sha256, "key"),
          verified: [
            %Verified{
              key: "nonce-key",
              issued_at: DateTime.utc_now(),
              verifier_id: "unit-verifier"
            }
          ],
          max_age: 60,
          clock_skew: 5
        )

      sanitized = Admission.sanitize_request(request)

      assert sanitized.verified == nil
      assert sanitized.clock == nil
      assert %{sanitized | verified: request.verified, clock: request.clock} == request
    end

    test "an idempotency request passes through untouched" do
      {:ok, request} =
        Claim.idempotency(
          operation_hash: :crypto.hash(:sha256, "operation"),
          scope_hash: :crypto.hash(:sha256, "scope"),
          key_hash: :crypto.hash(:sha256, "key"),
          fingerprint: :crypto.hash(:sha256, "fingerprint"),
          retention_seconds: 60
        )

      assert Admission.sanitize_request(request) == request
    end
  end

  describe "sanitize_claim/1 (the stripping seam)" do
    # H31: a nonce claim's verifier_id is burn-time evidence; the state that execution
    # proceeds with must not retain it. The idempotency claim carries no verification facts.

    test "a one_time_nonce claim loses verifier_id, everything else survives" do
      now = DateTime.utc_now()

      claim = %Claim{
        strategy: :one_time_nonce,
        id: Ecto.UUID.generate(),
        logical_partition: "tenant-a",
        operation_hash: :crypto.hash(:sha256, "operation"),
        scope_hash: :crypto.hash(:sha256, "scope"),
        key_hash: :crypto.hash(:sha256, "key"),
        issued_at: now,
        verifier_id: "unit-verifier",
        admitted_at: now,
        retain_until: DateTime.add(now, 60),
        inserted_at: now
      }

      sanitized = Admission.sanitize_claim(claim)

      assert sanitized.verifier_id == nil
      assert %{sanitized | verifier_id: claim.verifier_id} == claim
    end

    test "an idempotency claim passes through untouched" do
      now = DateTime.utc_now()

      claim = %Claim{
        strategy: :idempotency,
        id: Ecto.UUID.generate(),
        logical_partition: "tenant-a",
        operation_hash: :crypto.hash(:sha256, "operation"),
        scope_hash: :crypto.hash(:sha256, "scope"),
        key_hash: :crypto.hash(:sha256, "key"),
        fingerprint: :crypto.hash(:sha256, "fingerprint"),
        state: :processing,
        admitted_at: now,
        retain_until: DateTime.add(now, 60),
        inserted_at: now
      }

      assert Admission.sanitize_claim(claim) == claim
    end
  end

  describe "resolve/5: the :admitted arm" do
    # H31: every execution_class/2 mapping plus the invariant-reject shapes. Each test names
    # the failing function directly — synthetic Store.Result/Admission.State, zero Postgres.

    test "idempotency local claim executes with class :execute" do
      request = idempotency_request()
      claim = idempotency_claim(request)
      result = Result.success(:admitted, claim: claim)

      assert {:execute, resolved} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )

      assert resolved.class == :execute
      assert resolved.claim == claim
    end

    test "idempotency committed external claim maps to :external_execute under a committed transaction" do
      request = idempotency_request()
      claim = idempotency_claim(request)
      result = Result.success(:admitted, claim: claim) |> Result.committed()

      assert {:execute, resolved} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :committed_external_claim
               )

      assert resolved.class == :external_execute
    end

    test "idempotency locked external finalize maps to :external_execute under an open transaction" do
      request = idempotency_request()
      result = Result.success(:admitted, claim: idempotency_claim(request))

      assert {:execute, resolved} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :locked_external_finalize
               )

      assert resolved.class == :external_execute
    end

    test "a nonce admission executes with class :nonce and the claim stripped of verifier_id" do
      request = nonce_request()
      claim = nonce_claim(request)
      result = Result.success(:admitted, claim: claim)

      assert {:execute, resolved} =
               Admission.resolve(
                 result,
                 decision_state(:one_time_nonce, request),
                 %{strategy: :one_time_nonce},
                 System.monotonic_time(),
                 :local_claim
               )

      assert resolved.class == :nonce
      assert resolved.claim.verifier_id == nil
      assert %{resolved.claim | verifier_id: claim.verifier_id} == claim
    end

    test "a committed nonce admission (the burn-marker path) still maps to :nonce" do
      request = nonce_request()
      result = Result.success(:admitted, claim: nonce_claim(request)) |> Result.committed()

      assert {:execute, resolved} =
               Admission.resolve(
                 result,
                 decision_state(:one_time_nonce, request),
                 %{strategy: :one_time_nonce},
                 System.monotonic_time(),
                 :committed_external_claim
               )

      assert resolved.class == :nonce
    end

    test "a wrong transaction mode is a store invariant violation" do
      # The mode dictates the only acceptable transaction mode; a committed result under
      # :local_claim (which owns an open transaction) is untrusted.
      request = idempotency_request()
      result = Result.success(:admitted, claim: idempotency_claim(request)) |> Result.committed()

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a locator hash mismatch is a store invariant violation" do
      request = idempotency_request()
      claim = idempotency_claim(request, key_hash: :crypto.hash(:sha256, "foreign-key"))
      result = Result.success(:admitted, claim: claim)

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a claim id other than the request's id is a store invariant violation" do
      request = idempotency_request()
      claim = %{idempotency_claim(request) | id: Ecto.UUID.generate()}
      result = Result.success(:admitted, claim: claim)

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a claim in a state shape the status does not allow is a store invariant violation" do
      # :admitted must observe an idempotency claim still :processing; a :complete-shaped
      # claim under :admitted fails the claim-state validation.
      request = idempotency_request()
      claim = %{idempotency_claim(request) | state: :complete}
      result = Result.success(:admitted, claim: claim)

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end
  end

  describe "resolve/5: the :complete replay arm" do
    test "a matching stored response replays the persisted result" do
      contract = redeem_contract()
      {:ok, encoded} = AshOnetime.Response.encode(42, contract, [])
      request = idempotency_request()
      claim = complete_claim(request, encoded)
      result = Result.success(:complete, claim: claim, payload: encoded.payload)

      state =
        decision_state(:idempotency, request,
          contract: contract,
          cache: AshOnetime.Cache.config([])
        )

      assert {:replay, replayed, replay_state} =
               Admission.resolve(
                 result,
                 state,
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )

      assert replayed == 42
      assert replay_state.class == :replay
      assert replay_state.replayed == 42
      assert replay_state.claim == claim
    end

    test "a stored response under a different fingerprint is rejected as key reuse" do
      contract = redeem_contract()
      {:ok, encoded} = AshOnetime.Response.encode(42, contract, [])
      request = idempotency_request()
      claim = complete_claim(request, encoded, fingerprint: :crypto.hash(:sha256, "other"))
      result = Result.success(:complete, claim: claim, payload: encoded.payload)

      state =
        decision_state(:idempotency, request,
          contract: contract,
          cache: AshOnetime.Cache.config([])
        )

      assert {:error, %AshOnetime.Error{code: :key_reused_with_different_request}} =
               Admission.resolve(
                 result,
                 state,
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a complete result without a payload is a store invariant violation" do
      contract = redeem_contract()
      {:ok, encoded} = AshOnetime.Response.encode(42, contract, [])
      request = idempotency_request()
      result = Result.success(:complete, claim: complete_claim(request, encoded))

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request, contract: contract),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end
  end

  describe "resolve/5: the :processing arm" do
    test "a local claim collision reports the request in progress" do
      request = idempotency_request()
      result = Result.success(:processing, claim: idempotency_claim(request))

      assert {:error, %AshOnetime.Error{code: :request_in_progress}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a committed external claim collision returns :recover" do
      request = idempotency_request()
      claim = idempotency_claim(request)
      result = Result.success(:processing, claim: claim) |> Result.committed()

      assert {:recover, recovered} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :committed_external_claim
               )

      assert recovered.claim == claim
    end

    test "a locked external finalize collision proceeds to external execution" do
      request = idempotency_request()
      result = Result.success(:processing, claim: idempotency_claim(request))

      assert {:execute, resolved} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :locked_external_finalize
               )

      assert resolved.class == :external_execute
    end

    test "a processing collision under a different fingerprint is rejected as key reuse" do
      request = idempotency_request()
      claim = idempotency_claim(request, fingerprint: :crypto.hash(:sha256, "other"))
      result = Result.success(:processing, claim: claim)

      assert {:error, %AshOnetime.Error{code: :key_reused_with_different_request}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a processing result carrying a stray payload is a store invariant violation" do
      request = idempotency_request()
      result = Result.success(:processing, claim: idempotency_claim(request), payload: "stray")

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, request),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end
  end

  describe "resolve/5: the :collision arm (one_time_nonce)" do
    test "a matching nonce collision reports the nonce already used" do
      request = nonce_request()
      result = Result.success(:collision, claim: nonce_claim(request))

      assert {:error, %AshOnetime.Error{code: :nonce_already_used}} =
               Admission.resolve(
                 result,
                 decision_state(:one_time_nonce, request),
                 %{strategy: :one_time_nonce},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a malformed nonce collision is a store invariant violation" do
      # A nonce claim without its verifier evidence cannot be attributed to the burned
      # nonce, so the collision is not trusted to be THE nonce's.
      request = nonce_request()
      result = Result.success(:collision, claim: nonce_claim(request, verifier_id: nil))

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               Admission.resolve(
                 result,
                 decision_state(:one_time_nonce, request),
                 %{strategy: :one_time_nonce},
                 System.monotonic_time(),
                 :local_claim
               )
    end
  end

  describe "resolve/5: the :execute_untracked escape" do
    # The escape is an EXACT shape: a definite pre-dispatch checkout failure, the explicit
    # opt-in, the idempotency strategy, and the local-claim mode. Anything else fails closed.

    test "a definite checkout failure with the opt-in executes untracked" do
      result = Result.failure(:checkout_unavailable, :not_started, :not_applicable)

      assert {:execute_untracked, untracked} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, idempotency_request()),
                 %{strategy: :idempotency, on_definite_store_failure: :execute_untracked},
                 System.monotonic_time(),
                 :local_claim
               )

      assert untracked.class == :untracked
    end

    test "without the opt-in the same failure fails closed through the store error" do
      result = Result.failure(:checkout_unavailable, :not_started, :not_applicable)

      assert {:error, %AshOnetime.Error{code: :checkout_unavailable}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, idempotency_request()),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "the escape never applies to a nonce strategy" do
      result = Result.failure(:checkout_unavailable, :not_started, :not_applicable)

      assert {:error, %AshOnetime.Error{code: :checkout_unavailable}} =
               Admission.resolve(
                 result,
                 decision_state(:one_time_nonce, nonce_request()),
                 %{strategy: :one_time_nonce, on_definite_store_failure: :execute_untracked},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a checkout failure after dispatch fails closed too" do
      result = Result.failure(:checkout_unavailable, :sent, :open)

      assert {:error, %AshOnetime.Error{code: :checkout_unavailable}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, idempotency_request()),
                 %{strategy: :idempotency, on_definite_store_failure: :execute_untracked},
                 System.monotonic_time(),
                 :local_claim
               )
    end
  end

  describe "resolve/5: the store_error fallthrough" do
    test "an uncertain failure maps its reason to the store error" do
      result = Result.failure(:lock_timeout, :sent, :open)

      assert {:error, %AshOnetime.Error{code: :lock_timeout}} =
               Admission.resolve(
                 result,
                 decision_state(:idempotency, idempotency_request()),
                 %{strategy: :idempotency},
                 System.monotonic_time(),
                 :local_claim
               )
    end

    test "a result no decide arm accepts is a bare store failure" do
      # A :processing result under a nonce strategy has no decide arm (the processing arm
      # owns idempotency only) — the catch-all must collapse it, not admit it.
      result = %Result{status: :processing, admission_dispatch: :sent, transaction: :open}

      assert {:error, %AshOnetime.Error{code: :store_failure}} =
               Admission.resolve(
                 result,
                 decision_state(:one_time_nonce, nonce_request()),
                 %{strategy: :one_time_nonce},
                 System.monotonic_time(),
                 :local_claim
               )
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

  # --- H31 direct decision-function fixtures (synthetic, zero Postgres) ---
  # Every fixture is built through the real constructors (Claim.idempotency/nonce,
  # Result.success/failure/committed, Response.contract/encode) so a unit red names a
  # decision-function regression, not a hand-forged struct drifting from the live shapes.

  defp decision_state(strategy, request, opts \\ []) do
    %State{
      class: :pending,
      strategy: strategy,
      resource: AshOnetime.Test.ActionExamples.Resource,
      action: Keyword.get(opts, :action, :charge),
      request: request,
      target: %Postgres.Target{
        repo_module: AshOnetime.Test.Repo,
        dynamic_repo: AshOnetime.Test.Repo,
        logical_partition: "tenant-a"
      },
      contract: Keyword.get(opts, :contract),
      cache: Keyword.get(opts, :cache)
    }
  end

  defp idempotency_request(opts \\ []) do
    {:ok, request} =
      Claim.idempotency(
        operation_hash: Keyword.get(opts, :operation_hash, :crypto.hash(:sha256, "operation")),
        scope_hash: Keyword.get(opts, :scope_hash, :crypto.hash(:sha256, "scope")),
        key_hash: Keyword.get(opts, :key_hash, :crypto.hash(:sha256, "key")),
        fingerprint: Keyword.get(opts, :fingerprint, :crypto.hash(:sha256, "fingerprint")),
        retention_seconds: 60
      )

    request
  end

  defp nonce_request(opts \\ []) do
    {:ok, request} =
      Claim.nonce(
        operation_hash: Keyword.get(opts, :operation_hash, :crypto.hash(:sha256, "operation")),
        scope_hash: Keyword.get(opts, :scope_hash, :crypto.hash(:sha256, "scope")),
        key_hash: Keyword.get(opts, :key_hash, :crypto.hash(:sha256, "key")),
        verified: [
          %Verified{key: "nonce-key", issued_at: DateTime.utc_now(), verifier_id: "unit-verifier"}
        ],
        max_age: 60,
        clock_skew: 5
      )

    request
  end

  defp idempotency_claim(request, opts \\ []) do
    admitted = DateTime.utc_now()

    %Claim{
      strategy: :idempotency,
      id: request.id,
      logical_partition: "tenant-a",
      operation_hash: Keyword.get(opts, :operation_hash, request.operation_hash),
      scope_hash: Keyword.get(opts, :scope_hash, request.scope_hash),
      key_hash: Keyword.get(opts, :key_hash, request.key_hash),
      fingerprint: Keyword.get(opts, :fingerprint, request.fingerprint),
      state: :processing,
      admitted_at: admitted,
      retain_until: DateTime.add(admitted, 3_600),
      inserted_at: DateTime.add(admitted, 1)
    }
  end

  defp nonce_claim(request, opts \\ []) do
    admitted = DateTime.utc_now()

    %Claim{
      strategy: :one_time_nonce,
      id: request.id,
      logical_partition: "tenant-a",
      operation_hash: request.operation_hash,
      scope_hash: request.scope_hash,
      key_hash: request.key_hash,
      issued_at: admitted,
      verifier_id: Keyword.get(opts, :verifier_id, "unit-verifier"),
      admitted_at: admitted,
      retain_until: DateTime.add(admitted, 60),
      inserted_at: DateTime.add(admitted, 1)
    }
  end

  defp complete_claim(request, encoded, opts \\ []) do
    admitted = DateTime.utc_now()

    %Claim{
      strategy: :idempotency,
      id: request.id,
      logical_partition: "tenant-a",
      operation_hash: request.operation_hash,
      scope_hash: request.scope_hash,
      key_hash: request.key_hash,
      fingerprint: Keyword.get(opts, :fingerprint, request.fingerprint),
      state: :complete,
      response_partition: Date.utc_today(),
      response_codec: encoded.codec,
      response_digest: encoded.digest,
      admitted_at: admitted,
      retain_until: DateTime.add(admitted, 3_600),
      inserted_at: DateTime.add(admitted, 1)
    }
  end

  defp redeem_contract do
    protection = ResourceInfo.protection(AshOnetime.Test.ActionExamples.Resource, :redeem)

    {:ok, contract} =
      AshOnetime.Response.contract(
        AshOnetime.Test.ActionExamples.Resource,
        :redeem,
        protection.response,
        %{limits: protection.limits}
      )

    contract
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
