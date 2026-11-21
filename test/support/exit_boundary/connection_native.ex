defmodule AshOnetime.Test.ExitBoundary.ConnectionNative do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.Repo

  # Every packet here goes to the job's real PostgreSQL. Authentication and type
  # bootstrap finish before capture; the socket is owned and closed by the root.
  # Corruptions change real native calls or real frontend messages, never captures.
  def observe(mode, corruption \\ nil) do
    ExitBoundary.observe(
      &connect/0,
      &execute(&1, mode, corruption),
      %{host: [], callbacks: []}
    )
  end

  defp connect do
    options = Keyword.put(Repo.config(), :types, Postgrex.DefaultTypes)
    {:ok, protocol} = Postgrex.Protocol.connect(options)
    {:ok, protocol} = Postgrex.Protocol.checkout(protocol)
    protocol
  end

  defp execute(%{sock: {:gen_tcp, socket}}, :incomplete, nil) do
    try do
      :ok = :inet.setopts(socket, buffer: 4096, recbuf: 8192)
      :ok = :gen_tcp.send(socket, query_sql("SELECT repeat('x', 1048576)"))
      receive_partial(socket)
    after
      :ok = :gen_tcp.close(socket)
    end
  end

  defp execute(%{sock: {module, socket}}, mode, corruption) do
    try do
      values = values(mode, corruption)
      messages = Enum.map(values, &query/1)
      :ok = apply(module, :send, [socket, messages])
      :ok = drain(module, socket, length(values), <<>>, true, corruption)

      if corruption == :extra_read do
        {:error, :timeout} = apply(module, :recv, [socket, 0, 0])
      end

      :ok
    after
      :ok = apply(module, :close, [socket])
    end
  end

  defp values(:single, nil), do: [17]
  defp values(:single, corruption) when corruption in [:length, :timeout, :extra_read], do: [17]
  defp values(:pipeline, nil), do: [17, 29]
  defp values(:pipeline, :byte), do: [18, 29]
  defp values(:pipeline, :swap), do: [29, 17]
  defp values(:pipeline, :drop), do: [17]
  defp values(:pipeline, :add), do: [17, 29, 41]

  defp query(value) do
    sql = "SELECT " <> Integer.to_string(value) <> "::int4 AS connection_stream_probe"
    query_sql(sql)
  end

  defp query_sql(sql) do
    <<?Q, byte_size(sql) + 5::32, sql::binary, 0>>
  end

  defp receive_partial(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, :infinity)

    case ready_frames(1, data) do
      {_ready, <<>>} -> receive_partial(socket)
      {_ready, _incomplete} -> :ok
    end
  end

  defp drain(_module, _socket, 0, <<>>, _first?, _corruption), do: :ok

  defp drain(module, socket, ready, buffer, first?, corruption) do
    {ready, buffer} = ready_frames(ready, buffer)

    if ready == 0 and buffer == <<>> do
      :ok
    else
      requested = if first? and corruption == :length, do: 1, else: required(buffer)
      timeout = if first? and corruption == :timeout, do: 60_000, else: :infinity
      {:ok, data} = apply(module, :recv, [socket, requested, timeout])
      drain(module, socket, ready, buffer <> data, false, corruption)
    end
  end

  # This fixture reads ReadyForQuery only. It does not use the comparator's
  # framing, typed decoder or association machine as its completion oracle.
  defp ready_frames(ready, <<tag, size::32, tail::binary>>)
       when size >= 4 and byte_size(tail) >= size - 4 do
    <<_payload::binary-size(size - 4), rest::binary>> = tail
    ready = if tag == ?Z, do: ready - 1, else: ready
    ready_frames(ready, rest)
  end

  defp ready_frames(ready, buffer), do: {ready, buffer}

  defp required(buffer) when byte_size(buffer) < 5, do: 0

  defp required(<<_tag, size::32, tail::binary>>),
    do: min(size - 4 - byte_size(tail), 64 * 1024 * 1024)
end
