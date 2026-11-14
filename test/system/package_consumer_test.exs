defmodule AshOnetime.System.PackageConsumerTest do
  use ExUnit.Case, async: true

  alias AshOnetime.{Canonical, Error, Token}
  alias AshOnetime.KeyCustody.Local
  alias AshOnetime.Signer.HMAC

  @tag signature_compare_mutation: true
  test "meaningful signature-byte tampering fails closed" do
    key = :binary.copy(<<0x0B>>, 20)
    material = %{key: key, trust: :same_service}
    assert {:ok, signature} = HMAC.sign("system-message", material)
    <<first, rest::binary>> = signature
    tampered = <<Bitwise.bxor(first, 1), rest::binary>>
    refute tampered == signature

    assert {:error, %Error{code: :invalid_signature}} =
             HMAC.verify("system-message", tampered, material)
  end

  @tag canonical_domain_tag_mutation: true
  test "canonical domains stay distinct and the package starts its callback supervisor" do
    assert {:ok, <<2, _::binary>>} = Canonical.encode(1)
    assert {:ok, <<3, _::binary>>} = Canonical.encode("1")
    assert Application.spec(:ash_onetime, :mod) == {AshOnetime.Application, []}
    assert is_pid(Process.whereis(AshOnetime.TaskSupervisor))
    assert Code.ensure_loaded?(AshOnetime.Resource)
    assert Code.ensure_loaded?(AshOnetime.Store.Postgres)
  end

  test "key rotation retains old verification keys through the acceptance window" do
    issued_at = DateTime.utc_now()
    old_key = :binary.copy(<<0x31>>, 32)
    new_key = :binary.copy(<<0x32>>, 32)

    assert {:ok, old_token} =
             Token.mint("old-nonce",
               algorithm: :hmac_sha256,
               key_id: "old",
               namespace: "rotation",
               issued_at: issued_at
             )

    signing = %{
      material: AshOnetime.Test.KeyMaterial,
      keys: %{{:sign, "old"} => material(old_key)}
    }

    assert {:ok, encoded_old} = Token.sign(old_token, Local, signing)

    rotated = %{
      material: AshOnetime.Test.KeyMaterial,
      keys: %{
        {:sign, "new"} => material(new_key),
        {:verify, "new"} => material(new_key),
        {:verify, "old"} => material(old_key)
      }
    }

    assert {:ok, ^old_token} = Token.verify(encoded_old, Local, verify_options(rotated))

    assert {:ok, new_token} =
             Token.mint("new-nonce",
               algorithm: :hmac_sha256,
               key_id: "new",
               namespace: "rotation",
               issued_at: issued_at
             )

    assert {:ok, encoded_new} = Token.sign(new_token, Local, rotated)
    assert {:ok, ^new_token} = Token.verify(encoded_new, Local, verify_options(rotated))

    without_old = update_in(rotated.keys, &Map.delete(&1, {:verify, "old"}))

    assert {:error, %Error{code: :key_unusable}} =
             Token.verify(
               encoded_old,
               Local,
               verify_options(%{material: AshOnetime.Test.KeyMaterial, keys: without_old})
             )
  end

  defp verify_options(context) do
    [
      algorithm: :hmac_sha256,
      namespace: "rotation",
      max_age: 60,
      skew: 5,
      custody_context: context
    ]
  end

  defp material(key),
    do: %{algorithm: :hmac_sha256, key: key, kind: :secret, trust: :same_service}
end
