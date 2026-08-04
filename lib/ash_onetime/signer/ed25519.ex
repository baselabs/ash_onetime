defmodule AshOnetime.Signer.Ed25519 do
  @moduledoc """
  Ed25519 signing with private material and verification with public material.
  """

  @behaviour AshOnetime.Signer

  alias AshOnetime.Error

  @key_bytes 32
  @signature_bytes 64

  @impl AshOnetime.Signer
  def algorithm, do: :ed25519

  @impl AshOnetime.Signer
  def sign(message, %{key: key, kind: :private})
      when is_binary(message) and is_binary(key) and byte_size(key) == @key_bytes do
    {:ok, :crypto.sign(:eddsa, :none, message, [key, :ed25519])}
  rescue
    _exception -> {:error, Error.new(:signing_failed, "Ed25519 signing failed")}
  end

  def sign(message, %{kind: :private}) when not is_binary(message),
    do: {:error, Error.new(:invalid_message, "Ed25519 message must be binary")}

  def sign(_message, %{kind: :private}),
    do: {:error, Error.new(:invalid_key, "Ed25519 private key must be 32 bytes")}

  def sign(_message, _material),
    do: {:error, Error.new(:invalid_key_role, "Ed25519 signing requires private material")}

  @impl AshOnetime.Signer
  def verify(message, signature, %{key: key, kind: :public})
      when is_binary(message) and is_binary(signature) and is_binary(key) and
             byte_size(key) == @key_bytes and byte_size(signature) == @signature_bytes do
    if :crypto.verify(:eddsa, :none, message, signature, [key, :ed25519]) do
      :ok
    else
      {:error, Error.new(:invalid_signature, "Ed25519 signature is invalid")}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_signature, "Ed25519 signature is invalid")}
  end

  def verify(message, _signature, %{kind: :public}) when not is_binary(message),
    do: {:error, Error.new(:invalid_message, "Ed25519 message must be binary")}

  def verify(_message, signature, %{key: key, kind: :public})
      when is_binary(key) and byte_size(key) == @key_bytes and
             (not is_binary(signature) or byte_size(signature) != @signature_bytes) do
    {:error, Error.new(:invalid_signature, "Ed25519 signature must be 64 bytes")}
  end

  def verify(_message, _signature, %{kind: :public}),
    do: {:error, Error.new(:invalid_key, "Ed25519 public key must be 32 bytes")}

  def verify(_message, _signature, _material),
    do: {:error, Error.new(:invalid_key_role, "Ed25519 verification requires public material")}
end
