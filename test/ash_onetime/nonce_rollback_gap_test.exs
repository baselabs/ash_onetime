defmodule AshOnetime.NonceRollbackGapTest do
  @moduledoc """
  Pins the DPoP replay-fence GAP (RFC 9449): a one-time-nonce spend commits inside the protected
  action's transaction, so a failure in the action body rolls the nonce claim back and the same
  proof is re-admitted on retry.

  This test ASSERTS THE CURRENT (INCORRECT-FOR-DPoP) BEHAVIOR on purpose. When the independent-
  commit replay-fence API lands (`lib/livebooks/nonce-rollback-gap.livemd` + the handoff's design
  note), INVERT this test: the second attempt must return :nonce_already_used, not re-admit.
  See the handoff at .forge/handoffs/*-dpop-replay-fence-handoff.md.

  Why the nonce spends-then-rolls-back: change.ex before_action → admission.ex Store.claim →
  postgres.ex plain INSERT on the action's transaction. No inner commit. So action-body failure
  rolls the claim back. RFC 9449 requires the opposite: once a valid proof is observed, a
  downstream failure must not make it reusable.
  """

  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.{LivebookExamples, Repo}
  alias LivebookExamples.Charge
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
        id uuid PRIMARY KEY, account_id uuid NOT NULL, amount bigint NOT NULL
      )
      """,
      []
    )

    :ok
  end

  @tag nonce_rollback_gap: true
  test "a nonce spend rolls back when the action body fails — the proof is re-admitted (GAP)",
       %{prefix: prefix} do
    # First attempt: proof is spent in before_action, then the body (FailRun) fails.
    assert {:error, first_error} =
             Charge
             |> Ash.ActionInput.for_action(:redeem_fail, %{value: 1, proof: "dpop-proof-1"})
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    assert AshOnetime.Error.code(first_error) == :downstream_failed

    # The nonce claim rolled back with the action transaction — 0 claims, not 1.
    %{rows: [[0]]} =
      SQL.query!(Repo, "SELECT count(*) FROM \"#{prefix}\".\"ash_onetime_nonce_claims\"", [])

    # Second attempt with the SAME proof: re-admitted (the body runs again) — the gap.
    # WHEN THE FENCE LANDS: assert this is {:error, %AshOnetime.Error{code: :nonce_already_used}}.
    assert {:error, second_error} =
             Charge
             |> Ash.ActionInput.for_action(:redeem_fail, %{value: 1, proof: "dpop-proof-1"})
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    assert AshOnetime.Error.code(second_error) == :downstream_failed
  end
end
