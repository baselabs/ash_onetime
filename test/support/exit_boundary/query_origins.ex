defmodule AshOnetime.Test.ExitBoundary.QueryOrigins do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.References

  def build(indexed, side) do
    historical = side.historical.query_cache
    ids = for {_, _, _, {id, query}} <- historical.rows, into: %{}, do: {statement(query), id}
    generated = for {_, %{value: value}} <- indexed.origins, is_integer(value), do: value
    initial = %{ids: ids, cache_events: MapSet.new(), pending: %{}, errors: []}
    result = Enum.reduce(indexed.events, initial, fn e, state ->
      case e.event do
        {pid, :call, {:ets, function, [table | args]}} when table == historical.table ->
          state = %{state | cache_events: MapSet.put(state.cache_events, e.index),
            pending: Map.put(state.pending, {pid, e.mfa}, true)}
          case {function, args} do
            {:insert_new, [{_, :cache, _, {id, query}}]} ->
              if id in generated do
                %{state | ids: Map.put(state.ids, statement(query), id)}
              else
                %{state | errors: [{e, id, :missing_unique_integer_origin} | state.errors]}
              end
            _ -> state
          end
        {pid, tag, mfa, _} when tag in [:return_from, :exception_from] ->
          if Map.has_key?(state.pending, {pid, mfa}),
            do: %{state | cache_events: MapSet.put(state.cache_events, e.index), pending: Map.delete(state.pending, {pid, mfa})},
            else: state
        _ -> state
      end
    end)
    names = Map.new(result.ids, fn {sql, id} -> {sql, References.query_name(id, side.historical.repo_metadata)} end)
    Map.put(result, :names, names)
  end

  def expected_name(origins, query), do: Map.fetch(origins.names, statement(query))
  defp statement(%Postgrex.Query{statement: sql}), do: IO.iodata_to_binary(sql)
  defp statement(sql), do: IO.iodata_to_binary(sql)
end
