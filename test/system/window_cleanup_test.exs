defmodule AshOnetime.System.WindowCleanupTest do
  use AshOnetime.Test.StoreCase, async: false

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  @tag cleanup_strictness_mutation: true
  test "cleanup preserves the inclusive replay horizon then removes the first expired instant", %{
    prefix: prefix,
    target: target
  } do
    at_horizon = insert_nonce(prefix, "at-horizon", :equal)
    expired = insert_nonce(prefix, "expired", :expired)

    assert %{rows: [[false]]} =
             SQL.query!(
               Repo,
               "SELECT #{relation(prefix, "ash_onetime_cleanup_eligible")}(transaction_timestamp())",
               []
             )

    assert {:ok, %{idempotency: 0, nonce: 1}} = Store.cleanup(target, 100)
    assert count(prefix, at_horizon) == 1
    assert count(prefix, expired) == 0
  end

  test "window cleanup begins one microsecond after the inclusive boundary" do
    issued_at = ~U[2026-08-05 12:00:00.000000Z]
    horizon = DateTime.add(issued_at, 65, :second)

    assert AshOnetime.Window.cleanup_after(issued_at, 60, 5) ==
             DateTime.add(horizon, 1, :microsecond)
  end

  defp insert_nonce(prefix, label, position) do
    id = Ecto.UUID.generate()

    retain_until =
      if position == :equal,
        do: "transaction_timestamp()",
        else: "transaction_timestamp() - interval '1 microsecond'"

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_nonce_claims")}
        (id, operation_hash, scope_hash, key_hash, issued_at, verifier_id,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, transaction_timestamp() - interval '2 hours', 'system',
              transaction_timestamp() - interval '1 hour', #{retain_until},
              transaction_timestamp() - interval '1 hour')
      """,
      [Ecto.UUID.dump!(id), hash("o:" <> label), hash("s:" <> label), hash("k:" <> label)]
    )

    id
  end

  defp count(prefix, id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM #{relation(prefix, "ash_onetime_nonce_claims")} WHERE id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      )

    count
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
