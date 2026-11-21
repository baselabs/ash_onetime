defmodule AshOnetime.Test.ExitBoundary.PathFrames do
  alias AshOnetime.Delivery
  alias AshOnetime.Test.ExitBoundary.Hooks
  alias AshOnetime.Test.ExitBoundary.References
  @moduledoc false

  def declarations(row, hooks) do
    entry = action_entry(row.type)

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

    {slot, callee} = hook_callee(row.type, stage)
    inner = inner_declarations(slot, callee, row, hooks, module, stage)

    case row.branch do
      :transaction -> []
      :direct -> []
      _ -> inner ++ outer
    end
  end

  defp action_entry(:create), do: {Ash.Actions.Create, :run, 4}
  defp action_entry(:update), do: {Ash, :update, 3}
  defp action_entry(:destroy), do: {Ash, :destroy, 2}
  defp action_entry(:action), do: {Ash, :run_action, 2}

  defp hook_callee(:action, :reserve), do: {{:before_action, 0}, {:reserve, 4}}
  defp hook_callee(:action, :producer), do: {{:before_action, 0}, {:produce, 4}}
  defp hook_callee(:action, :complete), do: {{:after_action, 1}, {:complete, 2}}
  defp hook_callee(:action, _), do: {nil, nil}
  defp hook_callee(_, :reserve), do: {{:around_action, 0}, {:reserve, 4}}
  defp hook_callee(_, :producer), do: {{:around_action, 0}, {:produce, 4}}
  defp hook_callee(_, _), do: {{:around_action, 0}, {:complete, 2}}

  defp inner_declarations(nil, _, _, _, _, _), do: []

  defp inner_declarations(slot, {function, arity}, row, hooks, module, stage) do
    hook = Map.fetch!(hooks, slot)

    declaration = %{
      mfa: Hooks.trace_mfa(hook),
      anchor: {module, function, arity},
      source: {:install_delivery, 4, function, arity}
    }

    # Only CRUD's ordinary reserve hook is a non-tail call.
    if row.type != :action and stage == :reserve,
      do: [Map.merge(declaration, %{replace_hook: slot, installer: {module, :install, 3}})],
      else: [declaration]
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
      Enum.reduce(frames, twin, &insert_frame/2)
      |> Enum.take(depth)

    if filters == nil, do: inserted, else: Splode.filter_stacktrace(inserted, filters)
  end

  defp insert_frame(%{twin_mfa: twin_mfa, frame: frame}, stack) do
    Enum.map(stack, fn item -> if mfa(item) == twin_mfa, do: frame, else: item end)
  end

  defp insert_frame(%{anchor: anchor, frame: frame}, stack) do
    Enum.flat_map(stack, fn item ->
      if mfa(item) == anchor, do: [item, frame], else: [item]
    end)
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
    References.memo(
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
