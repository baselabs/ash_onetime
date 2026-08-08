defmodule AshOnetime.Resource.Info do
  @moduledoc """
  Read-only introspection for the normalized per-action protections a resource declares under
  `onetime`.

  Each protected action is normalized at compile time into an
  `AshOnetime.Resource.Protection` struct carrying its strategy, scope, key, response contract,
  and lifecycle configuration. The functions here read that normalized index back without
  re-running the DSL.
  """

  alias AshOnetime.Resource.Protection
  alias Spark.Dsl.Extension

  @type protection :: Protection.t()

  @doc """
  Returns all protections declared on `resource`, in declaration order.

  Returns an empty list when the resource declares no `onetime` protections.
  """
  @spec protections(Ash.Resource.t()) :: [protection()]
  def protections(resource), do: index(resource).ordered

  @doc """
  Returns the protection for `action_name` on `resource`, or `nil` if the action is unprotected.
  """
  @spec protection(Ash.Resource.t(), atom()) :: protection() | nil
  def protection(resource, action_name), do: Map.get(index(resource).by_action, action_name)

  @doc """
  Returns the keyed-effect strategy for `action_name` (`:idempotency` or `:one_time_nonce`),
  or `nil` if the action is unprotected.
  """
  @spec strategy(Ash.Resource.t(), atom()) :: :idempotency | :one_time_nonce | nil
  def strategy(resource, action_name) do
    case protection(resource, action_name) do
      nil -> nil
      protection -> protection.strategy
    end
  end

  @doc """
  Returns `true` if `action_name` on `resource` is protected by an `onetime` declaration.
  """
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
