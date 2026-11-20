defmodule AshOnetime.Test.ExitBoundary.Wire do
  @moduledoc false

  # Decode only the TCP driver's documented command and PostgreSQL messages at
  # transport positions. Arbitrary binaries are never inspected for ETF or packets.
  def build(indexed) do
    Enum.map_reduce(indexed.events, %{}, fn e, connections ->
      {event, connections} = transport(e.event, connections)
      {%{e | event: event}, connections}
    end) |> elem(0)
  end

  defp transport({pid, :call, {m, f, [port, data | rest]}}, state)
       when m in [:erlang, :erts_internal, :prim_inet, :gen_tcp] and f in [:port_command, :send] and is_port(port) do
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
  defp transport({port, :send, {:inet_async, port, ref, {:ok, data}}, pid}, state) when is_port(port) do
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
      :error -> {{pid, :return_from, mfa, {:ok, data}}, state}
    end
  end
  defp transport(event, state), do: {event, state}

  defp packet(data, port, layer, driver?, state) do
    bytes = IO.iodata_to_binary(data)
    {header, bytes} = if driver?, do: driver(bytes), else: {nil, bytes}
    connection = Map.get(state, port, %{parameter_types: [], columns: [], sql: nil, binds: [], statement: 0})
    connection = Map.put(connection, :direction, if(layer in [:driver_command, {:erlang, :port_command}, {:erts_internal, :port_command}, {:prim_inet, :send}, {:gen_tcp, :send}], do: :frontend, else: :backend))
    case messages(bytes, connection, []) do
      {:ok, decoded, connection} ->
        {{:pg_transport, layer, header, decoded}, Map.put(state, port, connection)}
      :error -> {data, state}
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
  defp messages(<<tag, size::32, bytes::binary>>, state, result) when size >= 4 and byte_size(bytes) >= size - 4 do
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
    {{:parse, name, sql, count, types}, %{state | sql: sql, statement: state.statement + 1}}
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
    params = params |> Enum.with_index() |> Enum.map(fn {value, index} ->
      oid = Enum.at(state.parameter_types, index, :unknown)
      format = case formats do [] -> 0; [format] -> format; _ -> Enum.at(formats, index) end
      {:bind_column, index + 1, oid, format, decode(oid, format, value)}
    end)
    columns = Enum.with_index(state.columns) |> Enum.map(fn {column, n} ->
      format = case result_formats do [] -> 0; [one] -> one; many -> Enum.fetch!(many, n) end
      put_elem(column, 6, format)
    end)
    {{:bind, portal, statement, formats, params, result_formats}, %{state | binds: params, columns: columns}}
  end
  defp message(?T, <<count::16, payload::binary>>, state) do
    {fields, <<>>} = fields(payload, count, [])
    {{:row_description, fields}, %{state | columns: fields}}
  end
  defp message(?D, payload, %{direction: :frontend} = state), do: {{:describe, payload}, state}
  defp message(?D, <<count::16, payload::binary>>, state) do
    {values, <<>>} = values(payload, count, [])
    true = count == length(state.columns)
    columns = Enum.zip(values, state.columns) |> Enum.with_index() |> Enum.map(fn {{value, field}, index} ->
      {name, table, number, oid, _width, _modifier, format} = field
      {:data_column, state.sql, {state.statement, state.binds}, index, name, table, number, oid, format, decode(oid, format, value)}
    end)
    {{:data_row, columns}, state}
  end
  defp message(tag, payload, state), do: {{:exact_payload, tag, payload}, state}

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
    {name, <<table::32, number::16, oid::32, width::signed-16, modifier::signed-32, format::16, rest::binary>>} = string(bytes)
    fields(rest, count - 1, [{name, {:table_oid, table}, number, oid, width, modifier, format} | acc])
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
end
