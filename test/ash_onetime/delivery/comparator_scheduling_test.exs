defmodule AshOnetime.Delivery.ComparatorSchedulingTest do
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false
  alias AshOnetime.Test.ExitBoundary.{Comparator, Origins, Scenarios, Values}

  for {row, ordinal} <- Enum.with_index(Scenarios.rows()) do
    name = "#{row.action}/#{row.branch}/#{row.fault || :none}"
    @tag :u9
    @tag :u11
    @tag u9_path: name
    @tag u9_group: Integer.to_string(div(ordinal, 5))
    test "U9 and U11: twenty C-pos observations of #{name}", context do
      started = System.monotonic_time(:millisecond)
      row = unquote(Macro.escape(row))
      context = with_references(context, [row])
      values = Values.set()[:va]

      profiles =
        for repetition <- 1..20 do
          pair = Scenarios.observe(row, values, context)
          result = Comparator.compare(pair)
          locations = Enum.map(result.errors, &{&1.at, &1.rule, &1.path})
          assert locations == [], "U9 repetition #{repetition}: #{inspect(locations)}"

          for side <- [:run, :twin],
              into: %{},
              do: {side, Origins.build(pair[side]).origins |> Map.keys() |> Enum.sort()}
        end

      assert length(Enum.uniq(profiles)) == 1,
             "U11: producer origin keys changed across repetitions"

      IO.inspect(
        %{
          group: unquote(Integer.to_string(div(ordinal, 5))),
          path: unquote(name),
          seconds: (System.monotonic_time(:millisecond) - started) / 1000
        },
        label: "U9_PATH_SECONDS"
      )
    end
  end
end
