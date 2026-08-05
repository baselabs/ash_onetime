defmodule AshOnetime.Resource.Verifier do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    raw = Verifier.get_entities(dsl_state, [:onetime])

    index =
      Verifier.get_persisted(
        dsl_state,
        :ash_onetime_protections,
        %{ordered: [], by_action: %{}}
      )

    case verify_index_count(dsl_state, raw, index) do
      :ok -> verify_wrappers(dsl_state, index.ordered)
      error -> error
    end
  end

  defp verify_index_count(dsl_state, raw, index) do
    if length(raw) == length(index.ordered) and map_size(index.by_action) == length(index.ordered) do
      :ok
    else
      verifier_error(dsl_state, "normalized protection index does not match declared protections")
    end
  end

  defp verify_wrappers(dsl_state, protections) do
    Enum.reduce_while(protections, :ok, fn protection, :ok ->
      action = ResourceInfo.action(dsl_state, protection.action)

      valid? = valid_wrapper?(dsl_state, action, protection)

      if valid? do
        {:cont, :ok}
      else
        {:halt,
         verifier_error(dsl_state, "protected action is missing exactly one runtime wrapper")}
      end
    end)
  end

  defp valid_wrapper?(
         _dsl_state,
         %{
           type: :action,
           run: {AshOnetime.GenericAction, opts},
           preparations: preparations
         },
         protection
       ) do
    package =
      Enum.filter(preparations, fn
        %Ash.Resource.Preparation{preparation: {AshOnetime.GenericAction, _opts}} -> true
        _other -> false
      end)

    opts[:protection] == protection and
      match?({_module, _opts}, opts[:original]) and length(package) == 1 and
      List.last(preparations) == hd(package) and
      package_protection(hd(package)) == opts[:protection]
  end

  defp valid_wrapper?(
         dsl_state,
         %{type: type, changes: changes, notifiers: action_notifiers},
         protection
       )
       when type in [:create, :update, :destroy] do
    package_count =
      Enum.count(changes, fn
        %{change: {AshOnetime.Change, opts}} ->
          match?(%AshOnetime.Resource.Protection{}, opts[:protection])

        _other ->
          false
      end)

    resource_notifiers = ResourceInfo.notifiers(dsl_state)

    package_count == 1 and package_change?(List.first(changes), protection) and
      resource_notifiers ++ action_notifiers == []
  end

  defp valid_wrapper?(_dsl_state, _action, _protection), do: false

  defp package_change?(%{change: {AshOnetime.Change, opts}}, protection),
    do: opts[:protection] == protection

  defp package_change?(_change, _protection), do: false

  defp package_protection(%Ash.Resource.Preparation{
         preparation: {AshOnetime.GenericAction, opts}
       }),
       do: opts[:protection]

  defp verifier_error(dsl_state, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: [:onetime],
       message: message
     )}
  end
end
