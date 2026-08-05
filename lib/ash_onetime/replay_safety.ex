defmodule AshOnetime.ReplaySafety do
  @moduledoc "Declaration for lifecycle callbacks that are safe during stored-result replay."

  @type mode :: :pure | :replay_aware
  @type capabilities :: %{
          notifications: boolean(),
          effects: boolean(),
          around_action: boolean(),
          marker: :unused | :consumed
        }
  @callback replay_safety(opts :: Keyword.t()) :: mode()
  @callback replay_capabilities(opts :: Keyword.t()) :: capabilities()
end
