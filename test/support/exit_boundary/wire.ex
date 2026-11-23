defmodule AshOnetime.Test.ExitBoundary.Wire do
  @moduledoc false

  # Input is one physical connection's actual writes and native deliveries, never
  # their mirrored copies. Offsets are independent in the two directions. A frame
  # retains the source span of every byte, including a header split over receives.
  def frames(chunks) do
    chunks |> Enum.reduce(frame_state(), &frame_chunk/2) |> finish_frames()
  end

  def frame_state do
    stream = %{buffer: <<>>, offset: 0, received: 0, provenance: []}
    %{directions: %{frontend: stream, backend: stream}, messages: [], errors: []}
  end

  def frame_state(:startup), do: Map.put(frame_state(), :format, :startup)
  def frame_state(:connection_startup), do: Map.put(frame_state(), :format, :connection_startup)
  def push_frame(state, chunk), do: frame_chunk(chunk, state)

  def finish_frames(state) do
    incomplete =
      for {direction, stream} <- state.directions,
          stream.buffer != <<>>,
          do: %{
            rule: :incomplete_frame,
            direction: direction,
            offset: stream.offset,
            received: byte_size(stream.buffer),
            required: frame_remaining(stream.buffer)
          }

    %{
      messages: Enum.reverse(state.messages),
      errors: Enum.reverse(state.errors) ++ Enum.sort_by(incomplete, & &1.direction),
      directions: state.directions
    }
  end

  # Postgrex requests all currently available bytes until the five-byte header is
  # present; after that it requests exactly the missing body, capped at 64 MiB.
  def frame_remaining(bytes) when byte_size(bytes) < 5, do: 0

  def frame_remaining(<<_tag, size::signed-32, tail::binary>>) when size >= 4,
    do: max(size - 4 - byte_size(tail), 0)

  def frame_remaining(_bytes), do: :invalid_length

  defp frame_chunk(%{direction: direction, bytes: bytes} = chunk, state)
       when direction in [:frontend, :backend] and is_binary(bytes) do
    stream = Map.fetch!(state.directions, direction)

    span = %{
      index: chunk.index,
      offset: stream.received,
      source_offset: Map.get(chunk, :source_offset, 0),
      phase: Map.get(chunk, :phase, :shared),
      copies: Map.get(chunk, :copies, []),
      length: byte_size(bytes)
    }

    stream = %{
      stream
      | buffer: stream.buffer <> bytes,
        received: stream.received + byte_size(bytes),
        provenance: stream.provenance ++ [span]
    }

    {stream, state} = extract_frames(stream, direction, state)
    put_in(state.directions[direction], stream)
  end

  defp extract_frames(stream, direction, %{format: :startup} = state),
    do: extract_startup(stream, direction, state)

  defp extract_frames(stream, direction, %{format: :connection_startup} = state),
    do: extract_startup(stream, direction, state)

  defp extract_frames(stream, direction, %{format: :ssl_response} = state),
    do: extract_ssl_response(stream, direction, state)

  defp extract_frames(
         %{buffer: <<tag, size::signed-32, tail::binary>>} = stream,
         direction,
         state
       )
       when size >= 4 and byte_size(tail) >= size - 4 do
    payload_size = size - 4
    <<payload::binary-size(^payload_size), rest::binary>> = tail
    stop = stream.offset + size + 1

    message = %{
      direction: direction,
      tag: tag,
      payload: payload,
      start: stream.offset,
      stop: stop,
      provenance: spans(stream.provenance, stream.offset, stop)
    }

    {message, state} = frame_ownership(message, state)

    stream = %{
      stream
      | buffer: rest,
        offset: stop,
        provenance: Enum.filter(stream.provenance, &(&1.offset + &1.length > stop))
    }

    extract_frames(stream, direction, %{state | messages: [message | state.messages]})
  end

  defp extract_frames(%{buffer: <<_tag, size::signed-32, _::binary>>} = stream, direction, state)
       when size < 4 do
    error = %{rule: :frame_length, direction: direction, offset: stream.offset, actual: size}
    {stream, %{state | errors: [error | state.errors]}}
  end

  defp extract_frames(stream, _direction, state), do: {stream, state}

  defp extract_startup(
         %{buffer: <<size::signed-32, tail::binary>>} = stream,
         :frontend,
         state
       )
       when size >= 8 and byte_size(tail) >= size - 4 do
    payload_size = size - 4
    <<payload::binary-size(^payload_size), rest::binary>> = tail
    stop = stream.offset + size

    message = %{
      direction: :frontend,
      tag: :startup,
      payload: payload,
      start: stream.offset,
      stop: stop,
      provenance: spans(stream.provenance, stream.offset, stop)
    }

    {message, state} = frame_ownership(message, state)

    stream = %{
      stream
      | buffer: rest,
        offset: stop,
        provenance: Enum.filter(stream.provenance, &(&1.offset + &1.length > stop))
    }

    state = %{state | messages: [message | state.messages]}

    case {Map.get(state, :format), payload} do
      {:connection_startup, <<80_877_103::32>>} ->
        extract_frames(stream, :frontend, Map.put(state, :format, :ssl_response))

      {:connection_startup, _payload} ->
        extract_frames(stream, :frontend, Map.delete(state, :format))

      _ ->
        extract_startup(stream, :frontend, state)
    end
  end

  defp extract_startup(%{buffer: <<size::signed-32, _::binary>>} = stream, :frontend, state)
       when size < 8 do
    error = %{rule: :frame_length, direction: :frontend, offset: stream.offset, actual: size}
    {stream, %{state | errors: [error | state.errors]}}
  end

  defp extract_startup(%{buffer: bytes} = stream, :backend, state) when bytes != <<>> do
    error = %{rule: :cancel_backend_bytes, direction: :backend, offset: stream.offset}
    {stream, %{state | errors: [error | state.errors]}}
  end

  defp extract_startup(stream, _direction, state), do: {stream, state}

  # SSLRequest has a one-byte response before the TLS handshake. An E instead
  # begins an ordinary PostgreSQL ErrorResponse; keep that byte in its frame.
  defp extract_ssl_response(%{buffer: <<?E, _::binary>>} = stream, :backend, state),
    do: extract_frames(stream, :backend, Map.delete(state, :format))

  defp extract_ssl_response(%{buffer: <<reply, rest::binary>>} = stream, :backend, state) do
    stop = stream.offset + 1

    message = %{
      direction: :backend,
      tag: :ssl_response,
      payload: <<reply>>,
      start: stream.offset,
      stop: stop,
      provenance: spans(stream.provenance, stream.offset, stop)
    }

    {message, state} = frame_ownership(message, state)

    stream = %{
      stream
      | buffer: rest,
        offset: stop,
        provenance: Enum.filter(stream.provenance, &(&1.offset + &1.length > stop))
    }

    state = %{state | messages: [message | state.messages]}

    state =
      if reply == ?S,
        do: Map.put(state, :format, :connection_startup),
        else: Map.delete(state, :format)

    extract_frames(stream, :backend, state)
  end

  defp extract_ssl_response(%{buffer: <<>>} = stream, _direction, state), do: {stream, state}

  defp extract_ssl_response(stream, :frontend, state) do
    error = %{rule: :ssl_response_required, direction: :frontend, offset: stream.offset}
    {stream, %{state | errors: [error | state.errors]}}
  end

  defp frame_ownership(%{direction: :frontend} = message, state) do
    phases = Enum.uniq(Enum.map(message.provenance, & &1.phase))

    state =
      if length(phases) == 1 do
        state
      else
        error = %{
          rule: :frame_ownership,
          direction: message.direction,
          offset: message.start,
          actual: phases,
          expected: :one_causal_frontend_origin
        }

        %{state | errors: [error | state.errors]}
      end

    {Map.put(message, :phase, List.first(phases)), state}
  end

  defp frame_ownership(message, state), do: {Map.put(message, :phase, :backend), state}

  def spans(spans, first, last) do
    for span <- spans,
        start = max(span.offset, first),
        stop = min(span.offset + span.length, last),
        stop > start do
      %{
        span
        | offset: start,
          source_offset: span.source_offset + start - span.offset,
          copies: copy_spans(span.copies, start - span.offset, stop - start),
          length: stop - start
      }
    end
  end

  defp copy_spans(copies, offset, size),
    do: Enum.map(copies, &%{&1 | offset: &1.offset + offset, length: size})

  # Decode only the TCP driver's documented command and PostgreSQL messages at
  # transport positions. Arbitrary binaries are never inspected for ETF or packets.
  def build(indexed, readback \\ MapSet.new()) do
    Enum.map_reduce(indexed.events, %{}, fn e, connections ->
      # This is annotation provenance, never server or prepared-connection state.
      # OPEN's independently checked extra statements cannot advance the ordinal
      # of a subsequent shared statement on the same physical connection.
      phase = if MapSet.member?(readback, e.index), do: :committed_read, else: :shared
      connections = Map.put(connections, :annotation_phase, phase)
      {event, connections} = transport(e.event, connections)
      e = e |> Map.put(:event, event) |> Map.put(:wire_sql, statement(event, connections))
      {e, connections}
    end)
    |> elem(0)
  end

  # A Bind may be in a later packet than its Parse. Keep its qualification
  # on this native connection's protocol instance, including mirrored copies.
  defp statement({port, _, _, _}, connections) when is_port(port),
    do: get_in(connections, [port, :sql])

  defp statement({port, _, _}, connections) when is_port(port),
    do: get_in(connections, [port, :sql])

  defp statement({_, :call, {m, f, [port | _]}}, connections)
       when m in [:erlang, :erts_internal, :prim_inet, :gen_tcp] and
              f in [:port_command, :send, :recv, :recv0] and is_port(port),
       do: get_in(connections, [port, :sql])

  defp statement({_, :receive, {:tcp, port, _}}, connections),
    do: get_in(connections, [port, :sql])

  defp statement({_, :receive, {:inet_async, port, _, _}}, connections),
    do: get_in(connections, [port, :sql])

  defp statement({pid, :return_from, {m, f, _}, _}, connections)
       when m in [:prim_inet, :gen_tcp] and f in [:recv, :recv0],
       do: get_in(connections, [connections[{:receiving, pid}], :sql])

  defp statement(_, _), do: nil

  defp transport({pid, :call, {m, f, [port, data | rest]}}, state)
       when m in [:erlang, :erts_internal, :prim_inet, :gen_tcp] and f in [:port_command, :send] and
              is_port(port) do
    driver? = f == :port_command or (m == :prim_inet and length(rest) == 2)
    {decoded, state} = packet(data, port, {m, f}, driver?, state)
    {{pid, :call, {m, f, [port, decoded | rest]}}, state}
  end

  defp transport({port, :receive, {pid, {:command, data}}}, state) when is_port(port) do
    {decoded, state} = packet(data, port, :driver_command, true, state)
    {{port, :receive, {pid, {:command, decoded}}}, state}
  end

  defp transport({pid, :receive, {:tcp, port, data}}, state) do
    {decoded, state} = packet(data, port, :tcp_receive, false, state)
    {{pid, :receive, {:tcp, port, decoded}}, state}
  end

  defp transport({port, :send, {:tcp, port, data}, pid}, state) when is_port(port) do
    {decoded, state} = packet(data, port, :tcp_send, false, state)
    {{port, :send, {:tcp, port, decoded}, pid}, state}
  end

  defp transport({pid, :receive, {:inet_async, port, ref, {:ok, data}}}, state) do
    {decoded, state} = packet(data, port, :async_receive, false, state)
    {{pid, :receive, {:inet_async, port, ref, {:ok, decoded}}}, state}
  end

  defp transport({port, :send, {:inet_async, port, ref, {:ok, data}}, pid}, state)
       when is_port(port) do
    {decoded, state} = packet(data, port, :async_send, false, state)
    {{port, :send, {:inet_async, port, ref, {:ok, decoded}}, pid}, state}
  end

  defp transport({pid, :call, {m, f, [port | _]}} = event, state)
       when m in [:prim_inet, :gen_tcp] and f in [:recv, :recv0] and is_port(port),
       do: {event, Map.put(state, {:receiving, pid}, port)}

  defp transport({pid, :return_from, {m, f, _} = mfa, {:ok, data}}, state)
       when m in [:prim_inet, :gen_tcp] and f in [:recv, :recv0] do
    case Map.fetch(state, {:receiving, pid}) do
      {:ok, port} ->
        {decoded, state} = packet(data, port, {:recv_return, m, f}, false, state)
        {{pid, :return_from, mfa, {:ok, decoded}}, state}

      :error ->
        {{pid, :return_from, mfa, {:ok, data}}, state}
    end
  end

  defp transport(event, state), do: {event, state}

  defp packet(data, port, layer, driver?, state) do
    bytes = IO.iodata_to_binary(data)
    {header, bytes} = if driver?, do: driver(bytes), else: {nil, bytes}

    connection =
      Map.get(state, port, %{
        parameter_types: [],
        columns: [],
        sql: nil,
        binds: [],
        statement: {:wire_statement, :shared, 0},
        counts: %{}
      })

    connection = Map.put(connection, :annotation_phase, Map.fetch!(state, :annotation_phase))

    connection =
      Map.put(
        connection,
        :direction,
        if(
          layer in [
            :driver_command,
            {:erlang, :port_command},
            {:erts_internal, :port_command},
            {:prim_inet, :send},
            {:gen_tcp, :send}
          ],
          do: :frontend,
          else: :backend
        )
      )

    case messages(bytes, connection, []) do
      {:ok, decoded, connection} ->
        {{:pg_transport, layer, header, decoded}, Map.put(state, port, connection)}

      :error ->
        {data, state}
    end
  rescue
    ArgumentError -> {data, state}
    MatchError -> {data, state}
    FunctionClauseError -> {data, state}
  end

  defp driver(<<size::16, reference::binary-size(size), bytes::binary>>) do
    case :erlang.binary_to_term(reference, [:safe, :used]) do
      {ref, ^size} when is_reference(ref) -> {{:driver_reference, ref}, bytes}
      _ -> raise ArgumentError
    end
  end

  defp driver(bytes), do: {nil, bytes}

  defp messages(<<>>, state, result), do: {:ok, Enum.reverse(result), state}

  defp messages(<<tag, size::32, bytes::binary>>, state, result)
       when size >= 4 and byte_size(bytes) >= size - 4 do
    payload_size = size - 4
    <<payload::binary-size(^payload_size), tail::binary>> = bytes
    {decoded, state} = message(tag, payload, state)
    messages(tail, state, [{tag, decoded} | result])
  end

  defp messages(_, _, _), do: :error

  defp message(?P, payload, state) do
    {name, payload} = string(payload)
    {sql, <<count::16, oids::binary>>} = string(payload)
    types = for <<oid::32 <- oids>>, do: oid
    {{:parse, name, sql, count, types}, statement_origin(state, sql)}
  end

  defp message(?t, <<count::16, bytes::binary>>, state) do
    types = for <<oid::32 <- bytes>>, do: oid
    {{:parameter_description, count, types}, %{state | parameter_types: types}}
  end

  defp message(?B, payload, state) do
    {portal, rest} = string(payload)
    {statement, <<count::16, rest::binary>>} = string(rest)
    {formats, rest} = words(rest, count, [])
    <<nparams::16, rest::binary>> = rest
    {params, rest} = values(rest, nparams, [])
    <<nformats::16, rest::binary>> = rest
    {result_formats, <<>>} = words(rest, nformats, [])

    params =
      params
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        oid = Enum.at(state.parameter_types, index, :unknown)

        format =
          case formats do
            [] -> 0
            [format] -> format
            _ -> Enum.at(formats, index)
          end

        {:bind_column, index + 1, oid, format, decode(oid, format, value)}
      end)

    columns =
      Enum.with_index(state.columns)
      |> Enum.map(fn {column, n} ->
        format =
          case result_formats do
            [] -> 0
            [one] -> one
            many -> Enum.fetch!(many, n)
          end

        put_elem(column, 6, format)
      end)

    {{:bind, portal, statement, formats, params, result_formats},
     %{state | binds: params, columns: columns}}
  end

  defp message(?T, <<count::16, payload::binary>>, state) do
    {fields, <<>>} = fields(payload, count, [])

    {{:row_description, fields},
     state |> Map.put(:columns, fields) |> Map.put(:description, :rows)}
  end

  defp message(?n, <<>>, state),
    do:
      {{:exact_payload, ?n, <<>>}, state |> Map.put(:columns, []) |> Map.put(:description, :none)}

  defp message(?D, payload, %{direction: :frontend} = state), do: {{:describe, payload}, state}

  defp message(?D, <<count::16, payload::binary>>, state) do
    {values, <<>>} = values(payload, count, [])
    true = count == length(state.columns)

    columns =
      Enum.zip(values, state.columns)
      |> Enum.with_index()
      |> Enum.map(fn {{value, field}, index} ->
        {name, table, number, oid, _width, _modifier, format} = field

        {:data_column, state.sql, {state.statement, state.binds}, index, name, table, number, oid,
         format, decode(oid, format, value)}
      end)

    {{:data_row, columns}, state}
  end

  defp message(tag, payload, state), do: {{:exact_payload, tag, payload}, state}

  defp statement_origin(state, sql) do
    phase = state.annotation_phase
    ordinal = Map.get(state.counts, phase, 0) + 1

    %{
      state
      | sql: sql,
        statement: {:wire_statement, phase, ordinal},
        counts: Map.put(state.counts, phase, ordinal)
    }
  end

  defp decode(_oid, _format, nil), do: nil
  defp decode(2950, 1, <<_::128>> = value), do: {:uuid, Ecto.UUID.load!(value)}
  defp decode(2950, 0, value), do: {:uuid, value}
  defp decode(1184, 1, <<value::signed-64>>), do: {:timestamptz, value}
  defp decode(1082, 1, <<value::signed-32>>), do: {:date, value}
  defp decode(20, 1, <<value::signed-64>>), do: value
  defp decode(23, 1, <<value::signed-32>>), do: value
  defp decode(16, 1, <<value>>), do: value == 1
  defp decode(_oid, _format, value), do: value

  defp fields(bytes, 0, acc), do: {Enum.reverse(acc), bytes}

  defp fields(bytes, count, acc) do
    {name,
     <<table::32, number::16, oid::32, width::signed-16, modifier::signed-32, format::16,
       rest::binary>>} = string(bytes)

    fields(rest, count - 1, [
      {name, {:table_oid, table}, number, oid, width, modifier, format} | acc
    ])
  end

  defp words(bytes, 0, acc), do: {Enum.reverse(acc), bytes}
  defp words(<<word::16, rest::binary>>, n, acc), do: words(rest, n - 1, [word | acc])
  defp values(bytes, 0, acc), do: {Enum.reverse(acc), bytes}
  defp values(<<-1::signed-32, rest::binary>>, n, acc), do: values(rest, n - 1, [nil | acc])

  defp values(<<size::signed-32, value::binary-size(size), rest::binary>>, n, acc),
    do: values(rest, n - 1, [value | acc])

  defp string(bytes) do
    {size, 1} = :binary.match(bytes, <<0>>)
    <<string::binary-size(^size), 0, rest::binary>> = bytes
    {string, rest}
  end

  def decode_message(tag, payload, state), do: message(tag, payload, state)
end
