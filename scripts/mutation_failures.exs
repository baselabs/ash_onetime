defmodule AshOnetime.MutationFailures do
  @moduledoc false
  @prefix "ASH_ONETIME_TEST_FAILURE="

  def records(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if String.starts_with?(line, @prefix) do
        case Jason.decode(String.replace_prefix(line, @prefix, "")) do
          {:ok, %{"test_name" => name, "file" => file, "line" => line} = record}
          when is_binary(name) and is_binary(file) and is_integer(line) ->
            [record]

          _ ->
            raise "invalid structured ExUnit failure record"
        end
      else
        []
      end
    end)
  end

  def matches?(records, mutation, test_name, assertion) do
    Enum.any?(records, fn record ->
      # rule:mutation-checker-failure-attribution
      record["test_name"] == test_name and
        Path.expand(record["file"]) in Enum.map(List.wrap(mutation.test), &Path.expand/1) and
        assertion_matches?(record, mutation, assertion)
    end)
  end

  defp assertion_matches?(record, %{assertion_line: line}, _assertion),
    do: record["line"] == line

  # Existing entries name source text. Bind that text to the assertion in THIS
  # failure, while newly added entries pin the source assertion line directly.
  defp assertion_matches?(record, _mutation, assertion),
    do: is_binary(record["assertion"]) and String.contains?(record["assertion"], assertion)
end
