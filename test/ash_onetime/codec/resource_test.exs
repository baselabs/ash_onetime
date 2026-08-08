defmodule AshOnetime.Codec.ResourceTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Codec.Resource
  alias AshOnetime.Error
  alias AshOnetime.Response
  alias AshOnetime.Store.{Claim, Result}
  alias AshOnetime.Test.ResultExamples.Account

  test "projects declared public fields and rehydrates every other field as not loaded" do
    contract = contract!([:id, :name, :amount])
    account = account()

    assert {:ok, tag, payload} = Resource.encode(account, contract, [])
    assert {:ok, restored} = Resource.decode(tag, payload, contract, [])
    assert restored.__struct__ == Account
    assert restored.id == account.id
    assert restored.name == "Ada"
    assert Decimal.equal?(restored.amount, Decimal.new("12.50"))
    assert %Ash.NotLoaded{field: :sentinel_private, type: :attribute} = restored.sentinel_private
    assert %Ash.NotLoaded{field: :secret, type: :attribute} = restored.secret
    assert %Ash.NotLoaded{field: :parent, type: :relationship} = restored.parent
    assert restored.__metadata__ == %{selected: [:id, :name, :amount]}
    assert restored.__meta__.state == :loaded
  end

  @tag :resource_relationship_leak_mutation
  test "encode rejects a result carrying a loaded relationship" do
    contract = contract!([:id, :name])
    loaded = %{account() | parent: account()}
    assert {:error, %Error{code: :response_value_invalid}} = Resource.encode(loaded, contract, [])
  end

  test "rejects loaded relationships, unloaded selected fields, and forbidden fields" do
    contract = contract!([:id, :name])

    for invalid <- [
          %{account() | parent: nil},
          %{account() | parent: []},
          %{account() | parent: account()},
          %{
            account()
            | parent: %Ash.NotLoaded{field: :name, type: :relationship, resource: Account}
          },
          %{account() | name: %Ash.NotLoaded{field: :name, type: :attribute, resource: Account}},
          %{account() | name: %Ash.ForbiddenField{field: :name, type: :attribute}}
        ] do
      assert {:error, %Error{code: :response_value_invalid}} =
               Resource.encode(invalid, contract, [])
    end
  end

  test "a configured max_response_bytes bounds the encoded resource payload" do
    response = %AshOnetime.Resource.Response{
      codec: Resource,
      fields: [:id, :name, :amount],
      classify: AshOnetime.Test.StoreClassifier
    }

    {:ok, capped} =
      Response.contract(Account, :create_account, response, %{limits: [max_response_bytes: 1]})

    assert AshOnetime.Codec.max_bytes(capped) == 1
    assert {:error, %Error{}} = Response.encode(account(), capped, [])

    {:ok, uncapped} = Response.contract(Account, :create_account, response, %{})
    assert {:ok, _encoded} = Response.encode(account(), uncapped, [])
  end

  test "a present-but-nil trusted limits key falls back to the hard default" do
    # trusted[:limits] => nil (key present, value nil) must not raise or reject — it should
    # fall back to the hard default, identical to trusted having no :limits key at all.
    response = %AshOnetime.Resource.Response{
      codec: Resource,
      fields: [:id, :name, :amount],
      classify: AshOnetime.Test.StoreClassifier
    }

    assert {:ok, _contract} =
             Response.contract(Account, :create_account, response, %{limits: nil})
  end

  test "custom codecs receive and return only the normalized resource projection" do
    contract = custom_contract!(AshOnetime.Test.ObservingCodec, observer: self())

    original =
      account()
      |> Map.put(:__metadata__, %{secret: "LEAK"})
      |> Map.put(:sentinel_private, "TASK4_SENTINEL_SECRET")
      |> Map.put(:secret, "sensitive")

    assert {:ok, encoded} = Response.encode(original, contract, [])
    assert_receive {:codec_received, received}
    assert %Ash.NotLoaded{} = received.sentinel_private
    assert %Ash.NotLoaded{} = received.secret
    assert received.__metadata__ == %{selected: [:id, :name]}
    refute Map.has_key?(received.__metadata__, :secret)
    assert encoded.result == received
    assert {:ok, ^received} = Response.replay(store_result(encoded), contract, [])

    loaded = %{original | parent: account()}
    assert {:error, %Error{code: :response_value_invalid}} = Response.encode(loaded, contract, [])
    refute_receive {:codec_received, _value}
  end

  test "custom decoder cannot restore metadata or undeclared resource data" do
    leaked = account() |> Map.put(:__metadata__, %{secret: "LEAK"})
    contract = custom_contract!(AshOnetime.Test.FixedDecodeCodec, decoded: leaked)

    assert {:error, %Error{code: :response_value_invalid}} =
             Response.encode(account(), contract, [])

    encoded = %{
      codec: "ao:fixed-decode:#{Base.url_encode64(contract.digest, padding: false)}",
      payload: <<>>,
      digest: :crypto.hash(:sha256, <<>>)
    }

    assert {:error, %Error{code: :response_value_invalid}} =
             Response.replay(store_result(encoded), contract, [])
  end

  test "non-null selected fields reject nil before dump and after cast" do
    contract = contract!([:id, :name])

    assert {:error, %Error{code: :response_value_invalid}} =
             Resource.encode(%{account() | name: nil}, contract, [])

    {:ok, tag, payload} = Resource.encode(account(), contract, [])
    envelope = Jason.decode!(payload)
    tampered = put_in(envelope, ["value", "name"], nil) |> Jason.encode!()

    assert {:error, %Error{code: :response_value_invalid}} =
             Resource.decode(tag, tampered, contract, [])
  end

  test "destroy result modes restore exact ok or a deleted record" do
    no_return =
      %AshOnetime.Resource.Response{
        codec: Resource,
        fields: [],
        classify: AshOnetime.Test.StoreClassifier
      }

    returned =
      %AshOnetime.Resource.Response{
        codec: Resource,
        fields: [:id, :name],
        classify: AshOnetime.Test.StoreClassifier
      }

    assert {:ok, no_return_contract} =
             Response.contract(Account, :destroy_account, no_return, %{})

    assert {:ok, tag, payload} = Resource.encode(:ok, no_return_contract, [])
    assert {:ok, :ok} = Resource.decode(tag, payload, no_return_contract, [])

    assert {:ok, returned_contract} =
             Response.contract(Account, :destroy_account, returned, %{return_destroyed?: true})

    assert {:ok, tag, payload} = Resource.encode(account(), returned_contract, [])
    assert {:ok, restored} = Resource.decode(tag, payload, returned_contract, [])
    assert restored.__meta__.state == :deleted
  end

  @tag response_allowlist_mutation: true
  test "undeclared sentinel private payload field is terminal" do
    contract = contract!([:id, :name])
    {:ok, tag, payload} = Resource.encode(account(), contract, [])
    envelope = Jason.decode!(payload)
    value = Map.put(envelope["value"], "sentinel_private", "TASK4_SENTINEL_SECRET")
    tampered = Jason.encode!(Map.put(envelope, "value", value))

    encoded = %{
      codec: "ao:#{tag}:#{Base.url_encode64(contract.digest, padding: false)}",
      payload: tampered,
      digest: :crypto.hash(:sha256, tampered)
    }

    assert {:error, %Error{code: :response_fields_invalid}} =
             Response.replay(store_result(encoded), contract, [])
  end

  defp contract!(fields) do
    response = %AshOnetime.Resource.Response{
      codec: Resource,
      fields: fields,
      classify: AshOnetime.Test.StoreClassifier
    }

    {:ok, contract} = Response.contract(Account, :create_account, response, %{})
    contract
  end

  defp custom_contract!(codec, codec_opts) do
    response = %AshOnetime.Resource.Response{
      codec: codec,
      fields: [:id, :name],
      classify: AshOnetime.Test.StoreClassifier,
      codec_opts: codec_opts
    }

    {:ok, contract} = Response.contract(Account, :create_account, response, %{})
    contract
  end

  defp account do
    Account
    |> struct(%{
      id: Ash.UUID.generate(),
      name: "Ada",
      amount: Decimal.new("12.50"),
      sentinel_private: "TASK4_SENTINEL_SECRET",
      secret: "never-store"
    })
    |> Ecto.put_meta(state: :loaded)
  end

  defp store_result(encoded) do
    now = DateTime.utc_now()

    claim = %Claim{
      strategy: :idempotency,
      id: Ecto.UUID.generate(),
      operation_hash: :binary.copy(<<1>>, 32),
      scope_hash: :binary.copy(<<2>>, 32),
      key_hash: :binary.copy(<<3>>, 32),
      fingerprint: :binary.copy(<<4>>, 32),
      state: :complete,
      response_partition: Date.utc_today(),
      response_codec: encoded.codec,
      response_digest: encoded.digest,
      admitted_at: now,
      retain_until: DateTime.add(now, 60),
      inserted_at: now
    }

    %Result{
      status: :complete,
      claim: claim,
      payload: encoded.payload,
      admission_dispatch: :sent,
      transaction: :open
    }
  end
end
