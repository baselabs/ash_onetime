defmodule AshOnetime.Test.VerifiedMinter do
  @moduledoc false

  # Consumer-shaped opacity proof: a host module whose public spec speaks the
  # opaque `AshOnetime.Verified.t()` and constructs only through `new/1` — the
  # exact shape that tripped `contract_with_opaque` when hosts built the struct
  # literally. `MIX_ENV=test mix dialyzer` analyzes this module (test/support
  # compiles into the test env); it must report no opacity violation.

  alias AshOnetime.Verified

  @spec mint_facts(binary(), DateTime.t(), binary()) ::
          {:ok, [Verified.t()]} | {:error, term()}
  def mint_facts(key, issued_at, verifier_id) do
    case Verified.new(key: key, issued_at: issued_at, verifier_id: verifier_id) do
      {:ok, verified} -> {:ok, [verified]}
      {:error, reason} -> {:error, reason}
    end
  end
end
