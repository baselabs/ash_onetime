defmodule AshOnetime.Test.ExitBoundary.QueryOrigins do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.References

  def build(indexed, side) do
    history = side.connection_history
    historical = history.indexed.query_cache

    ids =
      for {_, status, _, {id, query}} <- historical.rows,
          status in [:cache, :cached],
          into: %{},
          do: {statement(query), id}

    generated = for {_, %{value: value}} <- indexed.origins, is_integer(value), do: value

    cache_events =
      for {_index,
           %{
             source: %{event: {_, :call, {:ets, _, [table | _]}}} = source,
             returned: returned
           }} <- history.native.pairs,
          table == historical.table,
          index <- [source.index, returned.index],
          into: MapSet.new(),
          do: index

    result =
      Enum.reduce(history.states.table_commits, %{ids: ids, errors: []}, fn commit, state ->
        if commit.table == historical.table and is_integer(commit.origin) do
          source = Map.fetch!(history.native.pairs, commit.origin).source

          case source.event do
            {_, :call, {:ets, :insert_new, [_, {_, :cache, _, {id, query}}]}} ->
              if id in generated,
                do: %{state | ids: Map.put(state.ids, statement(query), id)},
                else: %{
                  state
                  | errors: [{source, id, :missing_unique_integer_origin} | state.errors]
                }

            _ ->
              state
          end
        else
          state
        end
      end)

    names =
      Map.new(result.ids, fn {sql, id} ->
        {sql, References.query_name(id, side.historical.repo_metadata)}
      end)

    result |> Map.put(:names, names) |> Map.put(:cache_events, cache_events)
  end

  def expected_name(origins, query), do: Map.fetch(origins.names, statement(query))
  defp statement(%Postgrex.Query{statement: sql}), do: IO.iodata_to_binary(sql)
  defp statement(sql), do: IO.iodata_to_binary(sql)
end
