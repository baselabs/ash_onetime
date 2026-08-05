defmodule AshOnetime.Cache.None do
  @moduledoc """
  No-op cache used when no optional completed-response cache is configured.
  """

  @behaviour AshOnetime.Cache

  @impl AshOnetime.Cache
  def get(_key), do: :miss

  @impl AshOnetime.Cache
  def put(_key, _entry, _ttl_seconds), do: :ok

  @impl AshOnetime.Cache
  def delete(_key), do: :ok
end
