defmodule AshOnetime.Resource.Info do
  @moduledoc "Read-only introspection for normalized per-action protections."

  alias AshOnetime.Resource.Protection
  alias Spark.Dsl.Extension

  @spec protections(Ash.Resource.t()) :: [Protection.t()]
  def protections(resource), do: index(resource).ordered

  @spec protection(Ash.Resource.t(), atom()) :: Protection.t() | nil
  def protection(resource, action_name), do: Map.get(index(resource).by_action, action_name)

  @spec strategy(Ash.Resource.t(), atom()) :: :idempotency | :one_time_nonce | nil
  def strategy(resource, action_name) do
    case protection(resource, action_name) do
      nil -> nil
      protection -> protection.strategy
    end
  end

  @spec protected?(Ash.Resource.t(), atom()) :: boolean()
  def protected?(resource, action_name), do: not is_nil(protection(resource, action_name))

  defp index(resource) do
    Extension.get_persisted(
      resource,
      :ash_onetime_protections,
      %{ordered: [], by_action: %{}}
    )
  end
end
