defmodule AshOnetime.Signer do
  @moduledoc """
  Behaviour implemented by bounded token signers.
  """

  alias AshOnetime.Error

  @type algorithm :: :hmac_sha256 | :ed25519
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @callback algorithm() :: algorithm()
  @callback sign(binary(), term()) :: result(binary())
  @callback verify(binary(), binary(), term()) :: :ok | {:error, Error.t()}
end
