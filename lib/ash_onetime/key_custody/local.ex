defmodule AshOnetime.KeyCustody.Local do
  @moduledoc """
  In-process key custody using the package's reference signers.

  Pass `%{material: MyMaterialSource, ...}` as custody context. The material
  source receives that context unchanged. Local checks algorithm, purpose, kind
  and trust before signing or verification. HMAC requires `kind: :secret` and
  `trust: :same_service`. Ed25519 signs with private keys and verifies with public
  keys; verify-only contexts need no signing record.

  Token calls still run in the package's supervised callback worker. The material
  source must therefore be independent of the caller's process and transaction.
  """

  @behaviour AshOnetime.KeyCustody

  alias AshOnetime.Error
  alias AshOnetime.Signer.{Ed25519, HMAC}

  @impl true
  def algorithms, do: [:hmac_sha256, :ed25519]

  @impl true
  def sign(algorithm, key_id, bytes, context) do
    with {:ok, material} <- material(:sign, algorithm, key_id, context) do
      case signer(algorithm).sign(bytes, material) do
        {:ok, signature} -> {:ok, signature}
        {:error, %Error{}} -> {:error, :key_unusable}
      end
    end
  end

  @impl true
  def verify(algorithm, key_id, bytes, signature, context) do
    with {:ok, material} <- material(:verify, algorithm, key_id, context) do
      case signer(algorithm).verify(bytes, signature, material) do
        :ok -> :ok
        {:error, %Error{code: :invalid_signature}} -> {:error, :invalid_signature}
        {:error, %Error{}} -> {:error, :key_unusable}
      end
    end
  end

  defp material(purpose, algorithm, key_id, %{material: source} = context)
       when is_atom(source) do
    case source.fetch(purpose, key_id, context) do
      {:ok, %{algorithm: ^algorithm} = material} ->
        if usable?(purpose, algorithm, material),
          do: {:ok, material},
          else: {:error, :key_unusable}

      {:ok, _material} ->
        {:error, :key_unusable}

      {:error, :not_found} ->
        {:error, :key_unusable}
    end
  end

  defp material(_purpose, _algorithm, _key_id, _context), do: {:error, :key_unusable}

  defp usable?(_, :hmac_sha256, %{key: key, kind: :secret, trust: :same_service}),
    do: is_binary(key) and byte_size(key) in 1..4_096

  defp usable?(:sign, :ed25519, %{key: key, kind: :private, trust: _trust}),
    do: is_binary(key) and byte_size(key) == 32

  defp usable?(:verify, :ed25519, %{key: key, kind: :public, trust: _trust}),
    do: is_binary(key) and byte_size(key) == 32

  defp usable?(_, _, _), do: false

  defp signer(:hmac_sha256), do: HMAC
  defp signer(:ed25519), do: Ed25519
end
