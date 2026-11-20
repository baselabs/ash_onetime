defmodule AshOnetime.Test.ExitBoundary.Hooks do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Registry

  def reference(resource, action, type) do
    AshOnetime.Test.ExitBoundary.References.memo({:hooks, resource, action, type}, fn ->
      build_reference(resource, action, type)
    end)
  end
  defp build_reference(resource, action, type) do
    protection = AshOnetime.Resource.Info.protection(resource, action)
    context = %{installer_context: make_ref()}
    fresh = if type == :action,
      do: %Ash.ActionInput{resource: resource, action: Ash.Resource.Info.action(resource, action)},
      else: %Ash.Changeset{resource: resource, action: Ash.Resource.Info.action(resource, action)}
    {module, function, 3} = Registry.installer(type)
    installed = apply(module, function, [fresh, [protection: protection], context])
    cell = get_in(installed.context, [:private, :ash_onetime_delivery_cell])

    Map.new(Registry.hook_slots(type), fn {list, index} = slot ->
      hook = installed |> Map.fetch!(list) |> Enum.at(if(type == :action and list == :after_action, do: 0, else: index))
      info = Map.new(Function.info(hook))
      sources = Enum.map(info.env, fn value ->
        cond do
          value === protection -> :protection
          value === context -> :context
          not is_nil(cell) and value === cell -> :cell
          value === protection.executing_only -> :names
          true -> raise "installer captured an undeclared environment source"
        end
      end)
      {slot, %{identity: identity(info), sources: sources}}
    end)
  end

  def frames(reference, canonical) do
    Map.new(reference, fn {slot, info} ->
      {trace_mfa(info), trace_mfa(canonical[slot])}
    end)
  end

  def trace_mfa(%{identity: {m, f, a, _, _}, sources: sources}),
    do: {m, f, a + length(sources)}

  def environment(slot, side) do
    sources = %{protection: side.protection, names: side.protection.executing_only,
      context: installer_context(side), cell: side.bound[:cell]}
    Enum.map(side.hooks[slot].sources, fn
      key -> Map.fetch!(sources, key)
    end)
  end

  def validate(hook, slot, side) do
    if AshOnetime.Test.ExitBoundary.FailureTwins.selected?(side) and not Map.get(side, :pre_fault?, false) and
         slot == AshOnetime.Test.ExitBoundary.FailureTwins.slot(side.row),
      do: AshOnetime.Test.ExitBoundary.FailureTwins.validate(hook, side),
      else: validate_library(hook, slot, side)
  end
  def validate_library(hook, slot, side) when is_function(hook) do
    info = Map.new(Function.info(hook))
    reference = side.hooks[slot]
    expected = environment(slot, side)
    cond do
      identity(info) != reference.identity -> {:error, :o2c_code, reference.identity, identity(info)}
      info.env !== expected -> {:error, :o2c_environment, expected, info.env}
      true -> :ok
    end
  end
  def validate_library(value, _slot, _side), do: {:error, :o2c_not_function, :function, value}

  defp installer_context(side) do
    {module, function, _} = Registry.installer(side.row.type)
    Enum.find_value(Map.get(side, :setup_events, []) ++ side.run.events, fn
      %{event: {_, :call, {^module, ^function, [_subject, _opts, context]}}} -> {:found, context}
      _ -> nil
    end)
    |> case do
      {:found, context} -> context
      nil -> :missing_installer_context_origin
    end
  end

  defp identity(info), do: {info.module, info.name, info.arity, info.new_uniq, info.index}
end
