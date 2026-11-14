defmodule AshOnetime.KeyCustody.Conformance do
  @moduledoc """
  Portable conformance suite for trusted key custody implementations.

  Provision an isolated test holder with `materials/0`, preserving the separate
  `{purpose, key_id}` bindings, then call `run/2` with its custody module and
  context. Never provision these public test keys in a production holder.

  The suite runs every algorithm declared by the custody. It checks RFC 4231
  HMAC-SHA256 and RFC 8032 pure Ed25519 known answers, reference-signer
  interoperability in both directions, wrong messages, keys, algorithms and
  purposes, first/middle/last-byte tampering, and truncated/extended signatures.
  It cannot prove constant-time comparison at an external holder.
  """

  alias AshOnetime.Signer.{Ed25519, HMAC}

  @private Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @other_private Base.decode16!(
                   "4CCD089B28FF96DA9DB6C346EC114E0F5B8A319F35ABA624DA8CF6ED4FB8A6FB"
                 )
  @other_public Base.decode16!("3D4017C3E843895A92B70AA74D1B7EBC9C982CCF2EC4968CC0CD55F12AF4660C")

  @doc "Public test vectors and purpose-specific bindings required by the suite."
  @spec materials() :: map()
  def materials do
    bindings(
      :hmac_sha256,
      "hmac",
      secret(:binary.copy(<<0x0B>>, 20)),
      secret(:binary.copy(<<0x0B>>, 20))
    )
    |> Map.merge(bindings(:hmac_sha256, "hmac-other", secret("Jefe"), secret("Jefe")))
    |> Map.merge(bindings(:ed25519, "ed", private(@private), public(@public)))
    |> Map.merge(bindings(:ed25519, "ed-other", private(@other_private), public(@other_public)))
    |> Map.put({:sign, "hmac-sign-only"}, secret("Jefe"))
    |> Map.put({:verify, "hmac-verify-only"}, secret("Jefe"))
    |> Map.put({:sign, "ed-sign-only"}, private(@private))
    |> Map.put({:verify, "ed-verify-only"}, public(@public))
  end

  @doc "Runs all declared algorithms; a failure identifies its algorithm and check without key material."
  @spec run(module(), term()) :: :ok | {:error, map()}
  def run(custody, context) do
    algorithms = custody.algorithms()

    if is_list(algorithms) and algorithms != [] and
         Enum.all?(algorithms, &(&1 in [:hmac_sha256, :ed25519])) and
         algorithms == Enum.uniq(algorithms) do
      run_algorithms(custody, context, algorithms)
    else
      {:error, %{check: :algorithms}}
    end
  end

  defp run_algorithms(custody, context, algorithms) do
    Enum.reduce_while(algorithms, :ok, fn algorithm, :ok ->
      case check_algorithm(custody, context, algorithm) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp check_algorithm(custody, context, algorithm) do
    Enum.reduce_while(vectors(algorithm), :ok, fn {key_id, bytes, expected}, :ok ->
      checks(custody, context, algorithm, key_id, bytes, expected)
      |> Enum.find(fn {_name, passes?} -> not passes? end)
      |> case do
        nil -> {:cont, :ok}
        {check, false} -> {:halt, {:error, %{algorithm: algorithm, key_id: key_id, check: check}}}
      end
    end)
  end

  defp checks(custody, context, algorithm, key_id, bytes, expected) do
    signed = custody.sign(algorithm, key_id, bytes, context)
    {:ok, reference} = signer(algorithm).sign(bytes, materials()[{:sign, key_id}])
    other_algorithm = if algorithm == :ed25519, do: :hmac_sha256, else: :ed25519
    prefix = if algorithm == :ed25519, do: "ed", else: "hmac"

    [
      known_answer_sign: signed == {:ok, expected},
      known_answer_verify: custody.verify(algorithm, key_id, bytes, expected, context) == :ok,
      reference_to_custody: custody.verify(algorithm, key_id, bytes, reference, context) == :ok,
      custody_to_reference:
        reference_verifies?(algorithm, bytes, signed, materials()[{:verify, key_id}]),
      wrong_message:
        rejected?(custody.verify(algorithm, key_id, bytes <> <<0>>, expected, context)),
      wrong_key:
        rejected?(custody.verify(algorithm, other_key(key_id), bytes, expected, context)),
      wrong_sign_algorithm:
        custody.sign(other_algorithm, key_id, bytes, context) == {:error, :key_unusable},
      wrong_verify_algorithm:
        custody.verify(other_algorithm, key_id, bytes, expected, context) ==
          {:error, :key_unusable},
      wrong_sign_purpose:
        custody.sign(algorithm, prefix <> "-verify-only", bytes, context) ==
          {:error, :key_unusable},
      wrong_verify_purpose:
        custody.verify(algorithm, prefix <> "-sign-only", bytes, expected, context) ==
          {:error, :key_unusable},
      verify_only:
        custody.verify(
          algorithm,
          prefix <> "-verify-only",
          bytes,
          reference_for_verify_only(algorithm, bytes),
          context
        ) == :ok
    ] ++ signature_checks(custody, context, algorithm, key_id, bytes, expected)
  end

  defp signature_checks(custody, context, algorithm, key_id, bytes, signature) do
    size = byte_size(signature)

    variants = [
      {:tamper_first, tamper(signature, 0)},
      {:tamper_middle, tamper(signature, div(size, 2))},
      {:tamper_last, tamper(signature, size - 1)},
      {:truncated, binary_part(signature, 0, size - 1)},
      {:extended, signature <> <<0>>}
    ]

    Enum.map(variants, fn {name, value} ->
      {name, rejected?(custody.verify(algorithm, key_id, bytes, value, context))}
    end)
  end

  defp reference_for_verify_only(algorithm, bytes) do
    material = if algorithm == :ed25519, do: private(@private), else: secret("Jefe")
    {:ok, signature} = signer(algorithm).sign(bytes, material)
    signature
  end

  defp reference_verifies?(algorithm, bytes, {:ok, signature}, material),
    do: signer(algorithm).verify(bytes, signature, material) == :ok

  defp reference_verifies?(_, _, _, _), do: false
  defp rejected?(result), do: result in [{:error, :key_unusable}, {:error, :invalid_signature}]
  defp other_key("hmac"), do: "hmac-other"
  defp other_key("hmac-other"), do: "hmac"
  defp other_key("ed"), do: "ed-other"
  defp other_key("ed-other"), do: "ed"

  defp tamper(bytes, offset) do
    <<prefix::binary-size(^offset), byte, suffix::binary>> = bytes
    prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix
  end

  defp bindings(algorithm, id, signing, verification),
    do: %{
      {:sign, id} => Map.put(signing, :algorithm, algorithm),
      {:verify, id} => Map.put(verification, :algorithm, algorithm)
    }

  defp secret(key), do: %{algorithm: :hmac_sha256, key: key, kind: :secret, trust: :same_service}
  defp private(key), do: %{algorithm: :ed25519, key: key, kind: :private, trust: :separated}
  defp public(key), do: %{algorithm: :ed25519, key: key, kind: :public, trust: :separated}
  defp signer(:hmac_sha256), do: HMAC
  defp signer(:ed25519), do: Ed25519

  # RFC 4231 §4.2/4.3; RFC 8032 §7.1 TEST 1/TEST 2 (pure Ed25519).
  defp vectors(:hmac_sha256),
    do: [
      {"hmac", "Hi There",
       Base.decode16!("B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7")},
      {"hmac-other", "what do ya want for nothing?",
       Base.decode16!("5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843")}
    ]

  defp vectors(:ed25519),
    do: [
      {"ed", "",
       Base.decode16!(
         "E5564300C360AC729086E2CC806E828A84877F1EB8E5D974D873E065224901555FB8821590A33BACC61E39701CF9B46BD25BF5F0595BBE24655141438E7A100B"
       )},
      {"ed-other", <<0x72>>,
       Base.decode16!(
         "92A009A9F0D4CAB8720E820B5F642540A2B27B5416503F8FB3762223EBDB69DA085AC1E43E15996E458F3613D0F11D8C387B2EAEB4302AEEB00D291612BB0C00"
       )}
    ]
end
