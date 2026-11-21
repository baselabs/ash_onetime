defmodule AshOnetime.Test.ExitBoundary.ConnectionReads do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.ConnectionProtocol
  alias AshOnetime.Test.ExitBoundary.Wire

  # Native program validation and framing demand are separate proofs. An extra
  # perfectly formed driver read is still refused when the protocol needs none.
  # Nothing in this ledger changes or removes an observation event.
  def build(native, readback \\ MapSet.new()) do
    writes = for write <- native.writes, do: {write.command.index, :write, write}
    requests = for read <- native.reads, do: {read.source.index, :request, read}
    replies = for read <- native.reads, do: {read.returned.index, :reply, read}

    state =
      (writes ++ requests ++ replies)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(%{connections: %{}, errors: [], demands: [], readback: readback}, &event/2)

    connections =
      Map.new(state.connections, fn {port, connection} -> {port, finish(connection)} end)

    errors = Enum.flat_map(connections, fn {_port, c} -> c.errors end)

    %{
      connections: connections,
      errors: Enum.reverse(state.errors) ++ errors,
      demands: Enum.reverse(state.demands)
    }
  end

  defp event({_index, :request, read}, state) do
    connection = connection(state, read.port)
    buffer = get_in(connection.framing, [:directions, :backend, :buffer]) || <<>>

    case ConnectionProtocol.request(connection.protocol, buffer) do
      {:ok, expected} ->
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
      phase: :backend
    })
  end

  defp feed(state, port, chunk) do
    connection = connection(state, port)
    prior_count = length(connection.framing.messages)
    framing = Wire.push_frame(connection.framing, chunk)
    added = Enum.take(framing.messages, length(framing.messages) - prior_count) |> Enum.reverse()

    protocol =
      Enum.reduce(added, connection.protocol, fn frame, protocol ->
        ConnectionProtocol.push(protocol, Map.put(frame, :phase, chunk.phase))
      end)

    connection = %{connection | framing: framing, protocol: protocol}
    put_in(state.connections[port], connection)
  end

  defp connection(state, port),
    do:
      Map.get(state.connections, port, %{
        framing: Wire.frame_state(),
        protocol: ConnectionProtocol.new()
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
