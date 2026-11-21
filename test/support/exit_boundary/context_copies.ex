defmodule AshOnetime.Test.ExitBoundary.ContextCopies do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Registry

  def slots, do: Registry.context_copy_slots()

  # The framework builds Implementation.Context before calling before_action.
  # That hook's input is the captured source, not the later admitted input.
  def source(side) do
    case side.hooks[{:before_action, 0}] do
      %{identity: {module, function, arity, _, _}, sources: env} ->
        trace_arity = arity + length(env)

        Enum.find_value(side.run.events, fn
          %{event: {_, :call, {^module, ^function, [input | _] = arguments}}}
          when length(arguments) == trace_arity ->
            {:source, input.context}

          _ ->
            nil
        end)

      nil ->
        nil
    end
  end

  def validate(
        %Ash.Resource.Actions.Implementation.Context{source_context: context},
        {:source, source}
      ),
      do: context === source

  def validate(_, _), do: false
end
