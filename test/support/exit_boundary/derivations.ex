defmodule AshOnetime.Test.ExitBoundary.Derivations do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.{Faults, References, Registry}

  @contract {AshOnetime.Response, :contract, 4}
  def build(indexed, side) do
    initial = %{active: %{}, slots: %{}, sources: prior_sources(side), errors: []}
    Enum.reduce(indexed.events, initial, &event(&1, &2, side))
  end

  defp prior_sources(side) do
    case Map.get(side, :prior_derivations) do
      nil ->
        %{}

      prior ->
        prior.sources
        |> Enum.group_by(fn {{root, _}, _} -> root end)
        |> Map.new(&last_source/1)
    end
  end

  defp last_source({root, sources}) do
    {_, value} = Enum.max_by(sources, fn {{_, n}, _} -> n end)
    {{root, -1}, value}
  end

  defp event(%{event: {pid, :call, {m, f, args}}} = e, state, side) do
    root = {m, f, length(args)}

    if root in Registry.derivations() and not Map.has_key?(state.active, pid) do
      reference = reference(root, args, side)
      frame = %{root: root, reference: reference, position: 0, input: args, index: e.index}
      state = put_in(state.active[pid], frame)
      # Source inputs remain in the paired comparison.
      advance(e, state, false)
    else
      interior(e, state)
    end
  end

  defp event(%{event: {pid, :return_from, root, _value}} = e, state, _) do
    case Map.get(state.active, pid) do
      %{root: ^root, reference: reference, position: position} = frame ->
        state = advance(e, state, true)

        state =
          if position + 1 == length(reference),
            do: state,
            else: fail(state, e, :derived_sequence_length, position + 1, length(reference))

        %{
          state
          | active: Map.delete(state.active, pid),
            sources: Map.put(state.sources, {root, frame.index}, elem(e.event, 3))
        }

      nil ->
        state

      _ ->
        interior(e, state)
    end
  end

  defp event(e, state, _), do: interior(e, state)

  defp reference(@contract, _args, side), do: side.contract_reference.events

  defp reference(root, args, side) do
    setup = fn -> Faults.put(side.row.fault) end
    events = References.capture(fn -> apply(elem(root, 0), elem(root, 1), args) end, root, setup)
    References.index(events)
  end

  defp interior(e, state) do
    case Map.get(state.active, e.pid) do
      nil -> state
      frame -> if frame.root in e.stack, do: advance(e, state, true), else: state
    end
  end

  defp advance(e, state, project?) do
    frame = state.active[e.pid]
    payload = Tuple.delete_at(e.event, 0)

    expected =
      case Enum.at(frame.reference, frame.position) do
        {_key, _ordinal, expected} -> expected
        nil -> :undeclared_derived_event
      end

    state =
      if payload === expected,
        do: state,
        else: fail(state, e, :derived_expression, payload, expected)

    state =
      if project? and payload === expected,
        do: put_in(state.slots[e.index], {:derived, frame.root, frame.position}),
        else: state

    put_in(state.active[e.pid], %{frame | position: frame.position + 1})
  end

  defp fail(state, e, rule, actual, expected),
    do: %{
      state
      | errors: [
          %{
            at: Map.take(e, [:mfa, :role, :stack]),
            index: e.index,
            rule: rule,
            actual: actual,
            expected: expected
          }
          | state.errors
        ]
    }
end
