defmodule AshOnetime.Test.ExitBoundary.PathFrames do
  @moduledoc false
  alias AshOnetime.Delivery
  alias AshOnetime.Test.ExitBoundary.Hooks

  def declarations(row, hooks) do
    entry =
      case row.type do
        :create -> {Ash.Actions.Create, :run, 4}
        :update -> {Ash, :update, 3}
        :destroy -> {Ash, :destroy, 2}
        :action -> {Ash, :run_action, 2}
      end

    outer = [
      %{mfa: {Delivery, :armed, 4}, anchor: entry, source: {:armed, 4, :dispatch, 2}},
      %{
        mfa: {Delivery, :armed_call, 4},
        anchor: {Delivery, :armed, 4},
        source: {:armed_call, 4, :armed, 4}
      }
    ]

    # The code's call structure determines these declarations, not observed
    # stacks. Generic before-action is suspended in claim/reserve/produce;
    # after-action is suspended in complete. Consumer hooks run between them.
    stage = Map.get(row, :frame_stage, suspension(row))
    module = if row.type == :action, do: AshOnetime.GenericAction, else: AshOnetime.Change

    {slot, callee} =
      case {row.type, stage} do
        {:action, :reserve} -> {{:before_action, 0}, {:reserve, 4}}
        {:action, :producer} -> {{:before_action, 0}, {:produce, 4}}
        {:action, :complete} -> {{:after_action, 1}, {:complete, 2}}
        {:action, _} -> {nil, nil}
        {_, :reserve} -> {{:around_action, 0}, {:reserve, 4}}
        {_, :producer} -> {{:around_action, 0}, {:produce, 4}}
        {_, _} -> {{:around_action, 0}, {:complete, 2}}
      end

    inner =
      if slot do
        hook = Map.fetch!(hooks, slot)
        {function, arity} = callee

        declaration = %{
          mfa: Hooks.trace_mfa(hook),
          anchor: {module, function, arity},
          source: {:install_delivery, 4, function, arity}
        }

        # CRUD's ordinary hook retains a non-tail reserve call. Generic's
        # ordinary before/after hooks and CRUD's completion are tail calls.
        if row.type != :action and stage == :reserve do
          [Map.merge(declaration, %{replace_hook: slot, installer: {module, :install, 3}})]
        else
          [declaration]
        end
      else
        []
      end

    case row.branch do
      :transaction -> []
      :direct -> []
      _ -> inner ++ outer
    end
  end

  def path(row),
    do: {row.action, row.external?, row.branch, row.fault, Map.get(row, :frame_stage)}

  defp suspension(%{branch: :consumer_failure}), do: :consumer
  defp suspension(%{branch: :producer_failure}), do: :producer
  defp suspension(%{fault: :codec_decode}), do: :reserve
  defp suspension(_), do: :complete

  def build(row, hooks) do
    twin = Hooks.reference(AshOnetime.Test.ExitBoundary.Returned, row.action, row.type)

    Enum.map(declarations(row, hooks), fn %{mfa: {module, function, arity}, source: source} = slot ->
      slot =
        if Map.has_key?(slot, :replace_hook),
          do: Map.put(slot, :twin_mfa, Hooks.trace_mfa(twin[slot.replace_hook])),
          else: slot

      Map.put(slot, :frame, {module, function, arity, location(module, source)})
    end)
  end

  def expected(twin, frames, depth, filters \\ nil) do
    inserted =
      Enum.reduce(frames, twin, fn
        %{twin_mfa: twin_mfa, frame: frame}, stack ->
          Enum.map(stack, fn item -> if mfa(item) == twin_mfa, do: frame, else: item end)

        %{anchor: anchor, frame: frame}, stack ->
          Enum.flat_map(stack, fn item ->
            if mfa(item) == anchor, do: [item, frame], else: [item]
          end)
      end)
      |> Enum.take(depth)

    if filters == nil, do: inserted, else: Splode.filter_stacktrace(inserted, filters)
  end

  def mfa({m, f, a, _}), do: {m, f, if(is_list(a), do: length(a), else: a)}
  def mfa(_), do: nil

  def witness?(stack, frame) do
    Enum.chunk_every(stack, 2, 1, :discard)
    |> Enum.any?(fn [callee, suspended] ->
      mfa(callee) == frame.anchor and suspended === frame.frame
    end)
  end

  # Erlang abstract code is obtained from the compiled module's debug backend.
  # The location is the call expression in the declaring function, including calls
  # in its anonymous functions. No part of the checked stack supplies it.
  def location(module, {function, arity, callee, callee_arity, ordinal}) do
    {file, lines} = locations(module, function, arity, callee, callee_arity)
    [file: file, line: Enum.fetch!(lines, ordinal)]
  end

  def location(module, {function, arity, callee, callee_arity}) do
    AshOnetime.Test.ExitBoundary.References.memo(
      {:location, module, module.module_info(:md5), function, arity, callee, callee_arity},
      fn ->
        compiled_location(module, {function, arity, callee, callee_arity})
      end
    )
  end

  defp compiled_location(module, {function, arity, callee, callee_arity}) do
    {file, [line]} = locations(module, function, arity, callee, callee_arity)
    [file: file, line: line]
  end

  defp locations(module, function, arity, callee, callee_arity) do
    {:ok, {^module, chunks}} = :beam_lib.chunks(:code.which(module), [:debug_info])
    {:debug_info_v1, backend, data} = chunks[:debug_info]
    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])

    {:function, _, ^function, ^arity, clauses} =
      Enum.find(forms, fn
        {:function, _, f, a, _} -> f == function and a == arity
        _ -> false
      end)

    lines = calls(clauses, callee, callee_arity) |> Enum.uniq()
    {:attribute, _, :file, {file, _}} = Enum.find(forms, &match?({:attribute, _, :file, _}, &1))
    {file, lines}
  end

  defp calls({:call, annotation, {:atom, _, callee}, args}, callee, arity)
       when length(args) == arity, do: [:erl_anno.line(annotation)]

  defp calls(
         {:call, annotation, {:remote, _, {:atom, _, _module}, {:atom, _, callee}}, args},
         callee,
         arity
       )
       when length(args) == arity, do: [:erl_anno.line(annotation)]

  defp calls(tuple, callee, arity) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> calls(callee, arity)

  defp calls(list, callee, arity) when is_list(list),
    do: Enum.flat_map(list, &calls(&1, callee, arity))

  defp calls(_, _, _), do: []
end
