defmodule AshOnetime.Signer.HMAC do
  @moduledoc """
  HMAC-SHA-256 signer restricted to explicitly same-service key material.

  Raw bytes are never sufficient authorization for HMAC. Both signing and
  verification require `%{key: key, trust: :same_service}` from the resolver.
  """

  @behaviour AshOnetime.Signer

  alias AshOnetime.Error

  @max_key_bytes 4_096

  @impl AshOnetime.Signer
  def algorithm, do: :hmac_sha256

  @impl AshOnetime.Signer
  def sign(message, %{key: key, trust: :same_service})
      when is_binary(message) and is_binary(key) and byte_size(key) in 1..@max_key_bytes do
    {:ok, :crypto.mac(:hmac, :sha256, key, message)}
  rescue
    _exception -> {:error, Error.new(:signing_failed, "HMAC signing failed")}
  end

  def sign(message, %{trust: :same_service}) when not is_binary(message),
    do: {:error, Error.new(:invalid_message, "HMAC message must be binary")}

  def sign(_message, %{trust: :same_service}),
    do: {:error, Error.new(:invalid_key, "HMAC key must be bounded non-empty bytes")}

  def sign(_message, _material),
    do:
      {:error,
       Error.new(
         :invalid_trust_boundary,
         "HMAC material must explicitly prove same-service trust"
       )}

  @impl AshOnetime.Signer
  def verify(message, signature, %{key: key, trust: :same_service})
      when is_binary(message) and is_binary(signature) and is_binary(key) and
             byte_size(key) in 1..@max_key_bytes do
    # Constant-time hash_equals/2 raises ArgumentError on unequal-length inputs.
    # A caller-supplied signature can have any length; the expected MAC has 32 bytes.
    # Keep the comparison inside the rescue boundary.
    # Wrong lengths and other crypto failures become :invalid_signature.
    if secure_equal(signature, :crypto.mac(:hmac, :sha256, key, message)) do
      :ok
    else
      {:error, Error.new(:invalid_signature, "HMAC signature is invalid")}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_signature, "HMAC signature is invalid")}
  end

  def verify(message, _signature, %{trust: :same_service}) when not is_binary(message),
    do: {:error, Error.new(:invalid_message, "HMAC message must be binary")}

  def verify(_message, _signature, %{trust: :same_service}),
    do: {:error, Error.new(:invalid_key, "HMAC key must be bounded non-empty bytes")}

  def verify(_message, _signature, _material),
    do:
      {:error,
       Error.new(
         :invalid_trust_boundary,
         "HMAC material must explicitly prove same-service trust"
       )}

  # Constant-time compare delegated to the crypto NIF. :crypto.hash_equals/2 is constant-time
  # over equal-length inputs; verify/3 rescues unequal-length failures.
  defp secure_equal(left, right), do: :crypto.hash_equals(left, right)
end
