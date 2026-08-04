defmodule AshOnetime.Verified do
  @moduledoc "Trusted local facts returned by a configured token verifier or minter."

  @enforce_keys [:key, :issued_at, :verifier_id]
  defstruct [:key, :issued_at, :expires_at, :verifier_id]

  @opaque t :: %__MODULE__{
            key: binary(),
            issued_at: DateTime.t(),
            expires_at: DateTime.t() | nil,
            verifier_id: binary()
          }
end
