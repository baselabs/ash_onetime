defmodule AshOnetime.Store.RollForwardTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Store
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @moduletag :store

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  describe "the DEFAULT drain (claim-scoped)" do
    test "deletes a past-retention claim AND its stranded DEFAULT payload", %{prefix: prefix} do
      claim_id = seed_default_claim!(prefix, past_retention: true)

      assert claim_exists?(prefix, claim_id)
      assert payload_exists?(prefix, claim_id)

      run_drain!(prefix)

      refute claim_exists?(prefix, claim_id),
             "past-retention claim should be drained (deleted via the trigger-safe claim path)"

      refute payload_exists?(prefix, claim_id),
             "the stranded DEFAULT payload should be gone after the claim-scoped drain"
    end

    test "leaves a within-retention stranded payload alone", %{prefix: prefix} do
      claim_id = seed_default_claim!(prefix, past_retention: false)

      run_drain!(prefix)

      # Within retention: the claim and its payload survive (re-completion is a new execution).
      assert claim_exists?(prefix, claim_id)
      assert payload_exists?(prefix, claim_id)
    end
  end

  describe "the silent-degradation fix (SEC-5 E2E — ADR-0001:65 bounded retention)" do
    # The blocking design-adversarial challenge: SEC-5's fix must RESTORE bounded retention, not
    # just paper over it. The proof: after roll_partitions, a payload whose response_partition
    # falls in a rolled-forward month routes to a NAMED partition (not _default), so cleanup can
    # drop it at retention. Before the roll, that payload would strand in _default forever.

    test "after a roll, a forward-month payload routes to a named partition, not _default", %{
      prefix: prefix,
      target: target
    } do
      # Roll forward far enough that month ~+14 has a named partition (install covers 0..12).
      assert {:ok, %{partitions_created: _}} = Store.roll_partitions(target, 15)

      forward_date = Date.utc_today() |> Date.beginning_of_month() |> shift_month(14)
      claim_id = Ecto.UUID.generate()

      # Insert a payload for that forward month — it must route to the named partition.
      SQL.query!(
        Repo,
        """
        INSERT INTO "#{prefix}"."ash_onetime_response_payloads" (partition_date, claim_id, encoded_response)
        VALUES ($1, $2::uuid, $3)
        """,
        [forward_date, Ecto.UUID.dump!(claim_id), <<0>>]
      )

      %{rows: [[routed]]} =
        SQL.query!(
          Repo,
          """
          SELECT tableoid::regclass::text
          FROM "#{prefix}"."ash_onetime_response_payloads" WHERE claim_id = $1::uuid
          """,
          [Ecto.UUID.dump!(claim_id)]
        )

      routed_name = routed |> String.split(".") |> List.last()

      assert routed_name =~ ~r/^ash_onetime_response_payloads_\d{4}_\d{2}$/,
             "forward-month payload should route to a named partition; routed to #{routed_name}"

      refute routed_name =~ "_default",
             "forward-month payload must NOT route to _default after the roll (that is the SEC-5 defect)"
    end
  end

  defp run_drain!(prefix) do
    target = Postgres.for_repo(Repo, prefix)
    assert {:ok, _} = Store.roll_partitions(target, 1)
    assert {:ok, _} = Store.cleanup(target, 100, 0)
  end

  # Seed a complete claim whose payload is stranded in _default. retain_until is set far in the
  # past (past retention) or the near future (within retention) to exercise both drain branches.
  defp seed_default_claim!(prefix, past_retention: past?) do
    id = Ecto.UUID.generate()
    # response_partition far in the future so the payload routes to _default (no named partition
    # covers 2100). admitted_at in the past; retain_until per the branch.
    admitted = ~U[2000-01-01 00:00:00Z]
    retain = if past?, do: ~U[2000-01-02 00:00:00Z], else: ~U[9999-12-31 23:59:59Z]

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{prefix}"."ash_onetime_idempotency_claims"
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         response_partition, response_codec, response_digest,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'complete',
              '2100-01-01', 'test', $6,
              $7, $8, $7)
      """,
      [
        Ecto.UUID.dump!(id),
        :crypto.hash(:sha256, "op"),
        :crypto.hash(:sha256, "scope"),
        :crypto.hash(:sha256, "key"),
        :crypto.hash(:sha256, "fp"),
        :crypto.hash(:sha256, "digest"),
        admitted,
        retain
      ]
    )

    # Insert the payload directly into the parent; with response_partition 2100-01-01 it routes
    # to _default (the only partition covering that date).
    SQL.query!(
      Repo,
      """
      INSERT INTO "#{prefix}"."ash_onetime_response_payloads" (partition_date, claim_id, encoded_response)
      VALUES ('2100-01-01', $1::uuid, $2)
      """,
      [Ecto.UUID.dump!(id), <<0>>]
    )

    id
  end

  defp claim_exists?(prefix, id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM \"#{prefix}\".\"ash_onetime_idempotency_claims\" WHERE id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      )

    count == 1
  end

  defp payload_exists?(prefix, id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM \"#{prefix}\".\"ash_onetime_response_payloads\" WHERE claim_id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      )

    count == 1
  end

  defp shift_month(date, offset) do
    month_index = date.year * 12 + date.month - 1 + offset
    Date.new!(div(month_index, 12), rem(month_index, 12) + 1, 1)
  end
end
