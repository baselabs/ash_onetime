defmodule AshOnetime.Test.ExitBoundary.ConnectionDecoders do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Wire

  # Decoder buffers are copies of one physical connection's unconsumed bytes.
  # Their source is the native receive ledger and the pre-observation snapshot,
  # never the buffer or decoded result currently being checked. This ledger
  # grants no observation exemption.
  def build(indexed, native, streams, historical) do
    replies = Map.new(native.reads ++ native.active, &{&1.returned.index, &1})

    initial = %{
      ports: %{},
      cursors: historical_cursors(historical),
      descriptors: historical_descriptors(historical),
      executing: %{},
      instances: [],
      replays: [],
      replay_sends: MapSet.new(),
      replay_receives: MapSet.new(),
      errors: [],
      events: indexed.events,
      pairs: native.pairs,
      streams: streams.connections
    }

    state = Enum.reduce(indexed.events, initial, &event(&1, &2, replies))
    %{
      instances: Enum.reverse(state.instances),
      replays: Enum.reverse(state.replays),
      errors: Enum.reverse(state.errors)
    }
  end

  defp historical_descriptors(historical) do
    for {_holder, %{protocol: %{sock: {:gen_tcp, port}} = protocol} = history} <- historical,
        origin <- Map.get(history, :descriptors, []),
        origin.port == port and origin.query.types === protocol.types,
        into: %{},
        do: {origin.query.ref, origin}
  end

  defp historical_cursors(historical) do
    for {holder, %{protocol: %{sock: {:gen_tcp, port}} = protocol}} <- historical,
        into: %{} do
      buffer = if is_binary(protocol.buffer), do: protocol.buffer, else: <<>>
      source = %{index: {:historical, holder}, path: [:protocol, :buffer], offset: 0}
      copies = [Map.put(source, :length, byte_size(buffer))]

      span = %{
        index: source.index,
        offset: 0,
        source_offset: 0,
        copies: copies,
        length: byte_size(buffer)
      }

      spans = if buffer == <<>>, do: [], else: [span]
      {port, %{buffer: buffer, offset: 0, rows: [], types: protocol.types, spans: spans}}
    end
  end

  defp event(e, state, replies) do
    state =
      case Map.fetch(replies, e.index) do
        {:ok, %{bytes: bytes, port: port, copies: copies}} when is_binary(bytes) ->
          receive_bytes(state, e, port, bytes, copies)

        _ ->
          state
      end

    decoder_event(e, state)
  end

  defp receive_bytes(state, source, port, bytes, copies) do
    case Map.fetch(state.cursors, port) do
      {:ok, cursor} ->
        span = %{
          index: source.index,
          offset: cursor.offset + byte_size(cursor.buffer),
          source_offset: 0,
          copies: copies,
          length: byte_size(bytes)
        }

        cursor = %{cursor | buffer: cursor.buffer <> bytes, spans: cursor.spans ++ [span]}
        put_in(state.cursors[port], cursor)

      :error ->
        failure(state, source, :decoder_history, false)
    end
  end

  defp decoder_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, :handle_prepare, 3},
              {:ok, %Postgrex.Query{} = query, %{sock: {:gen_tcp, port}}}}
         } = e,
         state
       ) do
    origin = %{query: query, port: port, index: e.index, path: [3, 1]}
    put_in(state.descriptors[query.ref], origin)
  end

  defp decoder_event(
         %{event: {pid, :call, {Postgrex.Protocol, function, args}}} = e,
         state
       )
       when function in [:msg_recv, :rows_recv, :handle_prepare, :handle_execute] do
    protocol = List.last(args)
    protocol = if function in [:msg_recv, :rows_recv], do: hd(args), else: protocol

    case protocol do
      %{sock: {:gen_tcp, port}} ->
        state = put_in(state.ports[pid], port)

        state =
          if function == :handle_execute and Map.has_key?(state.cursors, port),
            do: put_in(state.cursors[port].rows, []),
            else: state

        state =
          if function == :handle_execute,
            do: executing(state, e, port, hd(args)),
            else: state

        if Map.has_key?(state.cursors, port),
          do: state,
          else: failure(state, e, :decoder_history, false)

      _ ->
        failure(state, e, :decoder_transport, false)
    end
  end

  defp decoder_event(
         %{event: {_, :call, {Postgrex.Protocol, :msg_decode, [buffer]}}} = e,
         state
       ),
       do: decode(e, buffer, :message, state)

  defp decoder_event(
         %{
           event:
             {_, :call,
              {Postgrex.Protocol, :activate, [%{sock: {:gen_tcp, port}} = protocol, buffer]}}
         } = e,
         state
       )
       when is_binary(buffer) do
    with {:ok, cursor} <- Map.fetch(state.cursors, port) do
      state = exact(state, e, :decoder_replay_buffer, buffer, cursor.buffer)

      if buffer == <<>>,
        do: state,
        else: replay(e, protocol, buffer, port, cursor, state)
    else
      _ -> failure(state, e, :decoder_replay_origin, false)
    end
  end

  defp decoder_event(%{event: {pid, :send, {:tcp, _port, _bytes}, pid}} = e, state) do
    bound? = MapSet.member?(state.replay_sends, e.index)
    if bound?, do: state, else: failure(state, e, :decoder_replay_source, false)
  end

  defp decoder_event(
         %{event: {_, :call, {Postgrex.Types, :decode_rows, args}}} = e,
         state
       ) do
    [buffer, types, rows, type_state] = args
    decode(e, buffer, {:rows, types, rows, type_state}, state)
  end

  defp decoder_event(_event, state), do: state

  defp replay(e, protocol, buffer, port, cursor, state) do
    pair = Map.fetch!(state.pairs, e.index)
    pid = e.pid
    message = {:tcp, port, buffer}

    program =
      Enum.filter(state.events, fn event ->
        event.pid == pid and event.index >= e.index and event.index <= pair.returned.index
      end)

    expected = [
      e.event,
      {pid, :call, {:erlang, :send, [pid, message]}},
      {pid, :send, message, pid},
      {pid, :return_from, {:erlang, :send, 2}, message},
      {pid, :return_from, {Postgrex.Protocol, :activate, 2}, {:ok, protocol}}
    ]

    state = exact(state, e, :decoder_replay_program, Enum.map(program, & &1.event), expected)

    received =
      Enum.find(state.events, fn event ->
        event.index > pair.returned.index and event.event === {pid, :receive, message} and
          not MapSet.member?(state.replay_receives, event.index)
      end)

    case {program, received} do
      {[_source, call, sent, returned, _stop], %{index: index}} ->
        record_replay(e, pair, cursor, buffer, [call, sent, returned], received, index, state)

      _ ->
        failure(state, e, :decoder_replay_copy, false)
    end
  end

  defp record_replay(e, pair, cursor, buffer, [call, sent, returned], received, index, state) do
    size = byte_size(buffer)

    copies = [
      %{index: e.index, path: [2, 2, 1], offset: 0, length: size},
      %{index: call.index, path: [2, 2, 1, 2], offset: 0, length: size},
      %{index: sent.index, path: [2, 2], offset: 0, length: size},
      %{index: returned.index, path: [3, 2], offset: 0, length: size},
      %{index: received.index, path: [2, 2], offset: 0, length: size}
    ]

    replay = %{
      source: e,
      returned: pair.returned,
      received: received,
      start: cursor.offset,
      input: buffer,
      copies: copies,
      provenance: Wire.spans(cursor.spans, cursor.offset, cursor.offset + size)
    }

    state
    |> Map.update!(:replays, &[replay | &1])
    |> Map.update!(:replay_sends, &MapSet.put(&1, sent.index))
    |> Map.update!(:replay_receives, &MapSet.put(&1, index))
  end

  defp executing(state, e, port, %Postgrex.Query{} = query) do
    case Map.fetch(state.descriptors, query.ref) do
      {:ok, %{port: ^port} = origin} ->
        state = exact(state, e, :decoder_query_copy, query, origin.query)
        put_in(state.executing[port], origin)

      _ ->
        failure(state, e, :decoder_query_origin, false)
    end
  end

  defp executing(state, _e, _port, _query), do: state

  defp decode(e, buffer, kind, state) do
    with {:ok, port} <- Map.fetch(state.ports, e.pid),
         {:ok, cursor} <- Map.fetch(state.cursors, port),
         {:ok, pair} <- Map.fetch(state.pairs, e.index) do
      state = exact(state, e, :decoder_buffer, buffer, cursor.buffer)
      validate_result(pair, port, cursor, kind, state)
    else
      _ -> failure(state, e, :decoder_origin, false)
    end
  rescue
    _error in [ArgumentError, MatchError, KeyError, FunctionClauseError] ->
      failure(state, e, :decoder_protocol, false)
  end

  defp validate_result(pair, port, cursor, :message, state) do
    {expected, consumed} = message_result(cursor.buffer)
    state = exact(state, pair.source, :decoder_result, returned(pair), expected)
    retain(state, pair, port, cursor, consumed, cursor.rows, expected)
  end

  defp validate_result(pair, port, cursor, {:rows, types, rows, type_state}, state) do
    context = row_context(state.streams[port].protocol.messages, cursor.offset)
    origin = Map.fetch!(state.executing, port)
    query = origin.query
    state = query_metadata(state, pair.source, query, context, cursor.types)
    expected_types = query.result_types
    state = exact(state, pair.source, :decoder_types, types, expected_types)
    state = exact(state, pair.source, :decoder_type_state, type_state, cursor.types)
    state = exact(state, pair.source, :decoder_rows, rows, cursor.rows)

    expected =
      Postgrex.Types.decode_rows(cursor.buffer, expected_types, cursor.rows, cursor.types)

    state = exact(state, pair.source, :decoder_result, returned(pair), expected)
    {rest, rows} = row_result(expected)
    consumed = byte_size(cursor.buffer) - byte_size(IO.iodata_to_binary(rest))
    state = retain(state, pair, port, cursor, consumed, rows, expected)
    [instance | rest] = state.instances

    %{
      state
      | instances: [Map.put(instance, :descriptor, Map.take(origin, [:index, :path])) | rest]
    }
  end

  defp message_result(<<tag, size::signed-32, bytes::binary>> = buffer)
       when size >= 4 and byte_size(bytes) >= size - 4 do
    length = size - 4
    <<payload::binary-size(^length), rest::binary>> = bytes
    message = Postgrex.Messages.parse(payload, tag, length)
    {{:ok, message, rest}, byte_size(buffer) - byte_size(rest)}
  end

  defp message_result(buffer) do
    {{:more, Wire.frame_remaining(buffer)}, 0}
  end

  defp row_context(messages, offset) do
    %{context: context} =
      Enum.find(messages, &(&1.direction == :backend and &1.start >= offset))

    context
  end

  # Postgrex owns the decoder types, including modifiers and composite types.
  # Keep its prepared Query return as the origin; opaque values are only copied
  # and passed back to their owner. The independent wire catalog checks the
  # descriptor's statement, OIDs, column names and execution formats.
  defp query_metadata(state, source, query, context, types) do
    names = for {name, _, _, _, _, _, _} <- context.columns, do: name
    oids = for {_, _, _, oid, _, _, _} <- context.columns, do: oid
    formats = for {_, _, _, _, _, _, format} <- context.columns, do: format
    encodings = Enum.map(formats, &if(&1 == 1, do: :binary, else: :text))

    state
    |> exact(source, :decoder_statement, IO.iodata_to_binary(query.statement), context.sql)
    |> exact(source, :decoder_columns, query.columns, names)
    |> exact(source, :decoder_oids, query.result_oids, oids)
    |> exact(source, :decoder_formats, query.result_formats, encodings)
    |> exact(source, :decoder_query_types, query.types, types)
  end

  defp row_result({:ok, rows, rest}), do: {rest, rows}
  defp row_result({:more, rest, rows, _required}), do: {rest, rows}

  defp retain(state, pair, port, cursor, consumed, rows, expected) do
    remaining = byte_size(cursor.buffer) - consumed
    rest = binary_part(cursor.buffer, consumed, remaining)
    provenance = Wire.spans(cursor.spans, cursor.offset, cursor.offset + byte_size(cursor.buffer))

    instance = %{
      port: port,
      source: pair.source,
      returned: pair.returned,
      start: cursor.offset,
      stop: cursor.offset + consumed,
      input: cursor.buffer,
      tail: rest,
      provenance: provenance,
      expected: expected,
      copies: buffer_copies(pair, consumed, remaining, expected)
    }

    offset = cursor.offset + consumed
    spans = Enum.filter(cursor.spans, &(&1.offset + &1.length > offset))
    cursor = %{cursor | offset: offset, buffer: rest, rows: rows, spans: spans}
    state = put_in(state.cursors[port], cursor)
    %{state | instances: [instance | state.instances]}
  end

  defp buffer_copies(pair, consumed, remaining, expected) do
    output =
      case expected do
        {:ok, _message, _rest} -> [3, 2]
        {:more, _required} -> nil
        {:more, _rest, _rows, _required} -> [3, 1]
      end

    input = %{index: pair.source.index, path: [2, 2, 0], offset: 0, length: consumed + remaining}
    copies = [input]

    if output,
      do: copies ++ [%{index: pair.returned.index, path: output, offset: 0, length: remaining}],
      else: copies
  end

  defp returned(%{returned: %{event: {_, :return_from, _, result}}}), do: result
  defp returned(_pair), do: :missing_decoder_return

  defp exact(state, _source, _rule, actual, expected) when actual === expected, do: state
  defp exact(state, source, rule, _actual, _expected), do: failure(state, source, rule, false)

  defp failure(state, source, rule, actual) do
    error = %{
      index: source.index,
      at: Map.take(source, [:mfa, :role, :stack]),
      rule: rule,
      actual: actual,
      expected: true
    }

    %{state | errors: [error | state.errors]}
  end
end
