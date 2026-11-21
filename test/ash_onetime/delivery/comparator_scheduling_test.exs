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
      row = unquote(Macro.escape(row))
      context = with_references(context, [row])
      values = Values.set()[:va]

      # The first real path prepares Ecto/Postgrex's query cache. U11 measures
      # repeated execution on that prepared substrate; each observation still
      # captures its actual historical cache and compares every generated origin.
      warm = Scenarios.observe(row, values, context)
      warm_result = Comparator.compare(warm)

      if first = List.first(warm_result.errors) do
        IO.inspect(
          %{path: unquote(name), first: AshOnetime.Test.ExitBoundary.Diagnostics.safe(first)},
          label: "U9_NATIVE_WARM_FIRST_DIVERGENCE",
          limit: :infinity
        )
      end

      assert warm_result.errors == [], "U9 path preparation must compare green"
      started = System.monotonic_time(:millisecond)

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

      expected = hd(profiles)

      if index = Enum.find_index(profiles, &(&1 != expected)) do
        actual = Enum.at(profiles, index)

        for side <- [:run, :twin] do
          before = MapSet.new(expected[side])
          after_keys = MapSet.new(actual[side])

          IO.inspect(
            %{
              path: unquote(name),
              repetition: index + 1,
              side: side,
              missing: MapSet.difference(before, after_keys) |> Enum.sort(),
              added: MapSet.difference(after_keys, before) |> Enum.sort()
            },
            label: "U11_ORIGIN_KEY_DIFF",
            limit: :infinity
          )
        end
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
