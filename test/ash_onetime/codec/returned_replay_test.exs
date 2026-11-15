defmodule AshOnetime.Codec.ReturnedReplayTest do
  # §2.7.6 through the real store: a generic action that returns a record of another
  # resource replays the stored projection of that record, `:loaded`, with the replay
  # stamp as its only metadata. A nullable return replays both nil and a record.
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase, only: [unique_key: 1]

  alias AshOnetime.Delivery
  alias AshOnetime.Test.ReturnExamples.{Issuer, Receipt}
  alias Ecto.Adapters.SQL

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS "#{prefix}"."ash_onetime_return_receipts" (
        id uuid PRIMARY KEY,
        token text NOT NULL,
        code text
      )
      """,
      []
    )

    :ok
  end

  @tag returned_record_state_mutation: true
  test "a replayed returned record equals the original on its stored fields", %{prefix: prefix} do
    key = unique_key("returned")
    token = unique_key("token")

    assert {:ok, %Receipt{} = original} = run(prefix, :record, %{token: token, request_key: key})
    assert AshOnetime.replayed?(original) == false

    assert {:ok, %Receipt{} = replayed} = run(prefix, :record, %{token: token, request_key: key})

    assert replayed.id == original.id
    assert replayed.token == original.token
    assert replayed.__meta__.state == :loaded
    assert replayed.__metadata__ == %{ash_onetime: %{replayed: true}}
    assert %Ash.NotLoaded{field: :code, type: :attribute} = replayed.code
    assert %Ash.NotLoaded{field: :label} = replayed.label

    # The replay ran nothing: one receipt exists.
    assert receipt_count(prefix, token) == 1
  end

  test "a nullable returned record replays nil and a record", %{prefix: prefix} do
    nil_key = unique_key("returned-nil")
    args = %{token: "t-nil", present?: false, request_key: nil_key}

    assert {:ok, nil} = run(prefix, :maybe_record, args)
    assert {:ok, nil} = run(prefix, :maybe_record, args)

    key = unique_key("returned-present")
    args = %{token: "t-present", present?: true, request_key: key}

    assert {:ok, %Receipt{} = original} = run(prefix, :maybe_record, args)
    assert {:ok, %Receipt{} = replayed} = run(prefix, :maybe_record, args)
    assert replayed.id == original.id
    assert replayed.token == original.token
    assert replayed.__meta__.state == :loaded
    assert replayed.__metadata__ == %{ash_onetime: %{replayed: true}}
  end

  test "deliver/2 returns the record and the value once; the replay returns the record only",
       %{prefix: prefix} do
    key = unique_key("returned-deliver")
    build = fn -> input(prefix, :issue, %{token: "t-deliver", request_key: key}) end

    assert {:ok, %Receipt{} = original, %Delivery{outcome: :executed, values: %{secret: secret}}} =
             AshOnetime.deliver(build.())

    assert byte_size(secret) == 32

    assert {:ok, %Receipt{} = replayed, %Delivery{outcome: :replayed, values: values}} =
             AshOnetime.deliver(build.())

    assert values == %{}
    assert replayed.id == original.id
    assert replayed.token == original.token
    assert replayed.__meta__.state == :loaded
    assert replayed.__metadata__ == %{ash_onetime: %{replayed: true}}
  end

  defp run(prefix, action, args), do: prefix |> input(action, args) |> Ash.run_action()

  defp input(prefix, action, args),
    do: Ash.ActionInput.for_action(Issuer, action, args, tenant: prefix)

  defp receipt_count(prefix, token) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        ~s[SELECT count(*) FROM "#{prefix}"."ash_onetime_return_receipts" WHERE token = $1],
        [token]
      )

    count
  end
end
