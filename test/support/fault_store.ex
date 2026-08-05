defmodule AshOnetime.Test.FaultStore do
  @moduledoc false

  @behaviour AshOnetime.Store

  @result_key {__MODULE__, :result}
  @handler_key {__MODULE__, :handler}

  def put_result(result), do: Process.put(@result_key, result)
  def put_handler(handler) when is_function(handler, 2), do: Process.put(@handler_key, handler)

  def reset do
    Process.delete(@result_key)
    Process.delete(@handler_key)
    :ok
  end

  @impl AshOnetime.Store
  def claim(target, request), do: result!(:claim, [target, request])

  @impl AshOnetime.Store
  def claim_committed(target, request), do: result!(:claim_committed, [target, request])

  @impl AshOnetime.Store
  def complete(target, claim, codec, digest, payload),
    do: result!(:complete, [target, claim, codec, digest, payload])

  @impl AshOnetime.Store
  def complete_external(target, claim, codec, digest, payload),
    do: result!(:complete_external, [target, claim, codec, digest, payload])

  @impl AshOnetime.Store
  def load(target, claim), do: result!(:load, [target, claim])

  defp result!(operation, arguments) do
    case Process.get(@handler_key) do
      handler when is_function(handler, 2) -> handler.(operation, arguments)
      _other -> Process.get(@result_key) || raise("fault store result is not configured")
    end
  end
end
