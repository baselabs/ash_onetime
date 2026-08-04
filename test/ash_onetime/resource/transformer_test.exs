defmodule AshOnetime.Resource.TransformerTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Resource.Info
  alias AshOnetime.Test.Support.Resource

  test "normalizes durations and injects each wrapper exactly once" do
    charge = Info.protection(Resource, :charge)
    redeem = Info.protection(Resource, :redeem)

    assert charge.retention == 86_400
    assert charge.response.opts[:fields] == [:id, :account_id, :amount]
    assert charge.response.opts[:classify] == AshOnetime.Test.Support.ResponseClassifier
    assert charge.response.opts[:codec_option] == :preserved
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
end
