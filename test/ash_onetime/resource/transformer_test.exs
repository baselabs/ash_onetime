defmodule AshOnetime.Resource.TransformerTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Resource.Info
  alias AshOnetime.Test.Support.Resource

  test "normalizes durations and injects each wrapper exactly once" do
    charge = Info.protection(Resource, :charge)
    redeem = Info.protection(Resource, :redeem)

    assert charge.retention == 86_400
    assert charge.response.fields == [:id, :account_id, :amount]
    assert charge.response.classify == AshOnetime.Test.Support.ResponseClassifier
    assert redeem.window == [max_age: 600, clock_skew: 15]

    action = Ash.Resource.Info.action(Resource, :charge)

    assert 1 ==
             Enum.count(action.changes, fn
               %{change: {AshOnetime.Change, _opts}} -> true
               _other -> false
             end)

    generic = Ash.Resource.Info.action(Resource, :redeem)

    assert {AshOnetime.GenericAction, opts} = generic.run
    assert opts[:original] == {AshOnetime.Test.Support.GenericRun, []}
  end

  test "landed response declaration executes the exact codec boundary" do
    protection = Info.protection(Resource, :charge)

    assert {:ok, contract} =
             AshOnetime.Response.contract(Resource, :charge, protection.response, %{})

    value =
      Resource
      |> struct(id: Ash.UUID.generate(), account_id: Ash.UUID.generate(), amount: 10)
      |> Ecto.put_meta(state: :loaded)

    assert {:ok, encoded} = AshOnetime.Response.encode(value, contract, [])
    assert encoded.raw_tag == "test"
    assert encoded.codec =~ "ao:test:"
    assert encoded.result.id == value.id
    assert encoded.result.amount == 10
  end
end
