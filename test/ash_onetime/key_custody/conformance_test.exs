defmodule AshOnetime.KeyCustody.ConformanceTest do
  use ExUnit.Case, async: true
  alias AshOnetime.KeyCustody.{Conformance, Local}
  alias AshOnetime.Test.{KeyCustodyHolder, KeyMaterial}

  for custody <- [Local, KeyCustodyHolder] do
    @custody custody
    test "#{inspect(custody)} conforms for every declared algorithm" do
      materials = Conformance.materials()

      context =
        case @custody do
          Local -> %{material: KeyMaterial, keys: materials}
          KeyCustodyHolder -> start_supervised!({KeyCustodyHolder, materials})
        end

      assert :ok = Conformance.run(@custody, context)

      if is_pid(context) do
        stop_supervised!(KeyCustodyHolder)
        refute Process.alive?(context)
      end
    end
  end

  test "Local checks the record algorithm, role, trust and purpose independently of lookup" do
    hmac = %{algorithm: :hmac_sha256, kind: :secret, trust: :same_service, key: "test"}

    private = %{
      algorithm: :ed25519,
      kind: :private,
      trust: :separated,
      key: :binary.copy(<<1>>, 32)
    }

    context = %{material: KeyMaterial, keys: %{{:verify, "key"} => private}}

    assert {:error, :key_unusable} =
             Local.verify(:ed25519, "key", "bytes", :binary.copy(<<0>>, 64), context)

    assert {:error, :key_unusable} = Local.sign(:ed25519, "key", "bytes", context)

    for material <- [hmac, %{hmac | kind: :public}, %{hmac | trust: :separated}] do
      context = %{material: KeyMaterial, keys: %{{:sign, "key"} => material}}
      assert {:error, :key_unusable} = Local.sign(:ed25519, "key", "bytes", context)
    end

    mismatched = %{hmac | algorithm: :ed25519}

    context = %{
      material: KeyMaterial,
      keys: %{{:sign, "key"} => mismatched, {:verify, "key"} => mismatched}
    }

    assert {:error, :key_unusable} = Local.sign(:hmac_sha256, "key", "bytes", context)

    assert {:error, :key_unusable} =
             Local.verify(:hmac_sha256, "key", "bytes", :binary.copy(<<0>>, 32), context)

    for material <- [%{hmac | kind: :public}, %{hmac | trust: :separated}] do
      context = %{
        material: KeyMaterial,
        keys: %{{:sign, "key"} => material, {:verify, "key"} => material}
      }

      assert {:error, :key_unusable} = Local.sign(:hmac_sha256, "key", "bytes", context)

      assert {:error, :key_unusable} =
               Local.verify(:hmac_sha256, "key", "bytes", :binary.copy(<<0>>, 32), context)
    end
  end
end
