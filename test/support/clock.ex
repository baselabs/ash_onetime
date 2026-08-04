defmodule AshOnetime.Test.Clock do
  @moduledoc false

  @behaviour AshOnetime.Clock

  @clock_key {__MODULE__, :now}

  def freeze(%DateTime{} = datetime) do
    Process.put(@clock_key, datetime)
    :ok
  end

  def reset do
    Process.delete(@clock_key)
    :ok
  end

  @impl AshOnetime.Clock
  def now do
    Process.get(@clock_key) || raise "test clock is not frozen"
  end
end
