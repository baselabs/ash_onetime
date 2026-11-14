defmodule AshOnetime.KeyCustody.Local.Material do
  @moduledoc """
  Purpose-specific material source for `AshOnetime.KeyCustody.Local`.

  Local receives `%{material: MySource, ...}` as its custody context and passes
  that whole context to `fetch/3`. Records carry their authoritative algorithm,
  key kind and trust. Signing and verification records are separate lookups;
  Ed25519 verification must return public material, never a private key.
  """

  @type material :: %{
          algorithm: AshOnetime.KeyCustody.algorithm(),
          key: binary(),
          kind: :private | :public | :secret,
          trust: atom()
        }

  @callback fetch(:sign | :verify, binary(), term()) ::
              {:ok, material()} | {:error, :not_found}
end
