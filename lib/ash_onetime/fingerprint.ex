defmodule AshOnetime.Fingerprint do
  @moduledoc """
  Computes SHA-256 fingerprints over exact canonical bytes.

  A fingerprint is SHA-256 over the `AshOnetime.Canonical` format 1 encoding of a value.
  Pass the value itself to `compute/2`, never bytes you already encoded: a binary is a value
  too, so its fingerprint covers its own canonical frame. To keep the bytes as well, call
  `AshOnetime.Canonical.encode/1` and hash its result with SHA-256; the digest is the same.
  `priv/vectors/canonical-1.json` lists the fingerprint of every accepted vector.
  """

  alias AshOnetime.Canonical
  alias AshOnetime.Error

  @doc """
  Computes the SHA-256 fingerprint over the exact canonical encoding of `value`.

  The fingerprint is the replay-binding digest: two admissions with the same logical key but
  different request bodies produce different fingerprints, so a stale response cannot replay
  against a mutated request. `max_bytes` (default `:infinity`) bounds the canonical encoding
  size; an oversized value returns `{:error, %AshOnetime.Error{code: :fingerprint_too_large}}`
  without hashing. A value outside the canonical algebra or its bounds returns the
  `AshOnetime.Canonical.encode/1` error. Returns `{:ok, <<32-byte digest>>}`.
  """
  @spec compute(term(), pos_integer() | :infinity) :: {:ok, <<_::256>>} | {:error, Error.t()}
  def compute(value, max_bytes \\ :infinity) do
    with {:ok, encoded} <- Canonical.encode(value),
         :ok <- within_bytes(byte_size(encoded), max_bytes) do
      {:ok, :crypto.hash(:sha256, encoded)}
    end
  end

  defp within_bytes(_size, :infinity), do: :ok
  defp within_bytes(size, max_bytes) when is_integer(max_bytes) and size <= max_bytes, do: :ok

  defp within_bytes(_size, _max_bytes),
    do:
      {:error,
       Error.new(:fingerprint_too_large, "request fingerprint exceeds max_fingerprint_bytes")}
end
