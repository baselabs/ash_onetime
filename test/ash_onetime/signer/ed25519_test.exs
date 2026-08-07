defmodule AshOnetime.Signer.Ed25519Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshOnetime.Error
  alias AshOnetime.Signer.Ed25519

  @private_key Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public_key Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @signature Base.decode16!(
               "E5564300C360AC729086E2CC806E828A84877F1EB8E5D974D873E06522490155" <>
                 "5FB8821590A33BACC61E39701CF9B46BD25BF5F0595BBE24655141438E7A100B"
             )

  test "matches RFC 8032 Ed25519 test vector one through OTP crypto" do
    assert Ed25519.algorithm() == :ed25519
    assert {:ok, @signature} = Ed25519.sign(<<>>, private(@private_key))
    assert :ok = Ed25519.verify(<<>>, @signature, public(@public_key))
  end

  test "OTP-generated signatures verify with public material only" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    assert {:ok, signature} = Ed25519.sign("separated roles", private(private_key))
    assert :ok = Ed25519.verify("separated roles", signature, public(public_key))

    assert {:error, %Error{code: :invalid_key_role}} =
             Ed25519.verify("separated roles", signature, private(private_key))
  end

  test "rejects meaningful byte and message tampering" do
    tampered = flip_first_byte(@signature)
    refute tampered == @signature

    assert {:error, %Error{code: :invalid_signature}} =
             Ed25519.verify(<<>>, tampered, public(@public_key))

    assert {:error, %Error{code: :invalid_signature}} =
             Ed25519.verify("changed", @signature, public(@public_key))
  end

  test "signing and verification material roles are separated" do
    assert {:error, %Error{code: :invalid_key_role}} =
             Ed25519.sign("message", public(@public_key))

    assert {:error, %Error{code: :invalid_key}} = Ed25519.sign("message", private(<<0>>))

    assert {:error, %Error{code: :invalid_key}} =
             Ed25519.verify("message", @signature, public(<<0>>))
  end

  test "non-binary messages return a message error with valid role keys" do
    assert {:error, %Error{code: :invalid_message}} =
             Ed25519.sign(:not_binary, private(@private_key))

    assert {:error, %Error{code: :invalid_message}} =
             Ed25519.verify(:not_binary, @signature, public(@public_key))
  end

  @tag :ed25519_wrong_key_mutation
  test "a valid signature is invalid under a different, equally valid public key" do
    {public_a, private_a} = :crypto.generate_key(:eddsa, :ed25519)
    {public_b, _private_b} = :crypto.generate_key(:eddsa, :ed25519)
    refute public_a == public_b
    assert byte_size(public_b) == 32

    assert {:ok, signature} = Ed25519.sign("bound to key A", private(private_a))
    assert :ok = Ed25519.verify("bound to key A", signature, public(public_a))

    # The signature is bound to A's key, not merely well-formed: a *different valid* 32-byte
    # public key rejects it rather than accepting any 64-byte blob.
    assert {:error, %Error{code: :invalid_signature}} =
             Ed25519.verify("bound to key A", signature, public(public_b))
  end

  property "a signature never verifies under a wrong but valid public key" do
    check all(message <- binary(max_length: 96)) do
      {_public_a, private_a} = :crypto.generate_key(:eddsa, :ed25519)
      {public_b, _private_b} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:ok, signature} = Ed25519.sign(message, private(private_a))

      assert {:error, %Error{code: :invalid_signature}} =
               Ed25519.verify(message, signature, public(public_b))
    end
  end

  defp private(key), do: %{key: key, kind: :private}
  defp public(key), do: %{key: key, kind: :public}

  defp flip_first_byte(<<first, rest::binary>>),
    do: <<Bitwise.bxor(first, 1), rest::binary>>
end
