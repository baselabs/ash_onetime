defmodule AshOnetime.Test.ExitBoundary.ComparatorMutants do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Comparator

  def rules, do: [:k, :inv, :completion]

  # Disable K's expression at its source, while still binding that return and
  # checking every later copy. The captured events are passed through unchanged.
  def edits(:k) do
    [
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "    state =\n      if key == :ref, do: bind(state, :key, {Delivery, :crypto.hash(:sha256, value)}), else: state\n\n",
        mutated: ""
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original: "  defp returned(state, _e, {:erlang, :make_ref, 0}, [], value, _side),",
        mutated:
          "  defp returned(state, e, {Delivery, :key, 1}, _, value, _side) do\n    if Map.has_key?(state.bound, :key),\n      do: exact(state, e, :key_copy, value, state.bound.key),\n      else: bind(state, :key, value)\n  end\n\n  defp returned(state, _e, {:erlang, :make_ref, 0}, [], value, _side),"
      },
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original:
          "  defp expected_return({Delivery, :key, 1}, [ref], _, _),\n    do: {:value, {Delivery, :crypto.hash(:sha256, ref)}}\n",
        mutated:
          "  defp expected_return({Delivery, :key, 1}, [_ref], _, b),\n    do: {:value, b.key}\n"
      }
    ]
  end

  # Bind inv at its first claimed put instead of its entropy return. Every
  # later inv copy is still checked against that one captured value.
  def edits(:inv) do
    [
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original: "    state = bind(state, key, value)\n",
        mutated: "    state = if key == :ref, do: bind(state, key, value), else: state\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original: "      case {function, rest} do\n",
        mutated:
          "      state = case {function, rest, Enum.find(e.stack, fn {m, _, _} -> m == Delivery end)} do\n        {:put, [{:claimed, inv, _}], {Delivery, :claim_entry, 6}} -> bind(state, :inv, inv)\n        _ -> state\n      end\n\n      case {function, rest} do\n"
      }
    ]
  end

  # Disable the store-to-completion grounding, bind the first done tuple,
  # and retain every later readback copy and its real reference computation.
  def edits(:completion) do
    [
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "          state = exact(state, e, :dictionary_binding, value, expected)\n",
        mutated:
          "          {state, expected} =\n            case {value, expected} do\n              {{:done, inv, :executed, envelope, {target, claim}},\n               {:done, expected_inv, :executed, expected_envelope, _}}\n              when inv === expected_inv and envelope === expected_envelope ->\n                state =\n                  state\n                  |> bind(:target, target)\n                  |> bind(:c_admit, claim)\n                  |> bind(:completion, {target, claim})\n\n                {state, value}\n\n              _ ->\n                {state, expected}\n            end\n\n          state = exact(state, e, :dictionary_binding, value, expected)\n"
      },
      %{
        path: "test/support/exit_boundary/readback.ex",
        original:
          "        prepared = Map.get_lazy(side, :readback_reference, fn -> capture(side, bound) end)\n",
        mutated: "        prepared = capture(side, bound)\n"
      }
    ]
  end

  def compare(pair, rule) do
    grouped = Enum.group_by(edits(rule), & &1.path)
    originals = Map.new(grouped, fn {path, _} -> {path, File.read!(path)} end)
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      for {path, edits} <- grouped do
        source =
          Enum.reduce(edits, Map.fetch!(originals, path), fn edit, source ->
            unless length(:binary.matches(source, edit.original)) == 1,
              do: raise("comparator mutant requires one exact source site: #{path}")

            String.replace(source, edit.original, edit.mutated, global: false)
          end)

        File.write!(path, source)
        Code.compile_string(source, path)
      end

      Comparator.compare(pair)
    after
      try do
        for {path, source} <- originals, do: File.write!(path, source)

        for {path, source} <- originals do
          unless File.read!(path) === source,
            do: raise("comparator source restoration failed: #{path}")
        end

        for {path, source} <- originals, do: Code.compile_string(source, path)
      after
        Code.compiler_options(previous)
      end
    end
  end
end
