defmodule AshOnetime.Test.ExitBoundary.ConnectionReads do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.ConnectionProtocol
  alias AshOnetime.Test.ExitBoundary.NativeTransport
  alias AshOnetime.Test.ExitBoundary.Wire

  # Native program validation and framing demand are separate proofs. An extra
  # perfectly formed driver read is still refused when the protocol needs none.
  # Nothing in this ledger changes or removes an observation event.
  def build(native, readback \\ MapSet.new(), protocols \\ %{}) do
    {cancellations, cancellation_errors} = cancellations(native)
    writes = for write <- native.writes, do: {write.command.index, :write, write}
    requests = for read <- native.reads, do: {read.source.index, :request, read}
    replies = for read <- native.reads, do: {read.returned.index, :reply, read}
    active = for delivery <- native.active, do: {delivery.delivered.index, :active, delivery}

    state =
      (writes ++ requests ++ replies ++ active)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(
        %{
          connections: %{},
          errors: cancellation_errors,
          demands: [],
          versions: [],
          readback: readback,
          protocols: protocols,
          framing: Map.get(native, :connection_framing, %{}),
          cancellations: cancellations,
          pings: ping_calls(native),
          historical: Map.get(native, :historical, %{})
        },
        &event/2
      )

    connections =
      Map.new(state.connections, fn {port, connection} -> {port, finish(connection)} end)

    errors =
      Enum.flat_map(connections, fn {port, c} ->
        Enum.map(c.errors, &Map.put(&1, :port, port))
      end)

    %{
      connections: connections,
      errors: Enum.reverse(state.errors) ++ errors,
      demands: Enum.reverse(state.demands),
      versions: Enum.reverse(state.versions)
    }
  end

  # Several messages can finish at one native event. Keep that event's real
  # integer index for chronology and raw source lookup, with a separate address
  # for the logical message and all its database slots and query contexts.
  def messages(streams, indexed) do
    native = Map.new(indexed.events, &{&1.index, &1})

    for {port, connection} <- streams.connections,
        message <- connection.protocol.messages do
      span = Enum.max_by(message.provenance, & &1.index)
      source = Map.fetch!(native, span.index)
      transport = {:pg_transport, :stream, nil, [message.decoded]}

      event =
        case {message.direction, source.event} do
          {:frontend, {^port, :receive, {owner, {:command, _bytes}}}} ->
            {port, :receive, {owner, {:command, transport}}}

          {:backend, {^port, :send, _message, owner}} ->
            {port, :send, {:tcp, port, transport}, owner}

          {:frontend, {owner, :call, {:ssl, :send, [_socket, _bytes]}}} ->
            {owner, :call, {:ssl, :send, [port, transport]}}

          {:backend, {owner, :return_from, {:ssl, :recv, 3}, {:ok, _bytes}}} ->
            {owner, :return_from, {:ssl, :recv, 3}, {:ok, transport}}
        end

      source
      |> Map.put(:event, event)
      |> Map.put(
        :message_address,
        {:connection_message, port, message.direction, message.message_ordinal}
      )
      |> Map.put(:wire_sql, message.sql)
      |> Map.put(:wire_frame, message)
    end
    |> Enum.sort_by(&{&1.index, &1.wire_frame.start})
  end

  defp event({_index, :request, read}, state) do
    connection = connection(state, read.port)
    buffer = get_in(connection.framing, [:directions, :backend, :buffer]) || <<>>

    case ConnectionProtocol.request(connection.protocol, buffer) do
      {:ok, expected} ->
        {timeout, state} = receive_timeout(state, read, expected.timeout)
        expected = %{expected | timeout: timeout}
        state = exact(state, read, :receive_length, read.length, expected.length)
        state = exact(state, read, :receive_timeout, read.timeout, expected.timeout)

        demand = %{
          index: read.source.index,
          port: read.port,
          offset: received(connection),
          required: expected,
          origin: read.provenance
        }

        %{state | demands: [demand | state.demands]}

      {:error, reason} ->
        failure(state, read, :receive_required, reason, :framing_requires_a_read)
    end
  end

  defp event({_index, :write, write}, state) do
    phase =
      if MapSet.member?(state.readback, write.command.index), do: :committed_read, else: :shared

    feed(state, write.port, %{
      index: write.command.index,
      direction: :frontend,
      bytes: write.bytes,
      source_offset: write.header_size,
      copies: write.copies,
      phase: phase
    })
  end

  defp event({_index, :reply, %{result: {:error, _}} = read}, state) do
    connection = connection(state, read.port)

    if Map.has_key?(connection.protocol, :cancel) do
      case ConnectionProtocol.close_cancel(connection.protocol, read.result) do
        {:ok, protocol} ->
          connection = %{connection | protocol: protocol}

          version = %{
            index: read.returned.index,
            port: read.port,
            framing: connection.framing,
            protocol: protocol
          }

          state
          |> put_in([:connections, read.port], connection)
          |> Map.update!(:versions, &[version | &1])

        {:error, reason} ->
          failure(state, read, reason, :unexpected_cancel_result, :server_closed_without_reply)
      end
    else
      state
    end
  end

  defp event({_index, :reply, read}, state) do
    state =
      if read.length == 0 do
        exact(state, read, :receive_progress, byte_size(read.bytes) > 0, true)
      else
        exact(state, read, :receive_progress, byte_size(read.bytes), read.length)
      end

    feed(state, read.port, %{
      index: read.delivered.index,
      direction: :backend,
      bytes: read.bytes,
      copies: read.copies,
      phase: :backend
    })
  end

  defp event({_index, :active, delivery}, state) do
    connection = connection(state, delivery.port)

    demand = %{
      index: delivery.source.index,
      port: delivery.port,
      offset: received(connection),
      required: %{mode: :once},
      origin: activation_origin(delivery.activation)
    }

    state = %{state | demands: [demand | state.demands]}

    feed(state, delivery.port, %{
      index: delivery.delivered.index,
      direction: :backend,
      bytes: delivery.bytes,
      copies: delivery.copies,
      phase: :backend
    })
  end

  defp activation_origin(%{origin: origin}), do: origin
  defp activation_origin(%{requested: %{index: index}}), do: index

  defp ping_calls(native) do
    for {_index, %{source: %{mfa: {Postgrex.Protocol, :ping, 2}}} = pair} <- native.pairs,
        do: pair
  end

  defp receive_timeout(state, read, default) do
    ping =
      Enum.find(state.pings, fn pair ->
        pair.source.pid == read.source.pid and pair.source.index < read.source.index and
          read.returned.index < pair.returned.index
      end)

    if ping do
      ping_timeout(state, read, ping, default)
    else
      {default, state}
    end
  end

  defp ping_timeout(state, read, ping, default) do
    {_, :call, {_, _, [protocol, _options]}} = ping.source.event

    origin =
      Enum.find_value(state.historical, fn
        {_holder, %{protocol: %{sock: socket} = historical}} ->
          if NativeTransport.physical_port(state, socket) == read.port, do: historical

        _ ->
          nil
      end)

    if origin do
      state = exact(state, read, :receive_timeout_origin, protocol.sock, origin.sock)

      state =
        exact(state, read, :receive_timeout_origin, protocol.ping_timeout, origin.ping_timeout)

      {origin.ping_timeout, state}
    else
      {default, failure(state, read, :receive_timeout_origin, :absent, :historical_ping_timeout)}
    end
  end

  defp feed(state, port, chunk) do
    connection = connection(state, port)
    prior_count = length(connection.framing.messages)
    framing = Wire.push_frame(connection.framing, chunk)
    added = Enum.take(framing.messages, length(framing.messages) - prior_count) |> Enum.reverse()

    protocol =
      Enum.reduce(added, connection.protocol, fn frame, protocol ->
        ConnectionProtocol.push(protocol, frame)
      end)

    connection = %{connection | framing: framing, protocol: protocol}
    version = %{index: chunk.index, port: port, framing: framing, protocol: protocol}

    state
    |> put_in([:connections, port], connection)
    |> Map.update!(:versions, &[version | &1])
  end

  defp connection(state, port) do
    initial =
      case Map.fetch(state.cancellations, port) do
        {:ok, origin} ->
          %{
            framing: Wire.frame_state(:startup),
            protocol: ConnectionProtocol.cancellation(origin)
          }

        :error ->
          initial_connection(state, port)
      end

    Map.get(state.connections, port, initial)
  end

  defp initial_connection(state, port) do
    protocol = Map.get(state.protocols, port, ConnectionProtocol.new())

    %{
      framing: Map.get(state.framing, port, Wire.frame_state()),
      # A cut may have outstanding frontend operations. Retain their request
      # ownership, portals and counters; only this capture's emitted messages
      # start empty. Earlier messages remain in the retained history.
      protocol: %{protocol | messages: []},
      historical_messages: Enum.reverse(protocol.messages)
    }
  end

  # CancelRequest is a startup-format exchange on its own socket. Its authority
  # is the enclosing native request and that request's successful connect, not
  # a byte pattern, another connection's row or the message being checked.
  defp cancellations(native) do
    helpers =
      native.pairs
      |> Map.values()
      |> Enum.filter(&(&1.source.mfa == {Postgrex.Protocol, :cancel_send_recv, 2}))
      |> Enum.sort_by(& &1.source.index)

    Enum.reduce(helpers, {%{}, []}, fn helper, {origins, errors} ->
      {pid, :call, {_, _, [protocol, port]}} = helper.source.event

      roots =
        for {_index, root} <- native.pairs,
            root.source.pid == pid and root.source.index < helper.source.index and
              helper.returned.index < root.returned.index,
            {^pid, :call, {Postgrex.Protocol, :cancel_request, [ip, endpoint, ^protocol]}} <-
              [root.source.event],
            do: {root, ip, endpoint}

      connects =
        for {root, ip, endpoint} <- roots,
            {_index, pair} <- native.pairs,
            pair.source.pid == pid and root.source.index < pair.source.index and
              pair.returned.index < helper.source.index,
            pair.source.event ==
              {pid, :call,
               {:gen_tcp, :connect,
                [ip, endpoint, [mode: :binary, active: false], protocol.timeout]}},
            pair.returned.event == {pid, :return_from, {:gen_tcp, :connect, 4}, {:ok, port}},
            do: {root, pair}

      case connects do
        [{root, connect}] ->
          origin = %{
            source: root.source.index,
            connect: connect.source.index,
            helper: helper.source.index,
            port: port,
            backend: protocol.connection_id,
            key: protocol.connection_key,
            timeout: protocol.timeout
          }

          {Map.put(origins, port, origin), errors}

        _ ->
          error = %{
            index: helper.source.index,
            at: Map.take(helper.source, [:mfa, :role, :stack]),
            rule: :cancel_connection_origin,
            actual: :missing_native_connection,
            expected: :own_successful_cancel_connect
          }

          {origins, [error | errors]}
      end
    end)
  end

  defp finish(connection) do
    framing = Wire.finish_frames(connection.framing)
    protocol = ConnectionProtocol.finish(connection.protocol)

    %{
      framing: framing,
      protocol: protocol,
      historical_messages: Map.get(connection, :historical_messages, []),
      errors: framing.errors ++ protocol.errors
    }
  end

  defp received(connection),
    do: get_in(connection.framing, [:directions, :backend, :received]) || 0

  defp exact(state, _read, _rule, actual, expected) when actual === expected, do: state

  defp exact(state, read, rule, actual, expected),
    do: failure(state, read, rule, actual, expected)

  defp failure(state, read, rule, actual, expected) do
    error = %{
      index: read.source.index,
      at: Map.take(read.source, [:mfa, :role, :stack]),
      rule: rule,
      actual: actual,
      expected: expected
    }

    %{state | errors: [error | state.errors]}
  end
end
