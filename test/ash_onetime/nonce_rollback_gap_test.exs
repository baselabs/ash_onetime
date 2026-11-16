defmodule AshOnetime.NonceRollbackGapTest do
  @moduledoc """
  Nonce commit boundaries:

  With `commit: :with_action`, body failure rolls back the spend and permits retry.
  With `commit: :independent`, the spend commits before the body and survives failure.
  Reuse then returns `:nonce_already_used` throughout the acceptance window.
  Independent admission uses a separate real connection outside the test sandbox.
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

      # The same proof must be refused with :nonce_already_used.
      # Independent admission keeps it spent after body failure.
      # A failed action cannot reopen the acceptance window.
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
