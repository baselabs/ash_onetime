defmodule AshOnetime.Verifier do
  @moduledoc "Behaviour for trusted local verification callbacks."

  @callback verify(raw_token :: binary(), context :: map()) ::
              {:ok, AshOnetime.Verified.t()} | {:error, term()}
  @callback algorithm() :: :hmac_sha256 | :ed25519
  @callback trust_model() :: :same_service | :separated
end
