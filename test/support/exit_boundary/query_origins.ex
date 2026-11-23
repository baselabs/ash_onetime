defmodule AshOnetime.Test.ExitBoundary.QueryOrigins do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Diagnostics
  alias AshOnetime.Test.ExitBoundary.References

  def build(_indexed, side) do
    history = side.connection_history
    historical = history.indexed.query_cache

    ids =
      for {_, status, _, {id, query}} <- historical.rows,
          status in [:cache, :cached],
          into: %{},
          do: {statement(query), id}

    # The committed baseline can retain a successful insertion from the raw
    # prefix. Its own primitive generator remains authoritative after a cut;
    # the suffix's cross-side O1 inventory cannot recreate that occurrence.
    generated =
      for {_index, pair} <- history.native.pairs,
          %{pid: pid, mfa: {:erlang, :unique_integer, arity}} <- [pair.source],
          arity in [0, 1],
          {^pid, :return_from, {:erlang, :unique_integer, ^arity}, value} <-
            [pair.returned.event],
          is_integer(value),
          do: {pid, pair.returned.index, value}

    before = Map.get(side.historical, :event_offset, 0)

    cache_events =
      for {_index,
           %{
             source: %{event: {_, :call, {:ets, _, [table | _]}}} = source,
             returned: returned
           }} <- history.native.pairs,
          table == historical.table,
          index <- [source.index, returned.index],
          index >= before,
          into: MapSet.new(),
          do: index

    result =
      Enum.reduce(history.states.table_commits, %{ids: ids, errors: []}, fn commit, state ->
        promote_commit(commit, state, historical.table, history.native.pairs, generated)
      end)

    diagnose_missing_origins(result.errors, side, history)

    names =
      Map.new(result.ids, fn {sql, id} ->
        {sql, References.query_name(id, side.historical.repo_metadata)}
      end)

    result |> Map.put(:names, names) |> Map.put(:cache_events, cache_events)
  end

  defp promote_commit(%{table: table, origin: origin}, state, table, pairs, generated)
       when is_integer(origin) do
    source = Map.fetch!(pairs, origin).source

    case source.event do
      {_, :call, {:ets, :insert_new, [_, {_, :cache, _, {id, query}}]}} ->
        promote(state, source, id, query, generated)

      _ ->
        state
    end
  end

  defp promote_commit(_commit, state, _table, _pairs, _generated), do: state

  defp promote(state, source, id, query, generated) do
    own_origin? =
      Enum.any?(generated, fn {pid, index, value} ->
        pid == source.pid and index < source.index and value == id
      end)

    if own_origin?,
      do: %{state | ids: Map.put(state.ids, statement(query), id)},
      else: %{state | errors: [{source, id, :missing_unique_integer_origin} | state.errors]}
  end

  # Temporary continuation diagnostic: coordinates and ownership flags only.
  # Never expose the prepared query, generated integer or captured arguments.
  defp diagnose_missing_origins(errors, side, history) do
    before = Map.get(side.historical, :event_offset, 0)

    for {source, id, :missing_unique_integer_origin} <- errors do
      prefix_origin? =
        Enum.any?(history.program_events, fn
          %{event: {pid, :return_from, {:erlang, :unique_integer, _arity}, value}, index: index} ->
            pid == source.pid and value == id and index < source.index and index < before

          _ ->
            false
        end)

      Diagnostics.emit("CONNECTION_QUERY_ORIGIN_FAILURE", %{
        index: source.index,
        offset: before,
        insertion_in_prefix?: source.index < before,
        generator_in_prefix?: prefix_origin?
      })
    end
  end

  def expected_name(origins, query), do: Map.fetch(origins.names, statement(query))
  defp statement(%Postgrex.Query{statement: sql}), do: IO.iodata_to_binary(sql)
  defp statement(sql), do: IO.iodata_to_binary(sql)
end
