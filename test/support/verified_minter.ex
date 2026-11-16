defmodule AshOnetime.Test.VerifiedMinter do
  @moduledoc false

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
