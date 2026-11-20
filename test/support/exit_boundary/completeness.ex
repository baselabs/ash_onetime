defmodule AshOnetime.Test.ExitBoundary.Completeness do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.{
    ContextCopies,
    Declarations,
    PathFrames,
    Registry,
    Returned,
    Withheld
  }

  # This is an audit of the declared slots against independently captured terms.
  # Missing entries and entries with no witness both fail; neither side of the audit
  # is manufactured from the other.
  def check(pairs) do
    declarations = Declarations.pair(Withheld, Returned)

    hook_slots =
      for type <- [:create, :update, :destroy, :action],
          slot <- Registry.hook_slots(type),
          into: MapSet.new(),
          do: {type, slot}

    hooks = Enum.reduce(pairs, MapSet.new(), &hook_witnesses/2)
    copies = Enum.reduce(pairs, MapSet.new(), &copy_witnesses/2)

    declared_frames =
      for pair <- pairs,
          frame <- declared_frames(pair),
          into: MapSet.new(),
          do: {PathFrames.path(pair.row), frame.mfa}

    frames =
      Enum.reduce(pairs, MapSet.new(), fn pair, seen ->
        stacks = stacks(pair.run.run.events)

        Enum.reduce(declared_frames(pair), seen, fn frame, acc ->
          if Enum.any?(stacks, &PathFrames.witness?(&1, frame)),
            do: MapSet.put(acc, {PathFrames.path(pair.row), frame.mfa}),
            else: acc
        end)
      end)

    %{
      declarations: declarations.errors,
      hooks: MapSet.difference(hook_slots, hooks),
      copies: MapSet.difference(MapSet.new(ContextCopies.slots()), copies),
      frames: MapSet.difference(declared_frames, frames)
    }
  end

  defp declared_frames(pair) do
    Map.get_lazy(pair, :path_frame_declarations, fn ->
      PathFrames.build(pair.row, pair.run.hooks)
    end)
  end

  defp hook_witnesses(pair, seen) do
    left = subjects(pair.run)
    right = subjects(pair.twin)

    Enum.reduce(Registry.hook_slots(pair.row.type), seen, fn {field, index} = slot, acc ->
      run = Enum.flat_map(left, &(Map.fetch!(&1, field) |> Enum.drop(index) |> Enum.take(1)))
      twin = Enum.flat_map(right, &(Map.fetch!(&1, field) |> Enum.drop(index) |> Enum.take(1)))
      ri = get_in(pair.run.hooks, [slot, :identity])
      ti = get_in(pair.twin.hooks, [slot, :identity])

      if ri != nil and ti != nil and ri != ti and
           Enum.any?(run, &identity?(&1, ri)) and Enum.any?(twin, &identity?(&1, ti)),
         do: MapSet.put(acc, {pair.row.type, slot}),
         else: acc
    end)
  end

  defp subjects(side) do
    (Map.get(side, :setup_events, []) ++ side.run.events)
    |> Enum.flat_map(
      &terms(&1.event, fn
        %Ash.Changeset{} -> true
        %Ash.ActionInput{} -> true
        _ -> false
      end)
    )
  end

  defp identity?(fun, expected) when is_function(fun) do
    info = Map.new(Function.info(fun))
    {info.module, info.name, info.arity, info.new_uniq, info.index} == expected
  end

  defp identity?(_, _), do: false

  defp copy_witnesses(pair, seen) do
    Enum.reduce(ContextCopies.slots(), seen, fn {m, f, _} = mfa, acc ->
      left =
        for %{event: {_, :call, {^m, ^f, [_, _, context]}}} <- pair.run.run.events,
            do: context

      right =
        for %{event: {_, :call, {^m, ^f, [_, _, context]}}} <- pair.twin.run.events,
            do: context

      sources = {ContextCopies.source(pair.run), ContextCopies.source(pair.twin)}

      case sources do
        {{:source, a}, {:source, b}} when a !== b ->
          if Enum.any?(left, &ContextCopies.validate(&1, {:source, a})) and
               Enum.any?(right, &ContextCopies.validate(&1, {:source, b})),
             do: MapSet.put(acc, mfa),
             else: acc

        _ ->
          acc
      end
    end)
  end

  def stacks(events) do
    Enum.flat_map(events, fn
      %{event: {_, :return_from, {module, :info, 2}, {:current_stacktrace, stack}}}
      when module == Process ->
        [stack]

      %{event: {_, :return_from, {:erlang, :process_info, 2}, {:current_stacktrace, stack}}} ->
        [stack]

      %{event: {_, :call, {:erlang, :raise, [_, _, stack]}}} ->
        [stack]

      %{event: {_, :call, {Splode, :filter_stacktrace, [stack, _]}}} ->
        [stack]

      %{event: event} ->
        terms(event, fn value ->
          is_struct(value, Ash.Error.Stacktrace) or is_struct(value, Splode.Stacktrace)
        end)
        |> Enum.map(& &1.stacktrace)
    end)
  end

  defp terms(value, predicate) do
    own = if predicate.(value), do: [value], else: []

    nested =
      cond do
        is_map(value) -> Enum.flat_map(Map.to_list(value), &terms(&1, predicate))
        is_tuple(value) -> value |> Tuple.to_list() |> Enum.flat_map(&terms(&1, predicate))
        is_list(value) -> list_terms(value, predicate)
        true -> []
      end

    own ++ nested
  end

  defp list_terms([], _predicate), do: []

  defp list_terms([head | tail], predicate),
    do: terms(head, predicate) ++ list_terms(tail, predicate)

  defp list_terms(tail, predicate), do: terms(tail, predicate)
end
