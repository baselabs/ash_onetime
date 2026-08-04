defmodule AshOnetime.Test.FaultStore do
  @moduledoc false

  @behaviour AshOnetime.Store

  @result_key {__MODULE__, :result}

  def put_result(result), do: Process.put(@result_key, result)
  def reset, do: Process.delete(@result_key)

  @impl AshOnetime.Store
  def claim(_target, _request), do: result!()

  @impl AshOnetime.Store
  def complete(_target, _claim, _codec, _digest, _payload), do: result!()

  @impl AshOnetime.Store
  def load(_target, _claim), do: result!()

  defp result!, do: Process.get(@result_key) || raise("fault store result is not configured")
end
