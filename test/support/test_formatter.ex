defmodule AshOnetime.Test.TestFormatter do
  @moduledoc false
  use GenServer

  alias AshOnetime.Test.ExitBoundary.Diagnostics

  @assertions [
    :assert,
    :refute,
    :assert_raise,
    :assert_receive,
    :assert_received,
    :refute_receive,
    :refute_received,
    :flunk
  ]

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

  def failure(test, error, stacktrace) do
    file = Path.expand(Map.get(Map.get(test, :tags, %{}), :file, Map.get(test, :file)))

    line =
      Enum.find_value(stacktrace, fn
        {_module, _function, _arity, location} ->
          if location[:file] && Path.expand(to_string(location[:file])) == file,
            do: location[:line]

        _ ->
          nil
      end) || 0

    {line, assertion} = source_assertion(file, line, error)

    %{
      test_name: test.name |> Atom.to_string() |> String.replace_prefix("test ", ""),
      file: Path.relative_to_cwd(file),
      line: line,
      assertion: assertion,
      postgres_code: postgres_code(error)
    }
  end

  defp postgres_code(%ExUnit.AssertionError{right: {:migration_error, error}}),
    do: postgres_code(error)

  defp postgres_code(%Postgrex.Error{postgres: %{pg_code: code}}) when is_binary(code) do
    if Regex.match?(~r/\A[0-9A-Z]{5}\z/, code), do: code
  end

  defp postgres_code(_error), do: nil

  defp source_assertion(file, line, error) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {_ast, assertions} =
        Macro.prewalk(ast, [], fn
          {name, metadata, arguments} = node, found
          when name in @assertions and is_list(arguments) ->
            {node, [{metadata[:line], node} | found]}

          node, found ->
            {node, found}
        end)

      selected =
        expression_assertion(assertions, error) ||
          Enum.find(assertions, fn {start, node} -> start <= line and line <= last_line(node) end) ||
          migration_assertion(ast, line, error)

      assertion_location(selected, line)
    else
      _ -> {line, "source assertion unavailable"}
    end
  end

  defp assertion_location({start, node}, line) do
    location = if start <= line and line <= last_line(node), do: line, else: start
    {location, Macro.to_string(node)}
  end

  defp assertion_location(nil, line), do: {line, "source assertion unavailable"}

  # Ecto reraises a migration task's native stack. Its caller preserves the
  # local rescue frame while retaining the original exception and native frames.
  # Attribute only that rescue's single migration assertion, never a nearby test
  # assertion or a failure raised by the callback after the migration.
  defp migration_assertion(ast, line, %Postgrex.Error{}) do
    {_ast, matches} =
      Macro.prewalk(ast, [], fn
        {:try, _, [clauses]} = node, matches ->
          rescue_clause = Keyword.get(clauses, :rescue)

          if rescue_clause && first_line(rescue_clause) <= line &&
               line <= last_line(rescue_clause) do
            {_body, assertions} =
              Macro.prewalk(Keyword.fetch!(clauses, :do), [], fn
                {:assert, metadata,
                 [{:=, _, [:ok, {{:., _, [{:__aliases__, _, [:Ecto, :Migrator]}, :up]}, _, _}]}]} =
                    assertion,
                found ->
                  {assertion, [{metadata[:line], assertion} | found]}

                body, found ->
                  {body, found}
              end)

            {node, assertions ++ matches}
          else
            {node, matches}
          end

        node, matches ->
          {node, matches}
      end)

    case matches do
      [assertion] -> assertion
      _ -> nil
    end
  end

  defp migration_assertion(_ast, _line, _error), do: nil

  defp first_line(expression) do
    {_expression, line} =
      Macro.prewalk(expression, nil, fn
        {_, metadata, _} = node, line when is_list(metadata) ->
          value = metadata[:line]
          {node, if(value, do: min(line || value, value), else: line)}

        node, line ->
          {node, line}
      end)

    line || 0
  end

  # Tail calls can remove an assertion's caller from the native stack. ExUnit's
  # assertion macros retain their quoted source expression. Use it only to select
  # one parsed source assertion; no runtime field becomes printable source.
  defp expression_assertion(assertions, %ExUnit.AssertionError{expr: {kind, _, [expression]}}) do
    matches =
      Enum.filter(assertions, fn
        {_line, {^kind, _, [source | _]}} -> quoted(source) == quoted(expression)
        _ -> false
      end)

    case matches do
      [assertion] -> assertion
      _ -> nil
    end
  end

  defp expression_assertion(_assertions, _error), do: nil

  defp quoted(expression) do
    Macro.prewalk(expression, fn
      {name, _metadata, context} when is_atom(name) and is_atom(context) -> {name, [], nil}
      {name, _metadata, arguments} when is_list(arguments) -> {name, [], arguments}
      node -> node
    end)
  end

  defp last_line(expression) do
    {_expression, line} =
      Macro.prewalk(expression, 0, fn
        {_, metadata, _} = node, line when is_list(metadata) ->
          {node, max(line, metadata[:line] || 0)}

        node, line ->
          {node, line}
      end)

    line
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
