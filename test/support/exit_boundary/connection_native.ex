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

  # The server prepares this statement before observation. Its actual description
  # is retained independently of the later Bind and DataRow being checked.
  def observe_prepared do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect()
          send(observer, {tag, prepare_history(protocol)})
          protocol
        end,
        &execute(&1, :prepared, nil),
        %{host: [], callbacks: []}
      )

    receive do
      {^tag, history} -> %{run: run, history: history}
    after
      0 -> raise "native prepared history was not captured"
    end
  end

  defp connect do
    options = Keyword.put(Repo.config(), :types, Postgrex.DefaultTypes)
    {:ok, protocol} = Postgrex.Protocol.connect(options)
    {:ok, protocol} = Postgrex.Protocol.checkout(protocol)
    protocol
  end

  defp execute(%{sock: {:gen_tcp, socket}}, :incomplete, nil) do
    :ok = :inet.setopts(socket, buffer: 4096, recbuf: 8192)
    :ok = :gen_tcp.send(socket, query_sql("SELECT repeat('x', 1048576)"))
    receive_partial(socket)
  after
    :ok = :gen_tcp.close(socket)
  end

  defp execute(%{sock: {module, socket}}, :prepared, nil) do
    bind = <<0, "native_prepared", 0, 1::16, 1::16, 1::16, 4::32, 17::signed-32, 1::16, 1::16>>
    :ok = module.send(socket, [message(?B, bind), message(?E, <<0, 0::32>>), message(?S, <<>>)])
    drain(module, socket, 1, <<>>, true, nil)
  after
    :ok = module.close(socket)
  end

  defp execute(%{sock: {module, socket}}, mode, corruption) do
    values = values(mode, corruption)
    messages = Enum.map(values, &query/1)
    :ok = module.send(socket, messages)
    :ok = drain(module, socket, length(values), <<>>, true, corruption)

    if corruption == :extra_read do
      {:error, :timeout} = module.recv(socket, 0, 0)
    end

    :ok
  after
    :ok = module.close(socket)
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

  defp prepare_history(%{sock: {module, socket}}) do
    sql = "SELECT $1::int4 AS connection_stream_probe"
    parse = message(?P, <<"native_prepared", 0, sql::binary, 0, 1::16, 23::32>>)
    describe = message(?D, <<?S, "native_prepared", 0>>)
    bytes = IO.iodata_to_binary([parse, describe, message(?S, <<>>)])
    :ok = module.send(socket, bytes)
    chunks = [%{index: 0, direction: :frontend, bytes: bytes}]
    %{port: socket, chunks: history_replies(module, socket, 1, <<>>, chunks)}
  end

  defp history_replies(module, socket, ready, buffer, chunks) do
    {ready, buffer} = ready_frames(ready, buffer)

    if ready == 0 and buffer == <<>> do
      Enum.reverse(chunks)
    else
      {:ok, bytes} = module.recv(socket, required(buffer), :infinity)
      chunk = %{index: length(chunks), direction: :backend, bytes: bytes}
      history_replies(module, socket, ready, buffer <> bytes, [chunk | chunks])
    end
  end

  defp message(tag, payload), do: <<tag, byte_size(payload) + 4::32, payload::binary>>

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
      {:ok, data} = module.recv(socket, requested, timeout)
      drain(module, socket, ready, buffer <> data, false, corruption)
    end
  end

  # This fixture reads ReadyForQuery only. It does not use the comparator's
  # framing, typed decoder or association machine as its completion oracle.
  defp ready_frames(ready, <<tag, size::32, tail::binary>>)
       when size >= 4 and byte_size(tail) >= size - 4 do
    payload_size = size - 4
    <<_payload::binary-size(^payload_size), rest::binary>> = tail
    ready = if tag == ?Z, do: ready - 1, else: ready
    ready_frames(ready, rest)
  end

  defp ready_frames(ready, buffer), do: {ready, buffer}

  defp required(buffer) when byte_size(buffer) < 5, do: 0

  defp required(<<_tag, size::32, tail::binary>>),
    do: min(size - 4 - byte_size(tail), 64 * 1024 * 1024)
end
