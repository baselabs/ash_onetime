defmodule AshOnetime.Test.TestFormatter do
  @moduledoc false
  use GenServer

  alias AshOnetime.Test.ExitBoundary.Diagnostics

  @impl true
  def init(options) do
    IO.puts("Running ExUnit with seed: #{options[:seed]}")
    {:ok, %{passed: 0, failed: 0, excluded: 0, skipped: 0}}
  end

  @impl true
  def handle_cast({:test_finished, %{state: nil}}, state) do
    IO.write(".")
    {:noreply, Map.update!(state, :passed, &(&1 + 1))}
  end

  def handle_cast({:test_finished, %{state: {:failed, failures}} = test}, state) do
    print_failure(test, failures)
    {:noreply, Map.update!(state, :failed, &(&1 + 1))}
  end

  def handle_cast({:test_finished, %{state: {:invalid, _}}}, state),
    do: {:noreply, Map.update!(state, :failed, &(&1 + 1))}

  def handle_cast({:test_finished, %{state: {:excluded, _}}}, state),
    do: {:noreply, Map.update!(state, :excluded, &(&1 + 1))}

  def handle_cast({:test_finished, %{state: {:skipped, _}}}, state),
    do: {:noreply, Map.update!(state, :skipped, &(&1 + 1))}

  def handle_cast({:module_finished, %{state: {:failed, failures}} = module}, state) do
    print_failure(module, failures)
    {:noreply, state}
  end

  def handle_cast({:suite_finished, times}, state) do
    IO.puts("\n" <> ExUnit.Formatter.format_times(times))
    total = state.passed + state.failed
    result = if state.failed == 0, do: "#{state.passed}", else: "#{state.passed}/#{total}"
    excluded = if state.excluded == 0, do: "", else: ", #{state.excluded} excluded"
    skipped = if state.skipped == 0, do: "", else: ", #{state.skipped} skipped"
    IO.puts("Result: #{result} passed#{excluded}#{skipped}")
    if state.failed > 0, do: IO.puts("Failed: #{state.failed} tests")
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Diagnostics.status(status)

  # ExUnit's failure terms remain intact in its runner. Never invoke an exception's
  # message/1 or a default Inspect implementation on those terms, or on test logs.
  def print_failure(test, failures) do
    for {kind, error, stacktrace} <- failures do
      record = failure(test, error, stacktrace)
      IO.puts("\n#{record.test_name} (#{record.file}:#{record.line})")
      IO.puts("  code: " <> record.assertion)
      IO.puts("  " <> Diagnostics.render(%{kind: kind, error: error, stack: stack(stacktrace)}))
    end
  end

  def failure(test, _error, stacktrace) do
    file = Path.expand(Map.get(Map.get(test, :tags, %{}), :file, Map.get(test, :file)))

    line =
      Enum.find_value(stacktrace, fn
        {_module, _function, _arity, location} ->
          if location[:file] && Path.expand(to_string(location[:file])) == file,
            do: location[:line]

        _ ->
          nil
      end) || 0

    %{
      test_name: test.name |> Atom.to_string() |> String.replace_prefix("test ", ""),
      file: Path.relative_to_cwd(file),
      line: line,
      assertion: source_assertion(file, line)
    }
  end

  defp source_assertion(file, line) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {_ast, assertions} =
        Macro.prewalk(ast, [], fn
          {name, metadata, arguments} = node, found
          when name in [:assert, :refute, :assert_raise, :assert_receive, :refute_receive, :flunk] and
                 is_list(arguments) ->
            {node, if(metadata[:line] == line, do: [node | found], else: found)}

          node, found ->
            {node, found}
        end)

      assertions |> List.first() |> Macro.to_string()
    else
      _ -> "source assertion unavailable"
    end
  end

  defp stack(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, arguments, location} ->
        arity = if is_list(arguments), do: length(arguments), else: arguments
        %{mfa: {module, function, arity}, line: location[:line]}

      _ ->
        :native_frame
    end)
  end
end
