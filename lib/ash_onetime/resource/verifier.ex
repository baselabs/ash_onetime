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

      valid? = valid_wrapper?(action)

      if valid? do
        {:cont, :ok}
      else
        {:halt,
         verifier_error(dsl_state, "protected action is missing exactly one runtime wrapper")}
      end
    end)
  end

  defp valid_wrapper?(%{type: :action, run: {AshOnetime.GenericAction, opts}}) do
    match?(%AshOnetime.Resource.Protection{}, opts[:protection]) and
      match?({_module, _opts}, opts[:original])
  end

  defp valid_wrapper?(%{changes: changes}) do
    Enum.count(changes, fn
      %{change: {AshOnetime.Change, opts}} ->
        match?(%AshOnetime.Resource.Protection{}, opts[:protection])

      _other ->
        false
    end) == 1
  end

  defp valid_wrapper?(_action), do: false

  defp verifier_error(dsl_state, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: [:onetime],
       message: message
     )}
  end
end
