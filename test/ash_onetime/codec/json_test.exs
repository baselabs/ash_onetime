defmodule AshOnetime.Codec.JSONTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Codec.JSON
  alias AshOnetime.Error
  alias AshOnetime.Response
  alias AshOnetime.Test.ResultExamples.Account

  test "typed JSON dispatches resource and generic contracts without tag substitution" do
    resource = contract!(:create_account, [:id, :name])
    generic = contract!(:array_result, [])

    account =
      struct(Account, id: Ash.UUID.generate(), name: "Ada") |> Ecto.put_meta(state: :loaded)

    assert {:ok, tag, payload} = JSON.encode(account, resource, [])
    assert {:ok, %Account{name: "Ada"}} = JSON.decode(tag, payload, resource, [])

    assert {:error, %Error{code: :response_codec_mismatch}} =
             JSON.decode("wrong", payload, resource, [])

    assert {:ok, tag, payload} = JSON.encode([1, 2], generic, [])
    assert {:ok, [1, 2]} = JSON.decode(tag, payload, generic, [])
  end

  test "malformed, duplicate-key, empty, deep, and oversized JSON reject" do
    contract = contract!(:array_result, [])

    for payload <- [
          <<>>,
          "{}",
          ~s({"adapter":"action_result","adapter":"resource"}),
          String.duplicate("[", 100)
        ] do
      assert {:error, %Error{}} = JSON.decode(JSON.format_tag(), payload, contract, [])
    end
  end

  test "structural ceilings accept exact boundaries and reject one-over" do
    entries = contract!(:array_result, [], max_response_entries: 4)
    assert {:ok, _tag, _payload} = JSON.encode([1, 2, 3, 4], entries, [])

    assert {:error, %Error{code: :response_value_invalid}} =
             JSON.encode([1, 2, 3, 4, 5], entries, [])

    depth = contract!(:array_result, [], max_response_depth: 2)
    assert {:ok, _tag, _payload} = JSON.encode([1], depth, [])
    assert {:error, %Error{code: :response_value_invalid}} = JSON.encode([[1]], depth, [])

    nodes = contract!(:array_result, [], max_response_nodes: 10)
    assert {:ok, _tag, _payload} = JSON.encode([1], nodes, [])
    assert {:error, %Error{code: :response_payload_invalid}} = JSON.encode([1, 2], nodes, [])

    scalar = contract!(:nullable_result, [], max_response_scalar_bytes: 43)
    assert {:ok, _tag, _payload} = JSON.encode(String.duplicate("a", 43), scalar, [])

    assert {:error, %Error{code: :response_value_invalid}} =
             JSON.encode(String.duplicate("a", 44), scalar, [])
  end

  test "structural ceilings cannot be widened beyond package maxima" do
    for limits <- [
          [max_response_depth: 33],
          [max_response_nodes: 100_001],
          [max_response_entries: 10_001],
          [max_response_scalar_bytes: 16_777_217]
        ] do
      response = %AshOnetime.Resource.Response{
        codec: JSON,
        opts: [fields: [], classify: AshOnetime.Test.StoreClassifier, limits: limits]
      }

      assert {:error, %Error{code: :response_contract_invalid}} =
               Response.contract(Account, :array_result, response, %{})
    end
  end

  defp contract!(action, fields, limits \\ []) do
    response = %AshOnetime.Resource.Response{
      codec: JSON,
      opts: [fields: fields, classify: AshOnetime.Test.StoreClassifier, limits: limits]
    }

    {:ok, contract} = Response.contract(Account, action, response, %{})
    contract
  end
end
