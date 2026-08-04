defmodule AshOnetime.ReplaySafety do
  @moduledoc "Declaration for lifecycle callbacks that are safe during stored-result replay."

  @type mode :: :pure | :replay_aware
  @callback replay_safety(opts :: Keyword.t()) :: mode()
end
