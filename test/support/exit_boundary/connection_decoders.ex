defmodule AshOnetime.Test.ExitBoundary.ConnectionDecoders do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Wire
  alias AshOnetime.Test.ExitBoundary.Compiled

  # Decoder buffers are copies of one physical connection's unconsumed bytes.
  # Their source is the native receive ledger and the pre-observation snapshot,
  # never the buffer or decoded result currently being checked. This ledger
  # grants no observation exemption.
  def build(indexed, native, streams, historical, origins \\ []) do
    replies = Map.new(native.reads ++ native.active, &{&1.returned.index, &1})

    initial = %{
      ports: %{},
      cursors: historical_cursors(historical),
      pending_cursors: %{},
      versions: [],
      timeline: [],
      descriptors: Map.merge(historical_descriptors(historical), owner_descriptors(origins)),
      executing: %{},
      executions: [],
      query_inputs: %{},
      query_outputs: %{},
      query_params: %{},
      # Bind the loaded code version while the native owner is still installed.
      # A mutation's teardown may restore the module before copy validation.
      factory_identities: %{
        notify: Compiled.identity(Postgrex.Protocol, :"-notify/1-fun-0-", 2)
      },
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
      versions: Enum.reverse(state.versions),
      timeline: Enum.reverse(state.timeline),
      executions: Enum.reverse(state.executions),
      query_inputs: state.query_inputs,
      query_outputs: state.query_outputs,
      factory_identities: state.factory_identities,
      protocol_copies: protocol_copies(indexed, historical),
      replays: Enum.reverse(state.replays),
      errors: Enum.reverse(state.errors)
    }
  end

  # A census of native coordinates, not a qualification or a projection. Each
  # Protocol occurrence needs its own version/origin rule before any buffer copy
  # can leave O5. Public SSL socket arguments/results remain opaque throughout.
  defp protocol_copies(indexed, historical) do
    sockets =
      for {_holder, %{protocol: %{sock: {:ssl, socket}}}} <- historical, do: socket

    opaque = MapSet.new(sockets ++ Enum.flat_map(indexed.events, &ssl_socket/1))

    for source <- indexed.events,
        {path, protocol} <- protocol_terms(source.event, [], opaque) do
      source
      |> Map.take([:index, :mfa, :role, :stack])
      |> Map.put(:tag, elem(source.event, 1))
      |> Map.put(:path, path)
      |> Map.put(:buffer_kind, buffer_kind(protocol.buffer))
    end
  end

  defp ssl_socket(%{event: {_, :call, {:ssl, function, [socket | _]}}})
       when function in [
              :send,
              :recv,
              :close,
              :sockname,
              :peername,
              :getopts,
              :setopts,
              :shutdown,
              :controlling_process,
              :connection_information,
              :peercert
            ],
       do: [socket]

  defp ssl_socket(%{event: {_, :return_from, {:ssl, function, _}, {:ok, socket}}})
       when function in [:connect, :transport_accept, :handshake],
       do: [socket]

  defp ssl_socket(_event), do: []

  defp protocol_terms(value, path, opaque) do
    if MapSet.size(opaque) == 0 or not MapSet.member?(opaque, value),
      do: protocol_term(value, path, opaque),
      else: []
  end

  defp protocol_term(%Postgrex.Protocol{} = protocol, path, _opaque), do: [{path, protocol}]

  defp protocol_term(value, path, opaque) when is_function(value) do
    {:env, environment} = Function.info(value, :env)
    protocol_terms(environment, path ++ [:function, :env], opaque)
  end

  defp protocol_term(value, path, opaque) when is_map(value) do
    Enum.flat_map(Map.to_list(value), fn {key, item} ->
      protocol_terms(key, path ++ [{:map_key, key}], opaque) ++
        protocol_terms(item, path ++ [key], opaque)
    end)
  end

  defp protocol_term(value, path, opaque) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> protocol_terms(item, path ++ [index], opaque) end)
  end

  defp protocol_term([_head | _tail] = list, path, opaque),
    do: protocol_list(list, path, opaque, 0)

  defp protocol_term(_value, _path, _opaque), do: []

  defp protocol_list([head | tail], path, opaque, index),
    do:
      protocol_terms(head, path ++ [index], opaque) ++
        protocol_list(tail, path, opaque, index + 1)

  defp protocol_list([], _path, _opaque, _index), do: []

  defp protocol_list(tail, path, opaque, index),
    do: protocol_terms(tail, path ++ [{:improper_tail, index}], opaque)

  defp buffer_kind(buffer) when is_binary(buffer), do: :bytes
  defp buffer_kind(buffer) when buffer in [nil, :active_once], do: buffer
  defp buffer_kind(_buffer), do: :invalid

  defp owner_descriptors(origins) do
    for %{sock: {:gen_tcp, port}, query: query} = origin <- origins,
        into: %{},
        do: {query.ref, Map.put(origin, :port, port)}
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
    state = commit_cursor(e, state)

    state =
      case Map.fetch(replies, e.index) do
        {:ok, %{bytes: bytes, port: port, copies: copies}} when is_binary(bytes) ->
          receive_bytes(state, e, port, bytes, copies)

        _ ->
          state
      end

    state = query_event(e, state)
    decoder_event(e, state)
  end

  defp query_event(
         %{event: {_, :call, {Postgrex.Protocol, function, _arguments}}} = source,
         state
       )
       when function in [
              :describe,
              :describe_params,
              :describe_result,
              :redescribe,
              :recv_describe,
              :columns
            ] do
    case query_root(state, source) do
      %{query: query, protocol: protocol} = root ->
        port = elem(protocol.sock, 1)
        description = query_description(state, source, root, port)
        query = Map.get(state.query_params, root.index, query)

        input =
          Map.merge(description, %{
            query: query,
            types: protocol.types,
            root: root.index,
            pid: source.pid
          })

        put_in(state.query_inputs[source.index], input)

      nil ->
        failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, :recv_describe, _}, {:ok, _, _, _, _, _, _}}
         } = source,
         state
       ) do
    case query_root(state, source) do
      %{query: query, protocol: protocol} = root ->
        input = query_description(state, source, root, elem(protocol.sock, 1))

        input =
          Map.merge(input, %{
            query: query,
            types: protocol.types,
            root: root.index,
            pid: source.pid
          })

        put_in(state.query_inputs[source.index], input)

      nil ->
        failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(
         %{event: {_, :return_from, {Postgrex.Protocol, function, _}, {:ok, actual}}} = source,
         state
       )
       when function in [:describe_params, :describe_result] do
    with %{source: call} <- returned_pair(state, source),
         {:ok, input} <- Map.fetch(state.query_inputs, call.index),
         {:ok, expected} <- query_factory(state, source, call, input, function) do
      _ = actual

      state =
        put_in(state.query_outputs[source.index], %{
          query: expected,
          origin: {call.index, input.origin},
          pid: source.pid
        })

      if function == :describe_params,
        do: put_in(state.query_params[input.root], expected),
        else: state
    else
      _ -> failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, function, _},
              {:ok, %Postgrex.Query{}, _protocol, _buffer}}
         } = source,
         state
       )
       when function in [:describe, :redescribe] do
    with %{source: call} <- returned_pair(state, source),
         %{query: query, origin: origin} <- earlier_query_factory(state, source, call.index) do
      put_in(state.query_outputs[source.index], %{query: query, origin: origin, pid: source.pid})
    else
      _ -> failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(_source, state), do: state

  defp returned_pair(state, source) do
    state.pairs
    |> Map.values()
    |> Enum.find(&(&1.returned.index == source.index))
  end

  defp query_root(state, source) do
    state.pairs
    |> Map.values()
    |> Enum.filter(fn pair ->
      pair.source.pid == source.pid and pair.source.index < source.index and
        pair.returned.index > source.index and
        pair.source.mfa in [
          {Postgrex.Protocol, :handle_prepare, 3},
          {Postgrex.Protocol, :handle_execute, 4}
        ]
    end)
    |> Enum.max_by(& &1.source.index, fn -> nil end)
    |> case do
      %{
        source: %{
          index: index,
          event: {_, :call, {_, _, [%Postgrex.Query{} = query | arguments]}}
        }
      } ->
        %{query: query, protocol: List.last(arguments), index: index}

      _ ->
        nil
    end
  end

  defp query_description(state, source, root, port) do
    messages =
      state.instances
      |> Enum.filter(
        &(&1.port == port and &1.source.pid == source.pid and
            &1.source.index > root.index and &1.returned.index < source.index)
      )

    description =
      Enum.find(
        messages,
        &(match?({:ok, {:msg_row_desc, _}, _}, &1.expected) or
            match?({:ok, {:msg_no_data}, _}, &1.expected))
      )

    parameters = Enum.find(messages, &match?({:ok, {:msg_parameter_desc, _}, _}, &1.expected))

    {oids, mods, columns, fields, origin} =
      case description do
        %{expected: {:ok, {:msg_row_desc, fields}, _}, returned: returned} ->
          {Enum.map(fields, &elem(&1, 4)), Enum.map(fields, &elem(&1, 6)),
           Enum.map(fields, &elem(&1, 1)), fields, returned.index}

        %{expected: {:ok, {:msg_no_data}, _}, returned: returned} ->
          {nil, nil, nil, nil, returned.index}

        nil ->
          {nil, nil, nil, nil, :no_description}
      end

    param_oids =
      case parameters do
        %{expected: {:ok, {:msg_parameter_desc, values}, _}} -> values
        nil -> root.query.param_oids || []
      end

    %{
      result_oids: oids,
      result_mods: mods,
      columns: columns,
      fields: fields,
      param_oids: param_oids,
      origin: origin
    }
  end

  defp query_factory(state, source, call, input, :describe_params) do
    with {:ok, infos} <- query_type_info(state, source, call) do
      {formats, types} = Enum.unzip(infos)

      {:ok,
       %{input.query | param_oids: input.param_oids, param_formats: formats, param_types: types}}
    end
  end

  defp query_factory(state, source, call, input, :describe_result) do
    references =
      for {_index, pair} <- state.pairs,
          pair.source.pid == source.pid,
          pair.source.index > call.index and pair.returned.index < source.index,
          pair.source.mfa == {:erlang, :make_ref, 0},
          {_, :return_from, _, ref} = pair.returned.event,
          do: ref

    with [ref] <- references,
         true <- is_reference(ref),
         {:ok, formats, types} <- query_result_types(state, source, call, input) do
      {:ok,
       %{
         input.query
         | ref: ref,
           types: input.types,
           columns: input.columns,
           result_oids: input.result_oids,
           result_formats: formats,
           result_types: types
       }}
    else
      _ -> :error
    end
  end

  defp query_result_types(_state, _source, _call, %{result_oids: nil}), do: {:ok, [], nil}

  defp query_result_types(state, source, call, input) do
    with {:ok, infos} <- query_type_info(state, source, call) do
      {formats, types} = Enum.unzip(infos)

      types =
        Enum.zip_with(types, input.result_mods, fn
          {extension, sub_oids, sub_types}, mod -> {extension, sub_oids, sub_types, mod}
          extension, mod -> {extension, mod}
        end)

      {:ok, formats, types}
    end
  end

  defp query_type_info(state, source, call) do
    results =
      state.pairs
      |> Map.values()
      |> Enum.filter(fn pair ->
        pair.source.pid == source.pid and pair.source.index > call.index and
          pair.returned.index < source.index and
          pair.source.mfa == {Postgrex.Types, :fetch, 2}
      end)
      |> Enum.sort_by(& &1.source.index)
      |> Enum.map(fn pair -> elem(pair.returned.event, 3) end)

    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(results, &elem(&1, 1))},
      else: :error
  end

  defp earlier_query_factory(state, source, first) do
    state.query_outputs
    |> Enum.filter(fn {index, query} ->
      index > first and index < source.index and query.pid == source.pid
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {_index, value} -> value
      nil -> nil
    end
  end

  defp commit_cursor(source, state) do
    case Map.pop(state.pending_cursors, source.index) do
      {nil, _pending} ->
        state

      {%{port: port, cursor: cursor, returned_buffer: buffer}, pending} ->
        version = %{index: source.index, port: port, cursor: cursor, returned_buffer: buffer}

        state
        |> Map.put(:pending_cursors, pending)
        |> put_in([:cursors, port], cursor)
        |> Map.update!(:versions, &[version | &1])
        |> Map.update!(:timeline, &[Map.put(version, :kind, :decoder_return) | &1])
    end
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
        version = %{index: source.index, port: port, cursor: cursor, kind: :native_delivery}

        state
        |> put_in([:cursors, port], cursor)
        |> Map.update!(:timeline, &[version | &1])

      :error ->
        failure(state, source, :decoder_history, false)
    end
  end

  defp decoder_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, :redescribe, 6},
              {:ok, %Postgrex.Query{}, %{sock: {:gen_tcp, port}}, _buffer}}
         } = e,
         state
       ) do
    case state.query_outputs[e.index] do
      %{query: query} ->
        origin = %{query: query, port: port, index: e.index, path: [3, 1]}

        state
        |> put_in([:descriptors, query.ref], origin)
        |> put_in([:executing, port], origin)
        |> execution_version(e, port, origin)

      nil ->
        failure(state, e, :decoder_query_factory_origin, false)
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

        state = if function == :handle_execute, do: reset_rows(state, e, port), else: state

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
    case Map.fetch(state.cursors, port) do
      {:ok, cursor} ->
        state = exact(state, e, :decoder_replay_buffer, buffer, cursor.buffer)

        if buffer == <<>>,
          do: state,
          else: replay(e, protocol, buffer, port, cursor, state)

      :error ->
        failure(state, e, :decoder_replay_origin, false)
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
      {:ok, origin} ->
        state = exact(state, e, :decoder_query_copy, query, origin.query)

        state
        |> put_in([:executing, port], origin)
        |> execution_version(e, port, origin)

      _ ->
        failure(state, e, :decoder_query_origin, false)
    end
  end

  defp executing(state, _e, _port, _query), do: state

  defp execution_version(state, source, port, origin) do
    version = %{index: source.index, pid: source.pid, port: port, descriptor: origin}
    Map.update!(state, :executions, &[version | &1])
  end

  defp reset_rows(state, source, port) do
    case Map.fetch(state.cursors, port) do
      {:ok, cursor} ->
        cursor = %{cursor | rows: []}
        version = %{index: source.index, port: port, cursor: cursor, kind: :execution_start}

        state
        |> put_in([:cursors, port], cursor)
        |> Map.update!(:timeline, &[version | &1])

      :error ->
        state
    end
  end

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
    # Unsolicited messages have no command context. They remain in the stream;
    # the next associated backend message supplies this execution's descriptor.
    %{context: context} =
      Enum.find(messages, fn message ->
        message.direction == :backend and message.start >= offset and message.context != nil
      end)

    context
  end

  # Postgrex owns the decoder types, including modifiers and composite types.
  # Keep its prepared Query return as the origin; opaque values are only copied
  # and passed back to their owner. The independent wire catalog checks the
  # descriptor's statement, OIDs, column names and execution formats.
  defp query_metadata(state, source, query, context, types) do
    names =
      if context.description == :none, do: nil, else: Enum.map(context.columns, &elem(&1, 0))

    oids = if context.description == :none, do: nil, else: Enum.map(context.columns, &elem(&1, 3))
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
    # The paired return proves the result, but its cursor becomes available only
    # at that actual return event. Copies observed inside the decoder still see
    # the preceding version, even when another role interleaves there.
    returned_buffer =
      case expected do
        {:ok, _value, buffer} -> buffer
        {:more, buffer, _rows, _required} -> buffer
        {:more, _required} -> cursor.buffer
      end

    pending = %{port: port, cursor: cursor, returned_buffer: returned_buffer}
    state = put_in(state.pending_cursors[pair.returned.index], pending)
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
