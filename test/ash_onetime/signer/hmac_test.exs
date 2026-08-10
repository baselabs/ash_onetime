defmodule AshOnetime.Signer.HMACTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Error
  alias AshOnetime.Signer.HMAC

  @rfc_key :binary.copy(<<0x0B>>, 20)
  @rfc_digest Base.decode16!("B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7")

  test "matches RFC 4231 HMAC-SHA-256 test case one" do
    material = same_service(@rfc_key)

    assert HMAC.algorithm() == :hmac_sha256
    assert {:ok, @rfc_digest} = HMAC.sign("Hi There", material)
    assert :ok = HMAC.verify("Hi There", @rfc_digest, material)
  end

  test "rejects meaningful byte and key tampering" do
    material = same_service(@rfc_key)
    tampered = flip_first_byte(@rfc_digest)

    refute tampered == @rfc_digest

    assert {:error, %Error{code: :invalid_signature}} =
             HMAC.verify("Hi There", tampered, material)

    assert {:error, %Error{code: :invalid_signature}} =
             HMAC.verify("Hi There", @rfc_digest, same_service("wrong"))
  end

  test "raw, unspecified, and external key material cannot sign or verify" do
    for material <- [
          @rfc_key,
          %{key: @rfc_key},
          %{key: @rfc_key, trust: :external}
        ] do
      assert {:error, %Error{code: :invalid_trust_boundary}} = HMAC.sign("message", material)

      assert {:error, %Error{code: :invalid_trust_boundary}} =
               HMAC.verify("message", @rfc_digest, material)
    end
  end

  @tag :secure_equal_length_mutation
  test "invalid trusted keys and signature sizes fail closed" do
    assert {:error, %Error{code: :invalid_key}} = HMAC.sign("message", same_service(<<>>))

    # A wrong-length signature reaches :crypto.hash_equals/2 which RAISES ArgumentError on
    # unequal length; verify/3's rescue converts that to :invalid_signature (fail-closed).
    # The rescue is load-bearing here — pinned by the secure-equal-length mutation.
    assert {:error, %Error{code: :invalid_signature}} =
             HMAC.verify("message", <<0>>, same_service(@rfc_key))

    assert {:error, %Error{code: :invalid_signature}} =
             HMAC.verify("message", :binary.copy(<<0>>, 64), same_service(@rfc_key))
  end

  @tag :secure_equal_full_length_mutation
  test "a tamper anywhere past the first byte fails closed (full-length constant-time compare)" do
    material = same_service(@rfc_key)
    assert {:ok, digest} = HMAC.sign("Hi There", material)

    # Flip the last byte and a middle byte — NOT the first. A comparator that short-circuited on,
    # or only inspected, byte 0 would accept these tail flips; a full-length compare rejects them.
    last = flip_byte(digest, byte_size(digest) - 1)
    middle = flip_byte(digest, div(byte_size(digest), 2))
    refute last == digest
    refute middle == digest

    assert {:error, %Error{code: :invalid_signature}} = HMAC.verify("Hi There", last, material)
    assert {:error, %Error{code: :invalid_signature}} = HMAC.verify("Hi There", middle, material)
  end

  @tag :hmac_key_bound_mutation
  test "trusted key bytes accept the exact limit and reject the first excess" do
    exact = :binary.copy(<<0x42>>, 4_096)
    excess = exact <> <<0x42>>

    assert {:ok, signature} = HMAC.sign("message", same_service(exact))
    assert :ok = HMAC.verify("message", signature, same_service(exact))
    assert {:error, %Error{code: :invalid_key}} = HMAC.sign("message", same_service(excess))

    assert {:error, %Error{code: :invalid_key}} =
             HMAC.verify("message", signature, same_service(excess))
  end

  test "non-binary messages return a message error with valid trusted keys" do
    material = same_service(@rfc_key)

    assert {:error, %Error{code: :invalid_message}} = HMAC.sign(:not_binary, material)

    assert {:error, %Error{code: :invalid_message}} =
             HMAC.verify(:not_binary, @rfc_digest, material)
  end

  defp same_service(key), do: %{key: key, trust: :same_service}

  defp flip_first_byte(<<first, rest::binary>>),
    do: <<Bitwise.bxor(first, 1), rest::binary>>

  defp flip_byte(binary, index) do
    <<prefix::binary-size(^index), byte, suffix::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 1)::8, suffix::binary>>
  end
end
