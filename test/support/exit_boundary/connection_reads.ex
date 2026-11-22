defmodule AshOnetime.Test.ExitBoundary.ConnectionReads do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.ConnectionProtocol
  alias AshOnetime.Test.ExitBoundary.Wire

  # Native program validation and framing demand are separate proofs. An extra
  # perfectly formed driver read is still refused when the protocol needs none.
  # Nothing in this ledger changes or removes an observation event.
  def build(native, readback \\ MapSet.new(), catalogs \\ %{}) do
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
          errors: [],
          demands: [],
          readback: readback,
          catalogs: catalogs,
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
      demands: Enum.reverse(state.demands)
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

  defp event({_index, :reply, %{result: {:error, _}}}, state), do: state

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
    for {_index, %{source: %{mfa: {Postgrex.Protocol, :ping, 1}}} = pair} <- native.pairs,
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
    {_, :call, {_, _, [protocol]}} = ping.source.event

    origin =
      Enum.find_value(state.historical, fn
        {_holder, %{protocol: %{sock: {:gen_tcp, port}} = historical}}
        when port == read.port ->
          historical

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
    put_in(state.connections[port], connection)
  end

  defp connection(state, port),
    do:
      Map.get(state.connections, port, %{
        framing: Wire.frame_state(),
        protocol: ConnectionProtocol.new(Map.get(state.catalogs, port, %{}))
      })

  defp finish(connection) do
    framing = Wire.finish_frames(connection.framing)
    protocol = ConnectionProtocol.finish(connection.protocol)

    %{
      framing: framing,
      protocol: protocol,
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
