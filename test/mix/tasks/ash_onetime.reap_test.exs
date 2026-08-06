defmodule Mix.Tasks.AshOnetime.ReapTest do
  use AshOnetime.Test.StoreCase, async: false

  alias Mix.Tasks.AshOnetime.Reap

  @moduletag :store

  # Comfortably above the migration's 86_400 s (1 day) hard floor.
  @horizon 7 * 86_400

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "Mix task validates inputs and reaps abandoned processing recovery points", %{
    prefix: prefix
  } do
    claim_id = insert_abandoned(prefix, "task-reap")

    Mix.Task.reenable("ash_onetime.reap")

    assert :ok =
             Reap.run([
               "--repo",
               inspect(Repo),
               "--prefix",
               prefix,
               "--batch-size",
               "50",
               "--abandonment-seconds",
               Integer.to_string(@horizon)
             ])

    assert claim_count(prefix, claim_id) == 0

    Mix.Task.reenable("ash_onetime.reap")
    assert_raise Mix.Error, ~r/--repo is required/, fn -> Reap.run([]) end

    Mix.Task.reenable("ash_onetime.reap")

    assert_raise Mix.Error, ~r/--abandonment-seconds/, fn ->
      Reap.run(["--repo", inspect(Repo), "--abandonment-seconds", "3600"])
    end
  end

  defp insert_abandoned(prefix, label) do
    claim_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'processing',
              transaction_timestamp() - interval '40 days',
              transaction_timestamp() - interval '39 days',
              transaction_timestamp() - interval '40 days')
      """,
      [
        Ecto.UUID.dump!(claim_id),
        hash("operation:" <> label),
        hash("scope:" <> label),
        hash("key:" <> label),
        hash("fingerprint:" <> label)
      ]
    )

    claim_id
  end

  defp claim_count(prefix, claim_id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
        [Ecto.UUID.dump!(claim_id)]
      )

    count
  end

  defp relation(prefix, name), do: ~s("#{prefix}"."#{name}")
end
