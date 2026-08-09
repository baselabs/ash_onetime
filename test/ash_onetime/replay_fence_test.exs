defmodule AshOnetime.ReplayFenceTest do
  @moduledoc """
  Tripwires for the independent-commit DPoP replay fence (ADR-0003, RFC 9449 §11.1).

  Each test names the property it pins. The fence's defining property — "the spend survives
  action-body failure" — is pinned in `nonce_rollback_gap_test.exs`; these tests pin the
  surrounding safety properties: fail-closed on store unavailability, the burn-marker being
  unreapable inside its window, the fence keying on the verified proof, and the commit happening
  before the body runs.

  All fence-path tests run against an UNBOXED repo (`start_unboxed_repo!`) because
  `claim_committed` spawns a worker process on its own connection — the mechanism that makes the
  independent commit real — and a spawned process cannot share the test sandbox's owned
  transaction (the same constraint `external_recovery_test.exs` already satisfies). Because the
  unboxed repo is not sandboxed, claims persist across tests; tests use unique proofs and assert
  on the observable admit/reject behavior (the real contract) rather than total row counts.

  The `key_hash` stored in the table is a canonical-Fingerprint hash of the verified-proof
  descriptor (not a raw `sha256(proof)`), so tests that need to target a specific marker capture
  its `key_hash` from the DB after the first admit rather than reconstructing it.
  """

  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Store.Result
  alias AshOnetime.Test.{FaultStore, LivebookExamples, Repo}
  alias Ecto.Adapters.{SQL, SQL.Sandbox}
  alias LivebookExamples.Charge

  @moduletag unboxed: true

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema, migration_module: installation.module}
  end

  setup %{prefix: prefix} do
    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS "#{prefix}"."demo_charges" (
        id uuid PRIMARY KEY, account_id uuid NOT NULL, amount bigint NOT NULL
      )
      """,
      []
    )

    repo = start_unboxed_repo!()
    {:ok, fence_repo: repo}
  end

  describe "fail-closed on store unavailability (Rank 2: the fence must not fail open)" do
    @tag replay_fence: true
    test "claim_committed returning :dispatched_unknown rejects and runs no body",
         %{prefix: prefix, fence_repo: repo} do
      AshOnetime.Admission.put_test_store(FaultStore)
      FaultStore.put_handler(&fail_claim_committed/2)

      on_exit(fn ->
        AshOnetime.Admission.reset_test_store()
        FaultStore.reset()
      end)

      proof = "proof-fail-#{System.unique_integer([:positive])}"

      assert {:error, error} = run_fence(repo, prefix, proof, 1)

      # The fence fails closed with the typed store error — never executes untracked.
      assert AshOnetime.Error.code(error) == :dispatched_unknown
    end

    @tag replay_fence: true
    test "claim_committed returning :checkout_unavailable rejects with the typed error",
         %{prefix: prefix, fence_repo: repo} do
      AshOnetime.Admission.put_test_store(FaultStore)
      FaultStore.put_handler(&checkout_unavailable/2)

      on_exit(fn ->
        AshOnetime.Admission.reset_test_store()
        FaultStore.reset()
      end)

      proof = "proof-checkout-#{System.unique_integer([:positive])}"

      assert {:error, error} = run_fence(repo, prefix, proof, 1)

      assert AshOnetime.Error.code(error) == :checkout_unavailable
    end
  end

  describe "the fence keys on the verified proof (not something coarser)" do
    @tag replay_fence: true
    test "a different proof (different jti) admits independently — the fence is not over-coarse",
         %{prefix: prefix, fence_repo: repo} do
      proof_a = "proof-keyed-A-#{System.unique_integer([:positive])}"
      proof_b = "proof-keyed-B-#{System.unique_integer([:positive])}"

      # First proof spends and the body fails.
      assert {:error, first} = run_fence(repo, prefix, proof_a, 1)
      assert AshOnetime.Error.code(first) == :downstream_failed

      # A DIFFERENT proof (different key_hash) is a fresh attempt — admits and the body runs
      # (and fails). If the fence keyed on (operation, scope) only, this would collide and
      # return :nonce_already_used.
      assert {:error, second} = run_fence(repo, prefix, proof_b, 2)
      assert AshOnetime.Error.code(second) == :downstream_failed

      # And reusing proof_a still rejects (proof_a was spent; proof_b did not un-spend it).
      assert {:error, retry_a} = run_fence(repo, prefix, proof_a, 1)
      assert AshOnetime.Error.code(retry_a) == :nonce_already_used
    end
  end

  describe "the commit happens before the body runs (Rank 1 defense in depth)" do
    @tag replay_fence: true
    test "a body that raises still leaves the claim committed — the spend survives",
         %{prefix: prefix, fence_repo: repo} do
      proof = "proof-survive-#{System.unique_integer([:positive])}"

      # FailRun always returns :downstream_failed. The claim committed in before_action (via the
      # worker) before the body ran, so the action transaction's rollback cannot undo it.
      assert {:error, error} = run_fence(repo, prefix, proof, 1)
      assert AshOnetime.Error.code(error) == :downstream_failed

      # The retry rejects — the spend survived the body failure.
      assert {:error, retry} = run_fence(repo, prefix, proof, 1)
      assert AshOnetime.Error.code(retry) == :nonce_already_used
    end
  end

  describe "the CRUD (changeset) dispatch path also fences (change.ex, not just generic_action.ex)" do
    @tag replay_fence: true
    @tag replay_fence_crud_dispatch_mutation: true
    test "a nonce-protected CREATE with commit: :independent spends independently and rejects reuse",
         %{prefix: prefix, fence_repo: repo} do
      # Exercises change.ex's dispatch_reservation/3 (the CRUD path), NOT generic_action.ex.
      # A succeeding create commits its marker via claim_committed; a retry with the same proof
      # collides with :nonce_already_used. If the change.ex branch regressed (wrong guard /
      # wrong function), the retry would re-admit instead of rejecting.
      proof = "proof-crud-#{System.unique_integer([:positive])}"
      account = Ash.UUID.generate()

      assert {:ok, %AshOnetime.Test.LivebookExamples.Charge{}} =
               run_crud_fence(repo, prefix, proof, account, 1)

      # The retry rejects — the change.ex dispatch routed through reserve_committed.
      assert {:error, retry} = run_crud_fence(repo, prefix, proof, account, 1)
      assert AshOnetime.Error.code(retry) == :nonce_already_used
    end
  end

  describe "concurrent retry races the unique constraint (tripwire #3)" do
    @tag replay_fence: true
    test "two concurrent attempts with the same proof: exactly one admits, one rejects",
         %{prefix: prefix, fence_repo: repo} do
      proof = "proof-race-#{System.unique_integer([:positive])}"

      # Two in-flight attempts race the same (operation_hash, scope_hash, key_hash). The unique
      # constraint arbitrates: exactly one admits, the other collides. Both see the committed
      # claim independently. A real `Task.async` pair against the unboxed repo — not a sequential
      # mock — so the race is genuine.
      tasks =
        Enum.map(1..2, fn _ ->
          Task.async(fn ->
            previous = Repo.get_dynamic_repo()
            Repo.put_dynamic_repo(repo)

            try do
              Charge
              |> Ash.ActionInput.for_action(:redeem_succeed_fence, %{value: 7, proof: proof})
              |> Ash.ActionInput.set_tenant(prefix)
              |> Ash.run_action()
            after
              Repo.put_dynamic_repo(previous)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      codes =
        Enum.map(results, fn
          {:ok, _} -> :ok
          {:error, error} -> AshOnetime.Error.code(error)
        end)

      assert :ok in codes
      assert :nonce_already_used in codes
      assert Enum.count(codes, &(&1 == :ok)) == 1
    end
  end

  describe "cross-tenant isolation (tripwire #7)" do
    @tag replay_fence: true
    test "the same proof admits independently in two tenants (no cross-tenant bleed)",
         %{prefix: prefix, fence_repo: repo, migration_module: module} do
      # Two tenants = two prefixes (context-multitenancy physical-schema isolation). The same
      # proof in each admits independently — the fence keys on (operation, scope, key) and the
      # scope/tenant differs. No collision across tenants. Second prefix via Ecto.Migrator.up
      # with a bumped version (the tenant_prefix_test.exs pattern, since install_generated! can
      # only run once per test module).
      other_prefix = "ash_onetime_test_#{Ecto.UUID.generate() |> String.replace("-", "")}"
      other_version = 9_999_999_999

      Sandbox.mode(Repo, :auto)

      previous_dyn = Repo.get_dynamic_repo()
      Repo.put_dynamic_repo(repo)

      try do
        SQL.query!(Repo, ~s(CREATE SCHEMA "#{other_prefix}"), [])
        Ecto.Migrator.up(Repo, other_version, module, prefix: other_prefix, log: false)
      after
        Repo.put_dynamic_repo(previous_dyn)
        Sandbox.mode(Repo, :manual)
      end

      on_exit(fn ->
        Sandbox.mode(Repo, :auto)

        previous_dyn = Repo.get_dynamic_repo()
        Repo.put_dynamic_repo(repo)

        try do
          Ecto.Migrator.down(Repo, other_version, module, prefix: other_prefix, log: false)
          SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "#{other_prefix}" CASCADE), [])
        after
          Repo.put_dynamic_repo(previous_dyn)
          Sandbox.mode(Repo, :manual)
        end
      end)

      SQL.query!(
        repo,
        """
        CREATE TABLE IF NOT EXISTS "#{other_prefix}"."demo_charges" (
          id uuid PRIMARY KEY, account_id uuid NOT NULL, amount bigint NOT NULL
        )
        """,
        []
      )

      proof = "proof-tenant-#{System.unique_integer([:positive])}"

      # Tenant A admits.
      assert {:ok, _} = run_succeed_fence(repo, prefix, proof, 1)

      # Tenant B with the SAME proof also admits — different physical schema, no collision.
      assert {:ok, _} = run_succeed_fence(repo, other_prefix, proof, 1)

      # But reusing the proof WITHIN tenant A rejects.
      assert {:error, retry} = run_succeed_fence(repo, prefix, proof, 1)
      assert AshOnetime.Error.code(retry) == :nonce_already_used
    end
  end

  describe "a successful fence admit persists NO response (execution_class → :nonce)" do
    @tag replay_fence: true
    test "the body succeeds, the result returns, and no response payload is stored",
         %{prefix: prefix, fence_repo: repo} do
      proof = "proof-succeed-#{System.unique_integer([:positive])}"

      # The body succeeds (RedeemRun returns {:ok, value}). The fence marker committed in
      # before_action; complete/2 for class :nonce short-circuits (returns {:ok, result}) with
      # NO store write. If execution_class wrongly mapped to :external_execute, complete/2 would
      # drive persist_completion -> complete_external, storing a payload a burn-marker must never
      # have. Assert NO response_payloads row exists for this claim.
      assert {:ok, value} = run_succeed_fence(repo, prefix, proof, 42)

      assert value == 42

      # No response payload was persisted — the fence marker is a one-way spend, not a stored
      # response. (The idempotency response_payloads table is the persistence surface
      # complete_external would write; 0 rows proves the mapping is :nonce, not :external_execute.)
      %{rows: [[0]]} =
        SQL.query!(
          repo,
          "SELECT count(*) FROM \"#{prefix}\".\"ash_onetime_response_payloads\"",
          []
        )

      # And the retry still rejects (the marker committed regardless of body success).
      assert {:error, retry} = run_succeed_fence(repo, prefix, proof, 42)
      assert AshOnetime.Error.code(retry) == :nonce_already_used
    end
  end

  describe "the burn marker is unreapable inside its window (Rank 3: cleanup race)" do
    @tag replay_fence: true
    test "a committed burn marker whose retain_until is still inside the window is NOT reaped",
         %{prefix: prefix, fence_repo: repo, target: target} do
      proof = "proof-reap-#{System.unique_integer([:positive])}"

      # Spend a proof (body fails) — the burn marker commits.
      assert {:error, _} = run_fence(repo, prefix, proof, 1)
      key_hash = capture_key_hash(repo, prefix, proof)

      # Run cleanup against the fence repo (the marker is NOT eligible — its retain_until is
      # issued_at + max_age(1h) + skew(5s) + margin, well in the future).
      assert {:ok, %{nonce: 0}} = AshOnetime.Store.cleanup(%{target | dynamic_repo: repo}, 100)

      # The marker survived — the fence is intact.
      assert count_claims_by_key(repo, prefix, key_hash) == 1

      # And the retry still rejects (the marker was not reaped).
      assert {:error, retry} = run_fence(repo, prefix, proof, 1)
      assert AshOnetime.Error.code(retry) == :nonce_already_used
    end

    @tag replay_fence: true
    test "once retain_until is past the window, the marker IS reaped and reuse re-admits",
         %{prefix: prefix, fence_repo: repo, target: target} do
      proof = "proof-reap-expire-#{System.unique_integer([:positive])}"

      # Spend a proof.
      assert {:error, _} = run_fence(repo, prefix, proof, 1)
      key_hash = capture_key_hash(repo, prefix, proof)

      # Force the marker to be cleanup-eligible by back-dating retain_until, admitted_at,
      # inserted_at, AND issued_at past the window, following the established
      # window_cleanup_test.exs SQL-manipulation pattern. All four timestamp fields must move
      # together so the CHECKs (retain_until > admitted_at, retain_until > issued_at) hold;
      # back-dating only retain_until on a just-admitted row violates them.
      SQL.query!(
        repo,
        """
        UPDATE "#{prefix}"."ash_onetime_nonce_claims"
        SET retain_until = transaction_timestamp() - interval '2 hours',
            admitted_at = transaction_timestamp() - interval '3 hours',
            inserted_at = transaction_timestamp() - interval '3 hours',
            issued_at = transaction_timestamp() - interval '4 hours'
        WHERE key_hash = $1
        """,
        [key_hash]
      )

      # The back-dated marker is reaped.
      assert {:ok, %{nonce: nonce_reaped}} =
               AshOnetime.Store.cleanup(%{target | dynamic_repo: repo}, 100)

      assert nonce_reaped >= 1

      # THIS proof's marker is gone.
      assert count_claims_by_key(repo, prefix, key_hash) == 0

      # Window expired → a fresh attempt with the same proof re-admits (and the body fails again).
      assert {:error, retry} = run_fence(repo, prefix, proof, 1)
      assert AshOnetime.Error.code(retry) == :downstream_failed
    end
  end

  # --- helpers ---

  defp run_fence(repo, prefix, proof, value) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    try do
      Charge
      |> Ash.ActionInput.for_action(:redeem_fail_fence, %{value: value, proof: proof})
      |> Ash.ActionInput.set_tenant(prefix)
      |> Ash.run_action()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp run_succeed_fence(repo, prefix, proof, value) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    try do
      Charge
      |> Ash.ActionInput.for_action(:redeem_succeed_fence, %{value: value, proof: proof})
      |> Ash.ActionInput.set_tenant(prefix)
      |> Ash.run_action()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp run_crud_fence(repo, prefix, proof, account_id, amount) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    try do
      Charge
      |> Ash.Changeset.for_create(:nonce_charge_fence, %{
        proof: proof,
        account_id: account_id,
        amount: amount
      })
      |> Ash.Changeset.set_tenant(prefix)
      |> Ash.create()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  # Captures the key_hash of the fence marker for `proof`. The key_hash is a canonical-
  # Fingerprint hash (not raw sha256), so it must be read from the DB rather than reconstructed.
  # Select the fence-scope marker inserted in the last 2 seconds — tests use unique proofs and
  # run sequentially (async: false), so the just-inserted marker is the latest in its scope.
  defp capture_key_hash(repo, prefix, _proof) do
    %{rows: [[key_hash]]} =
      SQL.query!(
        repo,
        """
        SELECT key_hash FROM "#{prefix}"."ash_onetime_nonce_claims"
        WHERE inserted_at > transaction_timestamp() - interval '2 seconds'
        ORDER BY inserted_at DESC
        LIMIT 1
        """,
        []
      )

    key_hash
  end

  defp count_claims_by_key(repo, prefix, key_hash) do
    %{rows: [[count]]} =
      SQL.query!(
        repo,
        """
        SELECT count(*) FROM "#{prefix}"."ash_onetime_nonce_claims" WHERE key_hash = $1
        """,
        [key_hash]
      )

    count
  end

  defp fail_claim_committed(:claim_committed, _args),
    do: Result.failure(:dispatched_unknown, :unknown, :unknown)

  defp fail_claim_committed(_op, [target, request]),
    do: AshOnetime.Store.claim(target, request)

  defp checkout_unavailable(:claim_committed, _args),
    do: Result.failure(:checkout_unavailable, :not_started, :not_applicable)

  defp checkout_unavailable(_op, [target, request]),
    do: AshOnetime.Store.claim(target, request)
end
