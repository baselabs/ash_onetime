defmodule AshOnetime.NonceRollbackGapTest do
  @moduledoc """
  Pins the two nonce commit-boundary behaviors:

  1. DEFAULT (`commit: :with_action`, the rollback gap) — a nonce spend commits inside the
     protected action's transaction, so a failure in the action body rolls the nonce claim back
     and the same proof is re-admitted on retry. This is the CORRECT behavior for a single-use
     authenticator whose retry bears a fresh proof: the spend lives and dies with the effect.

  2. FENCE (`commit: :independent`, ADR-0003 DPoP replay fence) — a nonce spend commits in its
     own transaction BEFORE the action body runs, so a body failure leaves the proof spent for
     the acceptance window. A retry with the same proof is rejected with `:nonce_already_used`
     (RFC 9449 §11.1 request-attempt scope).

  The gap trace (why the default rolls back): change.ex before_action -> admission.ex
  Store.claim -> postgres.ex plain INSERT on the action's transaction. No inner commit. The
  fence trace: change.ex before_action -> admission.ex reserve_committed -> Store.claim_committed
  -> postgres.ex worker process commits in its own transaction before the body runs.

  The fence test runs against an UNBOXED repo (`start_unboxed_repo!`) because `claim_committed`
  spawns a worker process on its own connection (the mechanism that makes the independent commit
  real), and a spawned process cannot share the test sandbox's owned transaction — the same
  constraint the external-recovery tests already satisfy (`external_recovery_test.exs`).
  """

  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.{LivebookExamples, Repo}
  alias Ecto.Adapters.SQL
  alias LivebookExamples.Charge

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
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

    :ok
  end

  describe "commit: :with_action (default, the rollback gap)" do
    @tag nonce_rollback_gap: true
    test "a nonce spend rolls back when the action body fails — the proof is re-admitted (DEFAULT)",
         %{prefix: prefix} do
      # A unique proof per run (the schema is shared with the unboxed fence describe block below,
      # whose markers persist; this test's own rollback leaves no new row regardless).
      proof = "dpop-proof-default-#{System.unique_integer([:positive])}"

      # Count the committed markers BEFORE the spend (baseline; may include fence-test leftovers).
      %{rows: [[before_count]]} =
        SQL.query!(Repo, "SELECT count(*) FROM \"#{prefix}\".\"ash_onetime_nonce_claims\"", [])

      # First attempt: proof is spent in before_action, then the body (FailRun) fails.
      assert {:error, first_error} =
               Charge
               |> Ash.ActionInput.for_action(:redeem_fail, %{value: 1, proof: proof})
               |> Ash.ActionInput.set_tenant(prefix)
               |> Ash.run_action()

      assert AshOnetime.Error.code(first_error) == :downstream_failed

      # The nonce claim rolled back with the action transaction — no NEW committed marker.
      # (Delta is 0: the spend lived and died with the action transaction.)
      %{rows: [[after_count]]} =
        SQL.query!(Repo, "SELECT count(*) FROM \"#{prefix}\".\"ash_onetime_nonce_claims\"", [])

      assert after_count == before_count

      # Second attempt with the SAME proof: re-admitted (the body runs again) — the default
      # behavior for a single-use authenticator whose retry bears a fresh proof.
      assert {:error, second_error} =
               Charge
               |> Ash.ActionInput.for_action(:redeem_fail, %{value: 1, proof: proof})
               |> Ash.ActionInput.set_tenant(prefix)
               |> Ash.run_action()

      assert AshOnetime.Error.code(second_error) == :downstream_failed
    end
  end

  describe "commit: :independent (the DPoP replay fence, ADR-0003)" do
    # Unboxed (describe-scoped): the claim_committed worker spawns its own process and needs a
    # real (non-sandbox) repo to open its own transaction. Same constraint as
    # external_recovery_test.exs. @describetag (not @moduletag) so the DEFAULT describe block
    # above stays sandboxed and its count=0 rollback assertion holds.
    @describetag unboxed: true

    setup do
      repo = start_unboxed_repo!()
      {:ok, fence_repo: repo}
    end

    @tag replay_fence: true
    @tag replay_fence_dispatch_mutation: true
    test "a nonce spend survives action-body failure — the proof is NOT re-admitted (FENCE)",
         %{prefix: prefix, fence_repo: repo} do
      # Unique proof per run — the unboxed repo persists across tests, so a fixed proof would
      # collide with markers left by prior runs.
      proof = "dpop-proof-fence-#{System.unique_integer([:positive])}"

      # First attempt: proof is spent in before_action via claim_committed (its OWN
      # transaction), then the body (FailRun) fails. The spend survives the rollback.
      assert {:error, first_error} = run_fence(repo, prefix, proof, 1)

      assert AshOnetime.Error.code(first_error) == :downstream_failed

      # Second attempt with the SAME proof: REJECTED with :nonce_already_used.
      # This is the inversion of the default behavior — the proof is spent for the window.
      # (The count-of-1 assertion lives in replay_fence_test.exs's "survives body kill" test,
      # which captures the marker's key_hash from the DB; here the retry-rejection is the
      # deterministic contract the mutation sentinel targets.)
      assert {:error, second_error} = run_fence(repo, prefix, proof, 1)

      assert AshOnetime.Error.code(second_error) == :nonce_already_used
    end

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
  end
end
