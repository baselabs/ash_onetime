defmodule AshOnetime.Test.ExitBoundary.ConnectionStates do
  @moduledoc false

  # An owner version is a native return, or the pre-observation holder state.
  # Copies must bind to that version before a buffer can leave exact comparison.
  # This ledger grants no event allowance or projection.
  def build(_indexed, _native, _decoders, historical) do
    versions =
      for {holder, %{protocol: protocol}} <- historical,
          do: %{origin: {:historical, holder}, protocol: protocol}

    %{versions: versions, copies: [], errors: []}
  end
end
