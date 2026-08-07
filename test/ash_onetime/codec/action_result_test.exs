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

  test "decode rejects an envelope with a mismatched adapter, shape, or contract digest" do
    contract = contract!(:map_result)
    value = %{"safe" => [1, 2]}
    assert {:ok, tag, payload} = ActionResult.encode(value, contract, [])
    assert {:ok, ^value} = ActionResult.decode(tag, payload, contract, [])

    envelope = Jason.decode!(payload)

    for tampered <- [
          Map.put(envelope, "adapter", "not-the-adapter"),
          Map.put(envelope, "shape", "not-a-declared-shape"),
          Map.put(envelope, "contract", Base.url_encode64("wrong-digest", padding: false))
        ] do
      assert {:error, %Error{code: :response_payload_invalid}} =
               ActionResult.decode(tag, Jason.encode!(tampered), contract, [])
    end
  end

  test "decode rejects an envelope carrying an unexpected field set" do
    contract = contract!(:map_result)
    assert {:ok, tag, payload} = ActionResult.encode(%{"safe" => [1]}, contract, [])
    envelope = Jason.decode!(payload)

    extra = Map.put(envelope, "extra", "field")
    missing = Map.delete(envelope, "value")

    for bad <- [extra, missing] do
      assert {:error, %Error{code: :response_payload_invalid}} =
               ActionResult.decode(tag, Jason.encode!(bad), contract, [])
    end
  end

  test "decode fails closed on an adversarial over-wide and deeply nested value" do
    contract = contract!(:map_result)
    assert {:ok, tag, payload} = ActionResult.encode(%{"safe" => [1]}, contract, [])
    envelope = Jason.decode!(payload)

    over_wide = Map.put(envelope, "value", Enum.to_list(1..1_000))
    # A structurally deep value trips the hand-rolled json_preflight scanner on the DECODE path.
    deep_payload = String.duplicate("[", 100) <> "1" <> String.duplicate("]", 100)

    assert {:error, %Error{code: over_wide_code}} =
             ActionResult.decode(tag, Jason.encode!(over_wide), contract, [])

    assert over_wide_code in [:response_payload_invalid, :response_value_invalid]

    assert {:error, %Error{code: :response_payload_invalid}} =
             ActionResult.decode(tag, deep_payload, contract, [])
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
