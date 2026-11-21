defmodule AshOnetime.Test.ExitBoundary.ConnectionStates do
  @moduledoc false
  import Postgrex.Messages,
    only: [msg_ready: 1, msg_parameter: 1, msg_notice: 1, msg_notify: 1]

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
  @constructors [
    :parse_describe_flush,
    :close_parse_describe_flush,
    :recv_ready,
    :recv_strict_ready,
    :done,
    :handle_msg,
    :activate,
    :recv_buffer,
    :ping_recv
  ]
  @scopes [
    :handle_prepare_execute,
    :recv_transaction,
    :error_ready,
    :error_flushed,
    :rollback_flushed,
    :reload_flushed
  ]
  @copies [:msg_send, :msg_recv, :rows_recv, :redescribe]
  @owners @callbacks ++ @constructors ++ @scopes ++ @copies
  @last_state @callbacks ++ [:handle_prepare_execute]

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
      described: %{},
      versions: Map.values(holders),
      copies: [],
      errors: [],
      pairs: native.pairs,
      returns: Map.new(native.pairs, fn {_index, pair} -> {pair.returned.index, pair} end),
      decoders: decoders,
      native: native
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
       when function in @owners do
    argument = if function in @last_state, do: length(arguments) - 1, else: 0
    protocol = Enum.at(arguments, argument)
    frames = Map.get(state.frames, pid, [])

    case input_version(protocol, frames, Map.get(state.lookups, pid), state.ports) do
      {:ok, expected} ->
        {state, protocol_input} =
          input_protocol(state, source, expected.protocol, function, arguments)

        expected = %{expected | protocol: protocol_input}

        state = exact(state, source, :state_input_copy, protocol, expected.protocol)

        frame = %{
          source: source,
          input: protocol,
          owner: expected,
          current: protocol,
          parsed?: false
        }

        state
        |> copy(source, [2, 2, argument], expected)
        |> put_in([:frames, pid], [frame | frames])

      :error ->
        failure(state, source, :state_input_origin)
    end
  end

  defp callback_event(
         %{event: {pid, tag, {Postgrex.Protocol, function, _}, result}} = source,
         state
       )
       when function in @owners and tag in [:return_from, :exception_from] do
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

  defp returned(state, source, frame, result, rest) do
    function = elem(source.mfa, 1)
    state = described(state, source, frame, result)

    case returned_protocol(function, result) do
      {:ok, protocol, path} ->
        {state, expected} = output_protocol(state, source, frame, function, result)
        state = exact(state, source, :state_output_copy, protocol, expected)
        version = %{frame.owner | origin: {source.index, path}, protocol: protocol}
        state = %{state | versions: [version | state.versions]}
        state = copy(state, source, path, version)

        case rest do
          [] ->
            state
            |> put_in([:ports, protocol.sock], version)
            |> put_in([:completed, source.pid], version)

          [parent | outer] ->
            if function in @copies do
              state
            else
              parsed? = function in [:parse_describe_flush, :close_parse_describe_flush]

              parent = %{
                parent
                | current: protocol,
                  owner: version,
                  parsed?: parent.parsed? or parsed?
              }

              put_in(state.frames[source.pid], [parent | outer])
            end
        end

      nil ->
        state
    end
  end

  defp returned_protocol(:handle_msg, %Postgrex.Protocol{} = protocol),
    do: {:ok, protocol, [3]}

  defp returned_protocol(:redescribe, {_, _, %Postgrex.Protocol{} = protocol, _}),
    do: {:ok, protocol, [3, 2]}

  defp returned_protocol(_function, result) when is_tuple(result) and tuple_size(result) > 0 do
    position = tuple_size(result) - 1

    case elem(result, position) do
      %Postgrex.Protocol{} = protocol -> {:ok, protocol, [3, position]}
      _ -> nil
    end
  end

  defp returned_protocol(_function, _result), do: nil

  defp input_protocol(state, source, protocol, :msg_send, _arguments) do
    preserve? =
      Enum.any?(source.stack, fn
        {Postgrex.Protocol, function, _} ->
          function in [:error_flushed, :rollback_flushed, :reload_flushed]

        _ ->
          false
      end)

    expected = if preserve?, do: protocol, else: %{protocol | buffer: nil}
    {state, expected}
  end

  defp input_protocol(state, source, protocol, :done, arguments) when length(arguments) == 2,
    do: ready_protocol(state, source, protocol)

  defp input_protocol(state, _source, protocol, :ping_recv, _arguments),
    do: {state, %{protocol | buffer: nil}}

  defp input_protocol(state, source, protocol, :activate, _arguments) do
    if {Postgrex.Protocol, :ping_recv, 4} in source.stack do
      {state, expected} = ready_protocol(state, source, protocol)
      {state, %{expected | buffer: protocol.buffer}}
    else
      {state, protocol}
    end
  end

  defp input_protocol(state, _source, protocol, _function, _arguments), do: {state, protocol}

  defp output_protocol(state, source, frame, function, result)
       when function in [:parse_describe_flush, :close_parse_describe_flush] do
    case result do
      {:ok, query, _protocol} ->
        case query_origin(state, frame) do
          %Postgrex.Query{} = expected_query ->
            state = exact(state, source, :state_query_copy, query, expected_query)
            protocol = %{frame.current | postgres: {frame.current.postgres, expected_query.ref}}
            {state, %{protocol | buffer: cursor_buffer(state, source, frame)}}

          nil ->
            {failure(state, source, :state_query_origin), frame.current}
        end

      _ ->
        {state, frame.current}
    end
  end

  defp output_protocol(state, source, frame, function, _result)
       when function in [:recv_ready, :recv_strict_ready] do
    ready_protocol(state, source, frame.current)
  end

  defp output_protocol(state, _source, frame, :done, _result),
    do: {state, %{frame.input | messages: []}}

  defp output_protocol(state, source, frame, :handle_msg, _result) do
    {_, :call, {_, _, [_protocol, _status, message]}} = frame.source.event

    state =
      exact(
        state,
        source,
        :state_message_copy,
        message,
        native_message(state, source, frame.input)
      )

    expected =
      case message do
        msg_parameter(name: name, value: value) when is_map(frame.input.parameters) ->
          %{frame.input | parameters: Map.put(frame.input.parameters, name, value)}

        msg_parameter(name: _name, value: _value) ->
          frame.input

        msg_notice(fields: fields) ->
          %{frame.input | messages: [fields | frame.input.messages]}

        msg_notify(channel: _channel, payload: _payload) ->
          frame.input
      end

    {state, expected}
  end

  defp output_protocol(state, _source, frame, :activate, _result) do
    {_, :call, {_, _, [_protocol, buffer]}} = frame.source.event
    expected = if buffer == <<>>, do: %{frame.input | buffer: :active_once}, else: frame.input
    {state, expected}
  end

  defp output_protocol(state, source, frame, :recv_buffer, _result) do
    deliveries = state.native.active ++ state.decoders.replays

    received =
      Enum.filter(deliveries, fn delivery ->
        event = Map.get(delivery, :received, Map.get(delivery, :returned))

        event.pid == source.pid and event.index > frame.source.index and
          event.index < source.index
      end)

    case received do
      [] ->
        {state, %{frame.input | buffer: <<>>}}

      [delivery] ->
        bytes = Map.get(delivery, :bytes, Map.get(delivery, :input))
        {state, %{frame.input | buffer: bytes}}

      _ ->
        {failure(state, source, :state_buffer_delivery), frame.input}
    end
  end

  defp output_protocol(state, source, frame, :ping_recv, _result) do
    {_, :call, {_, _, [_protocol, _status, old_buffer, _buffer]}} = frame.source.event

    if is_nil(old_buffer),
      do: ready_protocol(state, source, frame.current),
      else: {state, frame.current}
  end

  defp output_protocol(state, _source, frame, :redescribe, _result), do: {state, frame.input}

  defp output_protocol(state, _source, frame, :handle_prepare, _result) do
    {_, :call, {_, _, [query, _opts, _protocol]}} = frame.source.event

    expected =
      if frame.parsed? and query.name != "" and not is_nil(frame.input.queries),
        do: %{frame.current | messages: []},
        else: frame.current

    {state, expected}
  end

  defp output_protocol(state, _source, frame, _function, _result), do: {state, frame.current}

  defp described(state, source, frame, {:ok, %Postgrex.Query{} = query, _protocol, _buffer}) do
    if source.mfa == {Postgrex.Protocol, :redescribe, 6},
      do: put_in(state.described[frame.input.sock], %{query: query, index: source.index}),
      else: state
  end

  defp described(state, _source, _frame, _result), do: state

  defp query_origin(state, frame) do
    case Map.get(state.described, frame.input.sock) do
      %{index: index, query: query} when index > frame.source.index ->
        query

      _ ->
        {_, :call, {_, _, [_protocol, _status, query, _comment]}} = frame.source.event

        if is_reference(query.ref) and query.types === frame.input.types,
          do: query
    end
  end

  defp ready_protocol(state, source, protocol) do
    case native_message(state, source, protocol) do
      msg_ready(status: status) ->
        expected = %{
          protocol
          | postgres: status,
            buffer: cursor_buffer(state, source, %{input: protocol})
        }

        {state, expected}

      _ ->
        {failure(state, source, :state_ready_origin), protocol}
    end
  end

  defp native_message(state, source, protocol) do
    state.decoders.instances
    |> Enum.filter(
      &({:gen_tcp, &1.port} == protocol.sock and &1.returned.pid == source.pid and
          &1.returned.index < source.index)
    )
    |> List.last()
    |> case do
      %{expected: {:ok, message, _rest}} -> message
      _ -> :no_native_message
    end
  end

  defp cursor_buffer(state, source, %{input: %{sock: {:gen_tcp, port}}} = frame) do
    state.decoders.timeline
    |> Enum.filter(&(&1.port == port and &1.index < source.index))
    |> List.last()
    |> case do
      %{cursor: cursor} -> cursor.buffer
      nil -> frame.input.buffer
    end
  end

  defp cursor_buffer(_state, _source, frame), do: frame.input.buffer

  defp pair_returned(state, source), do: Map.get(state.returns, source.index)

  defp copy(state, source, path, version) do
    copy = %{index: source.index, path: path, origin: version.origin}
    %{state | copies: [copy | state.copies]}
  end

  defp exact(state, _source, _rule, actual, expected) when actual === expected, do: state

  defp exact(state, source, rule, actual, expected) do
    state = failure(state, source, rule)

    fields =
      case {actual, expected} do
        {%Postgrex.Protocol{}, %Postgrex.Protocol{}} ->
          for {field, value} <- Map.from_struct(expected),
              Map.fetch!(actual, field) !== value,
              do: field

        _ ->
          []
      end

    [error | errors] = state.errors
    %{state | errors: [Map.put(error, :different_fields, fields) | errors]}
  end

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
