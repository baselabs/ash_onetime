defmodule AshOnetime.ReplaySafetyTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.ReplayChanges.{Aware, Pure}

  test "private replay marker is absent by default and visible only after replay admission" do
    input = Ash.ActionInput.for_action(Resource, :redeem, %{value: 1, request_key: "request-1"})
    refute AshOnetime.Admission.replay?(input)

    replay = AshOnetime.Admission.put_test_state(input, :replay, 1)
    assert AshOnetime.Admission.replay?(replay)
  end

  test "declarations distinguish pure and marker-aware callbacks" do
    assert :pure == Pure.replay_safety([])
    assert :replay_aware == Aware.replay_safety([])

    assert Pure.replay_capabilities([]) == %{
             notifications: false,
             effects: false,
             around_action: false,
             marker: :unused
           }

    assert Aware.replay_capabilities(transaction_ledger?: true) ==
             %{
               notifications: false,
               effects: true,
               around_action: false,
               marker: :consumed
             }
  end
end
