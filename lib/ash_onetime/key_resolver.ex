defmodule AshOnetime.KeyResolver do
  @moduledoc """
  Resolves purpose-specific signing or verification material.

  A resolver must keep `:sign` and `:verify` lookups distinct. Material is passed
  unchanged to the selected signer, which validates its trust and role tags.
  """

  @type purpose :: :sign | :verify
  @type algorithm :: :hmac_sha256 | :ed25519

  @callback resolve(purpose(), String.t(), algorithm(), term()) ::
              {:ok, term()} | {:error, term()}
end
