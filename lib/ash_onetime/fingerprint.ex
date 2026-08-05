defmodule AshOnetime.Fingerprint do
  @moduledoc """
  Computes SHA-256 fingerprints over exact canonical bytes.
  """

  alias AshOnetime.Canonical
  alias AshOnetime.Error

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
