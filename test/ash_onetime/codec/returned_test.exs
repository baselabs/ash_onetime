defmodule AshOnetime.Codec.ReturnedTest do
  # §2.7.6: a generic action that returns a resource record stores the projection its
  # `fields` allow, validated against the returned resource, not the action's resource.
  # The replayed struct is `:loaded`, because the action returned a persisted record.
  use ExUnit.Case, async: true

  alias AshOnetime.Codec.Resource
  alias AshOnetime.Error
  alias AshOnetime.Response
  alias AshOnetime.Test.ResultExamples.{Account, Receipt}

  @tag returned_record_validation_mutation: true
  test "a generic action's fields are valid on the returned resource and not on the action's" do
    for action <- [:receipt_struct, :maybe_receipt] do
      assert {:ok, contract} = contract(action, [:id, :token])
      assert contract.record_resource == Receipt
      assert contract.result_mode == {:resource, :returned}

      for fields <- [[:name], [:amount], [:id, :name]] do
        assert {:error, %Error{code: :response_fields_invalid}} = contract(action, fields),
               inspect({action, fields})
      end
    end
  end

  @tag returned_record_embedded_mutation: true
  test "an embedded return is a value: its fields are refused and it is stored whole" do
    for action <- [:stamp, :stamp_struct] do
      assert {action, {:error, %Error{code: :response_contract_invalid}}} =
               {action, contract(action, [:token])}

      assert {:ok, contract} = contract(action, [])
      assert contract.record_resource == nil
      assert {:typed, _type, _constraints, false} = contract.result_mode
    end
  end

  test "a CRUD action's fields are valid on its own resource and not on another's" do
    assert {:ok, contract} = contract(:create_account, [:id, :name])
    assert contract.record_resource == Account

    assert {:error, %Error{code: :response_fields_invalid}} =
             contract(:create_account, [:token])
  end

  test "a field the returned resource keeps private is refused" do
    assert {:error, %Error{code: :response_fields_invalid}} =
             contract(:receipt_struct, [:code])
  end

  test "the returned resource is part of the contract digest" do
    {:ok, generic} = contract(:receipt_struct, [:id])
    {:ok, crud} = contract(:create_account, [:id])
    refute generic.digest == crud.digest
  end

  @tag returned_record_state_mutation: true
  test "a returned record replays with its stored fields, loaded, and no metadata" do
    for action <- [:receipt_struct, :maybe_receipt] do
      {:ok, contract} = contract(action, [:id, :token])
      receipt = receipt()

      assert {:ok, tag, payload} = Resource.encode(receipt, contract, [])
      assert {:ok, restored} = Resource.decode(tag, payload, contract, [])

      assert restored.__struct__ == Receipt
      assert restored.id == receipt.id
      assert restored.token == receipt.token
      assert %Ash.NotLoaded{field: :code, type: :attribute} = restored.code
      assert restored.__meta__.state == :loaded
      assert restored.__metadata__ == %{}
    end
  end

  test "a nullable return stores nil and a record; a non-nullable return refuses nil" do
    {:ok, nullable} = contract(:maybe_receipt, [:id, :token])
    assert nullable.allow_nil?

    assert {:ok, tag, payload} = Resource.encode(nil, nullable, [])
    assert {:ok, nil} = Resource.decode(tag, payload, nullable, [])

    receipt = receipt()
    assert {:ok, tag, payload} = Resource.encode(receipt, nullable, [])
    assert {:ok, %Receipt{} = restored} = Resource.decode(tag, payload, nullable, [])
    assert restored.token == receipt.token

    for action <- [:receipt_struct] do
      {:ok, strict} = contract(action, [:id, :token])
      refute strict.allow_nil?
      assert {:error, %Error{}} = Resource.encode(nil, strict, [])

      # A stored nil does not decode under a contract that forbids it.
      assert {:error, %Error{}} =
               Resource.decode(tag(nullable), nil_payload(nullable), strict, [])
    end
  end

  test "a record of another resource is refused" do
    {:ok, contract} = contract(:receipt_struct, [:id])
    account = struct(Account, id: Ash.UUID.generate(), name: "Ada")
    assert {:error, %Error{}} = Resource.encode(account, contract, [])
  end

  defp contract(action, fields) do
    response = %AshOnetime.Resource.Response{
      codec: Resource,
      fields: fields,
      classify: AshOnetime.Test.StoreClassifier
    }

    Response.contract(Account, action, response, %{})
  end

  defp receipt do
    Receipt
    |> struct(%{id: Ash.UUID.generate(), token: "receipt-token", code: "kept-private"})
    |> Ecto.put_meta(state: :loaded)
  end

  defp tag(contract) do
    {:ok, tag, _payload} = Resource.encode(nil, contract, [])
    tag
  end

  defp nil_payload(contract) do
    {:ok, _tag, payload} = Resource.encode(nil, contract, [])
    payload
  end
end
