defmodule AshOnetime.Delivery.ComparatorMatrixTest do
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false
  alias AshOnetime.Test.Repo

  alias AshOnetime.Test.ExitBoundary.{
    Analysis,
    Comparator,
    Diagnostics,
    Origins,
    Scenarios,
    Search,
    Values
  }

  @tag :u3
  test "U3: finalize-to-replay follows a real seal on every route and tuple", context do
    Repo.put_dynamic_repo(context.repo)
    rows = Enum.filter(Scenarios.rows(), &(&1.branch == :finalize_replay))
    context = with_references(context, rows)

    outcomes =
      for row <- rows, {label, values} <- Values.set() do
        pair = Scenarios.observe(row, values, context)
        comparison = Comparator.compare(pair)

        locations =
          for error <- comparison.errors,
              uniq: true,
              do:
                {case error.at do
                   %{mfa: mfa} -> mfa
                   other -> other
                 end, error.rule,
                 Enum.map(error.path, fn n -> if is_integer(n), do: :element, else: n end)}

        {{row.action, label}, finalize_replay?(pair.run.run), locations}
      end

    failures = for {key, false, _} <- outcomes, do: key
    locations = outcomes |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()

    IO.puts(
      "U3_FINALIZE_REPLAY" <>
        ": " <> Diagnostics.render(%{pairs: length(rows) * 6, failures: failures}, pretty: true)
    )

    assert failures == []
    assert locations == [], "U3 comparison diverged at #{Diagnostics.render(locations)}"
  end

  defp finalize_replay?(run) do
    events = Enum.map(run.events, & &1.event)

    sealed =
      Enum.find_index(events, fn
        {_, :return_from, {AshOnetime.Delivery, :seal, 2}, :ok} -> true
        _ -> false
      end)

    replay =
      Enum.find_index(events, fn
        {_, :return_from, {AshOnetime.ExternalRecovery, :finalize, 6}, {:replay, _, _}} -> true
        _ -> false
      end)

    done =
      Enum.find_index(events, fn
        {_, :call, {:erlang, :put, [_, {:done, _, :replayed, nil, nil}]}} -> true
        _ -> false
      end)

    sealed != nil and replay != nil and done != nil and sealed < replay and replay < done and
      match?(
        {:ok, _, %AshOnetime.Delivery{outcome: :replayed, values: values}}
        when map_size(values) == 0,
        run.result
      )
  end

  @partition_file Path.expand("../../../.github/test-shards.json", __DIR__)
  @external_resource @partition_file
  @partitions @partition_file |> File.read!() |> Jason.decode!() |> Map.fetch!("matrix_routes")

  for partition <- @partitions do
    action = String.to_atom(partition["action"])
    labels = Enum.map(partition["values"], &String.to_atom/1)
    path_indices = partition["path_indices"]
    @tag :full_matrix
    @tag matrix_route: partition["name"]
    test "C-pos: #{partition["name"]}, every path and declared structured tuple", context do
      Repo.put_dynamic_repo(context.repo)
      labels = unquote(Macro.escape(labels))
      values = Keyword.take(Values.set(), labels)
      rows = Enum.filter(Scenarios.rows(), &(&1.action == unquote(action)))

      expected_rows =
        if String.starts_with?(Atom.to_string(unquote(action)), "external_"), do: 18, else: 17

      assert length(rows) == expected_rows
      assert Keyword.keys(values) == labels
      assert length(Enum.uniq_by(rows, &{&1.branch, &1.fault})) == expected_rows
      path_indices = unquote(Macro.escape(path_indices))
      assert Enum.uniq(path_indices) == path_indices
      assert Enum.all?(path_indices, &(&1 in 0..(expected_rows - 1)))
      rows = Enum.map(path_indices, &Enum.fetch!(rows, &1))

      IO.puts(
        "C_POS_FLIPPED_BITS" <> ": " <> Diagnostics.render(Values.flipped_bits(), pretty: true)
      )

      context = with_references(context, rows)

      {residuals, counts} =
        Enum.reduce(rows, {%{}, %{pairs: 0, events: 0}}, fn row, acc ->
          IO.puts(
            "C_POS_ROW" <>
              ": " <> Diagnostics.render({row.action, row.branch, row.fault}, pretty: true)
          )

          Enum.reduce(values, acc, fn {label, tuple}, {all, counts} ->
            result =
              try do
                pair = Scenarios.observe(row, tuple, context)
                comparison = Comparator.compare(pair)

                %{
                  comparison
                  | errors: comparison.errors ++ rule3_errors(pair.run) ++ rule3_errors(pair.twin)
                }
              rescue
                error ->
                  %{
                    events: {0, 0},
                    errors: [
                      %{
                        at: :comparator,
                        rule: :unhandled_capture,
                        path: [],
                        run: {error.__struct__, error, __STACKTRACE__},
                        twin: :completed_comparison
                      }
                    ]
                  }
              catch
                kind, reason ->
                  %{
                    events: {0, 0},
                    errors: [
                      %{
                        at: :comparator,
                        rule: :unhandled_capture,
                        path: [],
                        run: {kind, reason, __STACKTRACE__},
                        twin: :completed_comparison
                      }
                    ]
                  }
              end

            all =
              Enum.reduce(result.errors, all, fn difference, found ->
                log_difference(row, label, difference)

                at =
                  case difference.at do
                    %{mfa: mfa} -> mfa
                    other -> other
                  end

                key =
                  {at, difference.rule,
                   Enum.map(difference.path, fn n -> if is_integer(n), do: :element, else: n end)}

                case Map.fetch(found, key) do
                  {:ok, old} ->
                    Map.put(found, key, %{old | count: old.count + 1})

                  :error ->
                    Map.put(found, key, %{
                      count: 1,
                      tuple: label,
                      row: row,
                      source: Diagnostics.location(difference),
                      sample: Diagnostics.safe(difference)
                    })
                end
              end)

            {a, b} = result.events
            counts = %{pairs: counts.pairs + 1, events: counts.events + a + b}
            {all, counts}
          end)
        end)

      IO.puts("C_POS_COUNTS" <> ": " <> Diagnostics.render(counts, pretty: true))
      assert counts.pairs == length(path_indices) * length(labels)

      for {key, sample} <- Enum.sort(residuals),
          do:
            IO.puts(
              "C_POS_RESIDUAL" <>
                ": " <>
                Diagnostics.render({key, sample},
                  pretty: true,
                  limit: :infinity,
                  printable_limit: :infinity
                )
            )

      assert residuals == %{},
             "C-pos residuals: #{map_size(residuals)} qualified locations (the whole matrix ran)"
    end
  end

  defp log_difference(row, tuple, difference) do
    IO.puts(
      "C_POS_RESIDUAL_OCCURRENCE: " <>
        Diagnostics.render(
          %{
            row: row,
            tuple: tuple,
            source: Diagnostics.location(difference),
            difference: Diagnostics.safe(difference)
          },
          pretty: true,
          limit: :infinity,
          printable_limit: :infinity
        )
    )
  end

  defp rule3_errors(side) do
    prior = if side.prior, do: rule3_errors(side.prior), else: []

    coverage =
      for descriptor <- Analysis.unclaimed(side.run.events),
          do: %{
            at: :capture,
            rule: :unclaimed_exit,
            path: [],
            run: descriptor,
            twin: :classified_exit
          }

    found = Search.hits(side)
    indexed = if found == [], do: [], else: Origins.build(side).events

    hits =
      for {class, mfa, index} <- found do
        event = Enum.fetch!(indexed, index)

        %{
          at: %{mfa: mfa, role: event.role, run_index: index, stack: event.stack},
          rule: :raw_canary_exit,
          path: [],
          run: class,
          twin: :no_raw_canary
        }
      end

    prior ++ coverage ++ hits
  end
end
