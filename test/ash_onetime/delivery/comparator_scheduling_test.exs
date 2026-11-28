defmodule AshOnetime.Delivery.ComparatorSchedulingTest do
  alias AshOnetime.Test.ExitBoundary.Comparator
  alias AshOnetime.Test.ExitBoundary.Diagnostics
  alias AshOnetime.Test.ExitBoundary.Origins
  alias AshOnetime.Test.ExitBoundary.Scenarios
  alias AshOnetime.Test.ExitBoundary.Values
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false

  for {row, ordinal} <- Enum.with_index(Scenarios.rows()) do
    name = "#{row.action}/#{row.branch}/#{row.fault || :none}"
    @tag :u9
    @tag :u11
    @tag u9_path: name
    @tag u9_group: Integer.to_string(div(ordinal, 5))
    test "U9 and U11: twenty C-pos observations of #{name}", context do
      row = unquote(Macro.escape(row))
      context = with_references(context, [row])
      values = Values.set()[:va]

      # The first real path prepares Ecto/Postgrex's query cache. U11 measures
      # repeated execution on that prepared substrate; each observation still
      # captures its actual historical cache and compares every generated origin.
      warm = Scenarios.observe(row, values, context)
      assert_comparison(Comparator.compare(warm), :warmup)
      started = System.monotonic_time(:millisecond)

      profiles =
        for repetition <- 1..20 do
          pair = Scenarios.observe(row, values, context)
          assert_comparison(Comparator.compare(pair), repetition)

          for side <- [:run, :twin],
              into: %{},
              do: {side, Origins.build(pair[side]).origins |> Map.keys() |> Enum.sort()}
        end

      [expected | observations] = profiles
      divergence = Enum.find_index(observations, &(&1 != expected))

      assert is_nil(divergence),
             "U11: producer origin keys changed on repetition #{(divergence || 0) + 2}"

      IO.puts(
        "U9_PATH_SECONDS" <>
          ": " <>
          Diagnostics.render(
            %{
              group: unquote(Integer.to_string(div(ordinal, 5))),
              path: unquote(name),
              seconds: (System.monotonic_time(:millisecond) - started) / 1000
            },
            pretty: true
          )
      )
    end
  end

  defp assert_comparison(result, repetition) do
    failures =
      for difference <- Enum.take(result.errors, 4) do
        difference
        |> Map.take([:at, :rule, :path])
        |> Map.put(:index, repetition)
      end

    assert failures == []
  end
end
