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
    # Constant-time compare via the crypto NIF. :crypto.hash_equals/2 RAISES ArgumentError on
    # unequal-length inputs (verified empirically against OTP 29); a caller-supplied signature
    # of any length against the always-32-byte MAC hits that raise on a wrong-length signature.
    # The rescue below is LOAD-BEARING for that case (not redundant defense-in-depth): it
    # converts the raise — and any other crypto failure — to :invalid_signature. Keeping the
    # compare inside the rescue boundary is what makes wrong-length signatures fail closed.
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
  # over equal-length inputs and raises ArgumentError on unequal length (the raise is caught
  # by verify/3's rescue). Kept as a NAMED wrapper (not an inline call) so the fail-closed
  # contract reads at the call site and the registered mutation anchor
  # (secure-equal-length, which mutates the rescue arm) has a stable function boundary.
  defp secure_equal(left, right), do: :crypto.hash_equals(left, right)
end
