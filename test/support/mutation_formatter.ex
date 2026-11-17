defmodule AshOnetime.Test.MutationFormatter do
  @moduledoc false
  use GenServer

  def init(_options), do: {:ok, nil}

  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, state) do
    for {_kind, error, stacktrace} <- failures do
      file = Path.expand(test.tags.file)
      line = assertion_line(stacktrace, file)

      record = %{
        test_name: test.name |> Atom.to_string() |> String.replace_prefix("test ", ""),
        file: Path.relative_to_cwd(file),
        line: line,
        assertion: Exception.message(error)
      }

      IO.puts("ASH_ONETIME_TEST_FAILURE=" <> Jason.encode!(record))
    end

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp assertion_line(stacktrace, file) do
    Enum.find_value(stacktrace, fn
      {_module, _function, _arity, location} ->
        if path_matches?(location[:file], file), do: location[:line]

      _ ->
        nil
    end) || raise "failed test has no assertion location in #{Path.relative_to_cwd(file)}"
  end

  defp path_matches?(nil, _file), do: false
  defp path_matches?(path, file), do: Path.expand(to_string(path)) == file
end
