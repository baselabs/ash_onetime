defmodule AshOnetime.Codec.ActionResultTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Codec.ActionResult
  alias AshOnetime.Error
  alias AshOnetime.Response
  alias AshOnetime.Test.ResultExamples.Account

  for {action, value} <- [
        decimal_result: Decimal.new("12.50"),
        uuid_result: Ash.UUID.generate(),
        datetime_result: ~U[2026-08-04 12:00:00.123456Z],
        array_result: [1, 2, 3],
        map_result: %{"safe" => [1, 2]}
      ] do
    test "round trips declared #{action} return type" do
      action = unquote(action)
      value = unquote(Macro.escape(value))
      contract = contract!(action)
      assert {:ok, tag, payload} = ActionResult.encode(value, contract, [])
      assert {:ok, restored} = ActionResult.decode(tag, payload, contract, [])
      assert Ash.Type.equal?(contract.type, value, restored)
    end
  end

  test "nil and ok follow only their declared result modes" do
    nullable = contract!(:nullable_result)
    nothing = contract!(:nothing)
    assert {:ok, tag, payload} = ActionResult.encode(nil, nullable, [])
    assert {:ok, nil} = ActionResult.decode(tag, payload, nullable, [])
    assert {:ok, tag, payload} = ActionResult.encode(:ok, nothing, [])
    assert {:ok, :ok} = ActionResult.decode(tag, payload, nothing, [])

    assert {:error, %Error{code: :response_value_invalid}} =
             ActionResult.encode(:ok, nullable, [])
  end

  test "rejects dangerous and nested Ash resource results before dumping" do
    contract = contract!(:map_result)

    for value <- [fn -> :bad end, self(), make_ref(), %RuntimeError{message: "secret"}, account()] do
      assert {:error, %Error{code: :response_value_invalid}} =
               ActionResult.encode(value, contract, [])
    end
  end

  defp contract!(action) do
    response = %AshOnetime.Resource.Response{
      codec: ActionResult,
      opts: [fields: [], classify: AshOnetime.Test.StoreClassifier]
    }

    {:ok, contract} = Response.contract(Account, action, response, %{})
    contract
  end

  defp account, do: struct(Account, id: Ash.UUID.generate(), name: "Nested")
end
