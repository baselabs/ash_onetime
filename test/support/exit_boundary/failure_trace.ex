defmodule AshOnetime.Test.ExitBoundary.FailureTrace do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.{FailureTwins, Hooks, References}

  def check(side, indexed) do
    s = %{claimed: MapSet.new(), errors: [], sources: %{}, pending: %{}, references: %{}}
    state = Enum.reduce(indexed.events, s, fn e, s -> step(e, s, side) end)
    Enum.reduce(state.references, state, fn {pid, reference}, s ->
      source = Enum.find(indexed.events, &(&1.pid == pid))
      check(s, source, :unfinished_failure_reference, reference.position, length(reference.events))
    end)
  end

  defp step(%{pid: pid} = e, %{references: refs} = s, _side) when is_map_key(refs, pid),
    do: advance(s, e)
  defp step(%{event: {pid, :call, {AshOnetime.Error, :new, _}}} = e, s, side) do
    if Enum.any?(e.stack, fn
      {AshOnetime.Delivery, name, 0} -> name in [:invalid, :requires_call]
      _ -> false
    end) do
      expected = FailureTwins.error(side.row.branch)
      reference = References.capture(fn ->
        AshOnetime.Error.new(expected.code, expected.message)
      end, {AshOnetime.Error, :new, 2})
      s = put_in(s.references[pid], %{events: reference, position: 0})
      advance(s, e)
    else
      if Map.has_key?(s.references, pid), do: advance(s, e), else: s
    end
  end
  defp step(e, s, side) do
    if FailureTwins.selected?(side) and side.row.branch == :producer_failure do
      producer_twin(e, s, side)
    else
      s
    end
  end

  defp producer_twin(%{event: {pid, :call, {_, _, args}}} = e, s, side) do
    fault = FailureTwins.trace_mfa(FailureTwins.template(side.row))
    slot = FailureTwins.slot(side.row)
    library = Hooks.trace_mfa(side.hooks[slot])
    cond do
      e.mfa == fault ->
        {inputs, environment} = Enum.split(args, if(side.row.type == :action, do: 1, else: 2))
        original = Enum.find(environment, &is_function/1)
        s = check(s, e, :failure_environment, environment, FailureTwins.environment(side.row, original))
        s = case Hooks.validate_library(original, slot, side) do
          :ok -> s
          {:error, rule, expected, actual} -> check(s, e, rule, actual, expected)
        end
        s |> put_in([:sources, :entry_arguments], inputs) |> claim(e)
      e.mfa == {AshOnetime.Change, :complete, 2} ->
        source = Map.fetch!(s.sources, :admitted)
        callback = FailureTwins.failure_callback(FailureTwins.error(:producer_failure))
        s = check(s, e, :failure_completion_arguments, args, [source, callback])
        callbacks = References.capture(fn -> callback.(source) end, FailureTwins.trace_mfa(callback))
        replay = References.capture(fn -> AshOnetime.Admission.replay?(source) end, {AshOnetime.Admission, :replay?, 1})
        result = {:error, FailureTwins.error(:producer_failure)}
        events = [%{event: {pid, :call, {AshOnetime.Change, :complete, [source, callback]}}}] ++ callbacks ++ replay ++
          [%{event: {pid, :return_from, {AshOnetime.Change, :complete, 2}, result}}]
        s = put_in(s.references[pid], %{events: events, position: 0})
        advance(s, e)
      e.mfa == library ->
        put_in(s.sources[:library_entry], args)
      true -> s
    end
  end
  defp producer_twin(%{event: {_, :return_from, mfa, value}} = e, s, side) do
    library = Hooks.trace_mfa(side.hooks[FailureTwins.slot(side.row)])
    cond do
      side.row.type == :action and mfa == library ->
        check(s, e, :failure_admitted_source, value, Map.fetch!(s.sources, :admitted)) |> claim(e)
      side.row.type != :action and mfa == FailureTwins.trace_mfa(FailureTwins.template(side.row)) ->
        check(s, e, :failure_wrapper_return, value, {:error, FailureTwins.error(:producer_failure)}) |> claim(e)
      mfa in [{AshOnetime.Change, :reserve, 4}, {AshOnetime.GenericAction, :reserve, 4}] -> put_in(s.sources[:admitted], value)
      true -> s
    end
  end
  defp producer_twin(_, s, _), do: s

  defp advance(s, e) do
    reference = Map.fetch!(s.references, e.pid)
    expected = Enum.at(reference.events, reference.position)
    s = check(s, e, :failure_reference, Tuple.delete_at(e.event, 0),
      if(expected, do: Tuple.delete_at(expected.event, 0), else: :undeclared_fault_event)) |> claim(e)
    if reference.position + 1 == length(reference.events) do
      %{s | references: Map.delete(s.references, e.pid)}
    else
      put_in(s.references[e.pid], %{reference | position: reference.position + 1})
    end
  end
  defp claim(s, e), do: %{s | claimed: MapSet.put(s.claimed, e.index)}
  defp check(s, _e, _rule, a, b) when a === b, do: s
  defp check(s, e, rule, actual, expected), do: %{s | errors: [
    %{index: e.index, at: Map.take(e, [:mfa, :role, :stack]), rule: rule, actual: actual, expected: expected} | s.errors]}
end
