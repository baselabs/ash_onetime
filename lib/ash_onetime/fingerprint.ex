defmodule AshOnetime.Fingerprint do
  @moduledoc """
  Computes SHA-256 fingerprints over exact canonical bytes.
  """

  alias AshOnetime.Canonical
  alias AshOnetime.Error

  @spec compute(term()) :: {:ok, <<_::256>>} | {:error, Error.t()}
  def compute(value) do
    with {:ok, encoded} <- Canonical.encode(value) do
      {:ok, :crypto.hash(:sha256, encoded)}
    end
  end
end
