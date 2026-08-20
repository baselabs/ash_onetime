defmodule AshOnetime.Codec.ResponseTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Error
  alias AshOnetime.Response
  alias AshOnetime.Store.{Claim, Result}
  alias AshOnetime.Test.{FixedEmptyCodec, LongTagCodec, StoreClassifier}
  alias AshOnetime.Test.ResultExamples.Account

  @fixed_nullable_binding "ao:fixed-empty:qOrwDE5KM8cy6ap184HN_WWByO6f3n_UOFGOz-ik3Sc"

  test "fixed custom zero-byte codec is contract-bound on first result and replay" do
    contract = contract!(:nullable_result, FixedEmptyCodec, value: "fixed")
    assert {:ok, encoded} = Response.encode("fixed", contract, [])
    assert encoded.payload == <<>>
    assert byte_size(encoded.codec) == 58
    assert encoded.digest == :crypto.hash(:sha256, <<>>)
    assert encoded.result == "fixed"
    assert {:ok, "fixed"} = Response.replay(store_result(encoded), contract, [])
  end

  @tag return_type_mutation: true
  test "fixed bytes bind the live return contract before custom decode" do
    contract = contract!(:nullable_result, FixedEmptyCodec, value: "fixed")

    fixed = %{
      codec: @fixed_nullable_binding,
      payload: <<>>,
      digest: :crypto.hash(:sha256, <<>>)
    }

    assert {:ok, "fixed"} = Response.replay(store_result(fixed), contract, [])
  end

  test "codec options are bound into the digest so stored bytes cannot be reinterpreted" do
    stored = contract!(:nullable_result, FixedEmptyCodec, value: "fixed")
    reinterpret = contract!(:nullable_result, FixedEmptyCodec, value: "attacker")

    refute stored.digest == reinterpret.digest

    assert {:ok, encoded} = Response.encode("fixed", stored, [])

    # The same empty payload replayed under different codec options must fail closed,
    # never silently decode to the attacker's substituted value.
    assert {:error, %Error{code: :response_contract_mismatch}} =
             Response.replay(store_result(encoded), reinterpret, [])
  end

  test "81-byte raw tags fit exactly and malformed bindings are terminal" do
    contract = contract!(:nullable_result, LongTagCodec, [])
    assert {:ok, encoded} = Response.encode("value", contract, [])
    assert byte_size(encoded.codec) == 128

    for binding <- [
          "",
          "ao:bad",
          "ao:bad:bad",
          encoded.codec <> ":extra",
          String.duplicate("a", 129)
        ] do
      result = put_in(store_result(encoded).claim.response_codec, binding)

      assert {:error, %Error{code: :response_persisted_state_invalid}} =
               Response.replay(result, contract, [])
    end
  end

  test "corrupt digest, codec, and incomplete Store results are terminal" do
    contract = contract!(:nullable_result, FixedEmptyCodec, value: "fixed")
    {:ok, encoded} = Response.encode("fixed", contract, [])
    valid = store_result(encoded)

    assert {:error, %Error{code: :response_digest_mismatch}} =
             Response.replay(
               put_in(valid.claim.response_digest, :binary.copy(<<0>>, 32)),
               contract,
               []
             )

    assert {:error, %Error{code: :response_persisted_state_invalid}} =
             Response.replay(%{valid | status: :processing}, contract, [])

    invalid_partition = put_in(valid.claim.response_partition, nil)

    assert {:error, %Error{code: :response_persisted_state_invalid}} =
             Response.replay(invalid_partition, contract, [])

    wrong_codec =
      put_in(
        valid.claim.response_codec,
        "ao:other:#{Base.url_encode64(contract.digest, padding: false)}"
      )

    assert {:error, %Error{code: :response_codec_mismatch}} =
             Response.replay(wrong_codec, contract, [])
  end

  test "live contract rejects stale resource field declarations" do
    for fields <- [
          [:id, :id],
          [:sentinel_private],
          [:secret],
          [:parent],
          [:__metadata__],
          [:unknown]
        ] do
      response = %AshOnetime.Resource.Response{
        codec: AshOnetime.Codec.Resource,
        fields: fields,
        classify: StoreClassifier
      }

      assert {:error, %Error{code: :response_fields_invalid}} =
               Response.contract(Account, :create_account, response, %{})
    end
  end

  test "field order and trusted destroy mode are contract-bound" do
    response = fn fields ->
      %AshOnetime.Resource.Response{
        codec: AshOnetime.Codec.Resource,
        fields: fields,
        classify: StoreClassifier
      }
    end

    assert {:ok, ordered} =
             Response.contract(Account, :create_account, response.([:id, :name]), %{})

    assert {:ok, reversed} =
             Response.contract(Account, :create_account, response.([:name, :id]), %{})

    refute ordered.digest == reversed.digest

    assert {:ok, no_return} = Response.contract(Account, :destroy_account, response.([]), %{})

    assert {:ok, returned} =
             Response.contract(Account, :destroy_account, response.([:id]), %{
               return_destroyed?: true
             })

    assert no_return.result_mode == :ok
    assert returned.result_mode == {:resource, :deleted}
    refute no_return.digest == returned.digest
  end

  test "generic custom codecs cannot receive or return dangerous values" do
    port = Port.open({:spawn, "true"}, [])

    dangerous_values = [
      self(),
      port,
      make_ref(),
      fn -> :bad end,
      {:error, :secret},
      %Ash.Notifier.Notification{metadata: %{secret: "LEAK"}}
    ]

    for dangerous <- dangerous_values do
      contract = contract!(:map_result, FixedEmptyCodec, value: dangerous)

      assert {:error, %Error{code: :response_value_invalid}} =
               Response.encode(dangerous, contract, [])

      replay_contract =
        contract!(:map_result, AshOnetime.Test.FixedDecodeCodec, decoded: dangerous)

      fixed = %{
        codec: "ao:fixed-decode:#{Base.url_encode64(replay_contract.digest, padding: false)}",
        payload: <<>>,
        digest: :crypto.hash(:sha256, <<>>)
      }

      assert {:error, %Error{code: :response_value_invalid}} =
               Response.replay(store_result(fixed), replay_contract, [])
    end
  end

  test "replay rejects every impossible complete Result and Claim invariant" do
    contract = contract!(:nullable_result, FixedEmptyCodec, value: "fixed")
    {:ok, encoded} = Response.encode("fixed", contract, [])
    valid = store_result(encoded)

    inserted_after_admission =
      put_in(valid.claim.inserted_at, DateTime.add(valid.claim.admitted_at, 1, :microsecond))

    assert {:ok, "fixed"} = Response.replay(inserted_after_admission, contract, [])

    invalid_results = [
      %{valid | reason: :corrupt_payload},
      put_in(valid.claim.id, "invalid"),
      put_in(valid.claim.logical_partition, nil),
      put_in(valid.claim.logical_partition, ""),
      put_in(valid.claim.logical_partition, String.duplicate("a", 256)),
      put_in(valid.claim.logical_partition, <<0>>),
      put_in(valid.claim.logical_partition, <<255>>),
      put_in(valid.claim.operation_hash, <<1>>),
      put_in(valid.claim.scope_hash, <<1>>),
      put_in(valid.claim.key_hash, <<1>>),
      put_in(valid.claim.fingerprint, nil),
      put_in(valid.claim.issued_at, valid.claim.admitted_at),
      put_in(valid.claim.expires_at, valid.claim.retain_until),
      put_in(valid.claim.verifier_id, "verifier"),
      put_in(valid.claim.response_codec, ""),
      put_in(valid.claim.response_digest, <<1>>),
      put_in(valid.claim.inserted_at, DateTime.add(valid.claim.admitted_at, -1, :microsecond)),
      put_in(valid.claim.retain_until, valid.claim.admitted_at)
    ]

    for invalid <- invalid_results do
      assert {:error, %Error{code: :response_persisted_state_invalid}} =
               Response.replay(invalid, contract, [])
    end
  end

  @tag response_limits_unknown_key_mutation: true
  test "response limits reject unknown option keys (no silent drop)" do
    # After ARCH-8, the response entity no longer carries its own `limits`; the response-relevant
    # limits flow through trusted[:limits] (the unified protect-level vocabulary). A typo'd key
    # (max_respomse_bytes) is NEITHER a response key NOR a known protect-only key, so the
    # response_limit/1 selector's typo-reject path fires — it is rejected, not silently dropped
    # to the hard default (adversarial C1). RED if the selector's typo guard is removed.
    response = %AshOnetime.Resource.Response{
      codec: AshOnetime.Codec.Resource,
      fields: [:id, :name, :amount],
      classify: StoreClassifier
    }

    assert {:error, %Error{code: :response_contract_invalid}} =
             Response.contract(Account, :create_account, response, %{
               limits: [max_respomse_bytes: 1]
             })
  end

  test "the response contract selects out known protect-only limit keys but rejects typos" do
    # A known protect-only key (max_key_bytes) is valid on protect — the selector selects it OUT
    # (it bounds the key path, not the response codec), and the contract succeeds. A typo
    # (max_respomse_bytes) is neither a response key nor a known protect-only key — rejected.
    # This pins that the two selector paths (select-out vs reject) are distinct.
    response = %AshOnetime.Resource.Response{
      codec: AshOnetime.Codec.Resource,
      fields: [:id, :name, :amount],
      classify: StoreClassifier
    }

    assert {:ok, _contract} =
             Response.contract(Account, :create_account, response, %{
               limits: [max_key_bytes: 4096]
             })

    assert {:error, %Error{code: :response_contract_invalid}} =
             Response.contract(Account, :create_account, response, %{
               limits: [max_respomse_bytes: 1]
             })
  end

  test "every protect-only limit key is selected out without being mistaken for a typo" do
    # diff-review F1: the protect-only key set (Codec.protect_only_ceilings/0) and the response
    # key set (Codec.hard_limits/0) are both sourced from Codec so they cannot drift. This test
    # pins that EVERY protect-only key is accepted (selected out), not rejected as a typo — if
    # a future protect-only key were added to the transformer but not to Codec, this would fail.
    response = %AshOnetime.Resource.Response{
      codec: AshOnetime.Codec.Resource,
      fields: [:id, :name, :amount],
      classify: StoreClassifier
    }

    for key <- Keyword.keys(AshOnetime.Codec.protect_only_ceilings()) do
      assert {:ok, _contract} =
               Response.contract(Account, :create_account, response, %{limits: [{key, 1}]})
    end
  end

  test "a malformed trusted limits list is rejected, not rescued into an opaque error" do
    # diff-review F2 / correctness lens F-1: a non-keyword list (non-tuple elements, or odd
    # arity) must be rejected explicitly via the selector's Keyword.keyword? guard (message
    # "response limits are invalid") — not fall through to contract/4's blanket rescue
    # (message "response contract is invalid"). Asserting on the message discriminates the
    # structured-reject path from the rescue path: neutering the guard makes split_with raise
    # and the rescue's different message surfaces, turning this test red.
    response = %AshOnetime.Resource.Response{
      codec: AshOnetime.Codec.Resource,
      fields: [:id, :name, :amount],
      classify: StoreClassifier
    }

    for malformed <- [[1, 2], [:max_response_bytes], [{:max_response_bytes, 1}, 2]] do
      assert {:error,
              %Error{code: :response_contract_invalid, message: "response limits are invalid"}} =
               Response.contract(Account, :create_account, response, %{limits: malformed})
    end
  end

  defp contract!(action, codec, codec_opts) do
    response = %AshOnetime.Resource.Response{
      codec: codec,
      fields: [],
      classify: StoreClassifier,
      codec_opts: codec_opts
    }

    {:ok, contract} = Response.contract(Account, action, response, %{})
    contract
  end

  defp store_result(encoded) do
    now = DateTime.utc_now()

    claim = %Claim{
      strategy: :idempotency,
      id: Ecto.UUID.generate(),
      logical_partition: "global",
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
