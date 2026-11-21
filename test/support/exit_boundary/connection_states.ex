defmodule AshOnetime.Test.ExitBoundary.ConnectionStates do
  @moduledoc false

  @callbacks [
    :handle_prepare,
    :handle_execute,
    :handle_close,
    :handle_declare,
    :handle_fetch,
    :handle_deallocate,
    :handle_begin,
    :handle_commit,
    :handle_rollback,
    :handle_status,
    :handle_info,
    :checkin,
    :checkout,
    :ping
  ]

  # An owner version is a native return, or the pre-observation holder state.
  # Copies must bind to that version before a buffer can leave exact comparison.
  # This ledger grants no event allowance or projection.
  def build(indexed, native, decoders, historical) do
    holders =
      for {holder, %{protocol: protocol}} <- historical, into: %{} do
        {holder, %{origin: {:historical, holder}, protocol: protocol, holder: holder}}
      end

    ports = for {_holder, version} <- holders, into: %{}, do: {version.protocol.sock, version}

    initial = %{
      holders: holders,
      ports: ports,
      lookups: %{},
      completed: %{},
      frames: %{},
      pending: %{},
      versions: Map.values(holders),
      copies: [],
      errors: [],
      pairs: native.pairs,
      returns: Map.new(native.pairs, fn {_index, pair} -> {pair.returned.index, pair} end),
      decoders: decoders
    }

    state = Enum.reduce(indexed.events, initial, &event/2)

    %{
      versions: Enum.reverse(state.versions),
      copies: Enum.reverse(state.copies),
      errors: Enum.reverse(state.errors)
    }
  end

  defp event(source, state) do
    state = commit(source, state)
    state = holder_event(source, state)
    callback_event(source, state)
  end

  defp holder_event(
         %{event: {pid, :return_from, {:ets, :lookup, 2}, [row]}} = source,
         state
       )
       when is_tuple(row) and tuple_size(row) == 8 do
    with {:conn, _owner, Postgrex.Protocol, %Postgrex.Protocol{} = protocol, _, _, _, _} <- row,
         %{source: %{event: {^pid, :call, {:ets, :lookup, [holder, :conn]}}}} <-
           pair_returned(state, source),
         {:ok, version} <- Map.fetch(state.holders, holder) do
      state = exact(state, source, :state_holder_lookup, protocol, version.protocol)
      lookup = %{version | origin: {source.index, [3, 0, 3]}}

      state
      |> put_in([:lookups, pid], lookup)
      |> copy(source, [3, 0, 3], version)
    else
      _ -> state
    end
  end

  defp holder_event(
         %{event: {pid, :return_from, {DBConnection.Holder, :checkout, _}, result}} = source,
         state
       ) do
    case {result, Map.get(state.lookups, pid), pair_returned(state, source)} do
      {{:ok, {:pool_ref, _, _, _, holder, _}, Postgrex.Protocol, _, protocol},
       %{holder: holder, origin: {lookup_index, _}} = version, %{source: call}}
      when lookup_index > call.index ->
        state
        |> exact(source, :state_checkout_copy, protocol, version.protocol)
        |> copy(source, [3, 4], version)

      _ ->
        state
    end
  end

  defp holder_event(
         %{event: {pid, :call, {:ets, :update_element, [holder, :conn, updates]}}} = source,
         state
       ) do
    if Map.has_key?(state.holders, holder) do
      listed? = is_list(updates)
      updates = if listed?, do: updates, else: [updates]

      Enum.reduce(Enum.with_index(updates), state, fn
        {{4, %Postgrex.Protocol{} = protocol}, ordinal}, state ->
          path =
            if listed?,
              do: [2, 2, 2, ordinal, 1],
              else: [2, 2, 2, 1]

          store(state, source, pid, holder, protocol, path)

        _, state ->
          state
      end)
    else
      state
    end
  end

  defp holder_event(_source, state), do: state

  defp store(state, source, pid, holder, protocol, path) do
    case {Map.get(state.completed, pid), Map.get(state.pairs, source.index)} do
      {%{holder: ^holder} = version,
       %{returned: %{index: index, event: {_, :return_from, _, true}}}} ->
        state
        |> exact(source, :state_holder_update, protocol, version.protocol)
        |> copy(source, path, version)
        |> put_in([:pending, index], version)

      _ ->
        failure(state, source, :state_holder_update_origin)
    end
  end

  defp commit(source, state) do
    case Map.pop(state.pending, source.index) do
      {nil, _} ->
        state

      {version, pending} ->
        %{state | pending: pending, holders: Map.put(state.holders, version.holder, version)}
    end
  end

  defp callback_event(
         %{event: {pid, :call, {Postgrex.Protocol, function, arguments}}} = source,
         state
       )
       when function in @callbacks do
    protocol = List.last(arguments)
    frames = Map.get(state.frames, pid, [])

    case input_version(protocol, frames, Map.get(state.lookups, pid), state.ports) do
      {:ok, expected} ->
        state = exact(state, source, :state_input_copy, protocol, expected.protocol)
        frame = %{source: source, input: protocol, owner: expected, current: protocol}

        state
        |> copy(source, [2, 2, length(arguments) - 1], expected)
        |> put_in([:frames, pid], [frame | frames])

      :error ->
        failure(state, source, :state_input_origin)
    end
  end

  defp callback_event(
         %{event: {pid, tag, {Postgrex.Protocol, function, _}, result}} = source,
         state
       )
       when function in @callbacks and tag in [:return_from, :exception_from] do
    case Map.get(state.frames, pid, []) do
      [%{source: %{mfa: mfa}} = frame | rest] when mfa == source.mfa ->
        state = put_in(state.frames[pid], rest)
        returned(state, source, frame, result, rest)

      _ ->
        failure(state, source, :state_return_origin)
    end
  end

  defp callback_event(_source, state), do: state

  defp input_version(_protocol, [frame | _], _lookup, _ports),
    do: {:ok, %{frame.owner | protocol: frame.current}}

  defp input_version(_protocol, [], lookup, _ports) when not is_nil(lookup), do: {:ok, lookup}

  defp input_version(%Postgrex.Protocol{sock: sock}, [], nil, ports), do: Map.fetch(ports, sock)
  defp input_version(_protocol, _frames, _lookup, _ports), do: :error

  defp returned(state, source, frame, result, rest) when is_tuple(result) do
    protocol = elem(result, tuple_size(result) - 1)

    if is_struct(protocol, Postgrex.Protocol) do
      state = output_buffer(state, source, frame, protocol)
      path = [3, tuple_size(result) - 1]
      version = %{frame.owner | origin: {source.index, path}, protocol: protocol}
      state = %{state | versions: [version | state.versions]}
      state = copy(state, source, path, version)

      case rest do
        [] ->
          state
          |> put_in([:ports, protocol.sock], version)
          |> put_in([:completed, source.pid], version)

        [parent | outer] ->
          put_in(state.frames[source.pid], [%{parent | current: protocol} | outer])
      end
    else
      state
    end
  end

  defp returned(state, _source, _frame, _result, _rest), do: state

  defp output_buffer(state, source, frame, %{sock: {:gen_tcp, port}} = protocol) do
    cursor =
      state.decoders.versions
      |> Enum.filter(&(&1.port == port and &1.index < source.index))
      |> List.last()

    expected = if cursor, do: cursor.cursor.buffer, else: frame.input.buffer

    expected =
      case {frame.source.mfa, frame.input.buffer} do
        {{Postgrex.Protocol, :checkin, 1}, <<>>} -> :active_once
        {{Postgrex.Protocol, :checkin, 1}, buffer} -> buffer
        _ -> expected
      end

    exact(state, source, :state_output_buffer, protocol.buffer, expected)
  end

  defp output_buffer(state, source, _frame, _protocol),
    do: failure(state, source, :state_transport_origin)

  defp pair_returned(state, source), do: Map.get(state.returns, source.index)

  defp copy(state, source, path, version) do
    copy = %{index: source.index, path: path, origin: version.origin}
    %{state | copies: [copy | state.copies]}
  end

  defp exact(state, _source, _rule, actual, expected) when actual === expected, do: state
  defp exact(state, source, rule, _actual, _expected), do: failure(state, source, rule)

  defp failure(state, source, rule) do
    error = %{
      index: source.index,
      at: Map.take(source, [:mfa, :role, :stack]),
      rule: rule,
      actual: false,
      expected: true
    }

    %{state | errors: [error | state.errors]}
  end
end
