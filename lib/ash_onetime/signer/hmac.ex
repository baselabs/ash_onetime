defmodule AshOnetime.Signer.HMAC do
  @moduledoc """
  HMAC-SHA-256 signer restricted to explicitly same-service key material.

  Raw bytes are never sufficient authorization for HMAC. Both signing and
  verification require `%{key: key, trust: :same_service}` from the resolver.
  """

  @behaviour AshOnetime.Signer

  import Bitwise

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
    # secure_equal owns the length check: its equal-length clause runs the constant-time compare,
    # and its fallback fails closed on any length mismatch (the mac is always 32 bytes). Keeping the
    # length guard inside the comparator, rather than a separate byte_size prefix on this `if`, means
    # the fallback is live and covered rather than dead, and a wrong-length signature still fails closed.
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

  defp secure_equal(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, difference ->
      difference ||| bxor(left_byte, right_byte)
    end)
    |> Kernel.==(0)
  end

  defp secure_equal(_left, _right), do: false
end
