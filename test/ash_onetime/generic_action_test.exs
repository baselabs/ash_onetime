defmodule AshOnetime.GenericActionTest do
  use ExUnit.Case, async: true

  alias AshOnetime.GenericAction
  alias AshOnetime.Test.ActionExamples.{GenericRun, Resource}

  test "wrapper fails closed without package admission state" do
    input = Ash.ActionInput.for_action(Resource, :redeem, %{value: 7, request_key: "request-7"})

    assert {:error, %AshOnetime.Error{code: :admission_unavailable}} =
             GenericAction.run(input, [original: {GenericRun, [observer: self()]}], %{})

    refute_receive {:generic_run, _arguments}
  end

  test "wrapper invokes the original exactly once only for admitted execution" do
    input =
      Resource
      |> Ash.ActionInput.for_action(:redeem, %{value: 7, request_key: "request-7"})
      |> AshOnetime.Admission.put_test_state(:execute)

    assert {:ok, 7} =
             GenericAction.run(input, [original: {GenericRun, [observer: self()]}], %{})

    assert_receive {:generic_run, %{request_key: "request-7", value: 7}}
    refute_receive {:generic_run, _arguments}
  end
end
