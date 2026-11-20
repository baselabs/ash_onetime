defmodule AshOnetime.Test.ExitBoundary.ComparatorMutants do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Comparator

  def rules, do: [:k]

  # Disable K's expression at its source, while still binding that return and
  # checking every later copy. The captured events are passed through unchanged.
  def edits(:k) do
    [
      %{path: "test/support/exit_boundary/permitted_trace.ex", original: "    state =\n      if key == :ref, do: bind(state, :key, {Delivery, :crypto.hash(:sha256, value)}), else: state\n\n", mutated: ""},
      %{path: "test/support/exit_boundary/permitted_trace.ex", original: "  defp returned(state, _e, {:erlang, :make_ref, 0}, [], value, _side),", mutated: "  defp returned(state, e, {Delivery, :key, 1}, _, value, _side) do\n    if Map.has_key?(state.bound, :key),\n      do: exact(state, e, :key_copy, value, state.bound.key),\n      else: bind(state, :key, value)\n  end\n\n  defp returned(state, _e, {:erlang, :make_ref, 0}, [], value, _side),"},
      %{path: "test/support/exit_boundary/trace_program.ex", original: "  defp expected_return({Delivery, :key, 1}, [ref], _, _),\n    do: {:value, {Delivery, :crypto.hash(:sha256, ref)}}\n", mutated: "  defp expected_return({Delivery, :key, 1}, [_ref], _, b),\n    do: {:value, b.key}\n"}
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
          unless File.read!(path) === source, do: raise("comparator source restoration failed: #{path}")
        end

        for {path, source} <- originals, do: Code.compile_string(source, path)
      after
        Code.compiler_options(previous)
      end
    end
  end
end
