defmodule AshOnetime.Clock do
  @moduledoc """
  Trusted clock boundary used when minting and verifying tokens.
  """

  @callback now() :: DateTime.t()

  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()
end
