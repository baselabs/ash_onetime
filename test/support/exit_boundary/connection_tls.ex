defmodule AshOnetime.Test.ExitBoundary.ConnectionTls do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.NativeTransport

  # The SSL socket stays opaque. Match its public endpoint pair to the unique
  # live TCP port and retain the port's actual connected owner before observation.
  def bind(socket) do
    {:ok, local} = :ssl.sockname(socket)
    {:ok, peer} = :ssl.peername(socket)

    [port] =
      for port <- Port.list(),
          Port.info(port, :name) == {:name, ~c"tcp_inet"},
          :inet.sockname(port) == {:ok, local},
          :inet.peername(port) == {:ok, peer},
          do: port

    {:connected, owner} = Port.info(port, :connected)
    {:links, links} = Process.info(owner, :links)
    linked = process_origins(links)

    [supervisor] =
      for %{pid: pid, mfa: {:supervisor, :tls_dyn_connection_sup, 1}} <- linked, do: pid

    children = :supervisor.which_children(supervisor)
    {:receiver, ^owner, :worker, _modules} = List.keyfind(children, :receiver, 0)
    {:sender, sender, :worker, [:tls_sender]} = List.keyfind(children, :sender, 0)

    %{
      socket: socket,
      port: port,
      owner: owner,
      local: local,
      peer: peer,
      supervisor: supervisor,
      sender: sender,
      processes: process_origins([owner, sender, supervisor])
    }
  end

  defp process_origins(pids) do
    for pid <- Enum.uniq(pids), is_pid(pid) do
      mfa =
        case :proc_lib.translate_initial_call(pid) do
          {module, function, arity}
          when is_atom(module) and is_atom(function) and is_integer(arity) ->
            {module, function, arity}

          _ ->
            :unknown_initial_call
        end

      %{pid: pid, mfa: mfa}
    end
  end

  def validate(binding) do
    local = :ssl.sockname(binding.socket)
    peer = :ssl.peername(binding.socket)
    transport_local = :inet.sockname(binding.port)
    transport_peer = :inet.peername(binding.port)
    owner = Port.info(binding.port, :connected)
    local_matches? = local == transport_local and local == {:ok, binding.local}

    []
    |> mismatch(:tls_local_endpoint, local_matches?)
    |> mismatch(:tls_peer_endpoint, peer == transport_peer and peer == {:ok, binding.peer})
    |> mismatch(:tls_transport_owner, owner == {:connected, binding.owner})
    |> mismatch(:tls_connection_workers, connection_workers?(binding))
  end

  defp connection_workers?(binding) do
    children = :supervisor.which_children(binding.supervisor)

    match?(
      {:receiver, owner, :worker, _} when owner == binding.owner,
      List.keyfind(children, :receiver, 0)
    ) and List.keyfind(children, :sender, 0) == {:sender, binding.sender, :worker, [:tls_sender]}
  catch
    :exit, _reason -> false
  end

  # Only the public SSL send/recv arguments and returns are PostgreSQL bytes.
  # Encrypted port data never enters the framing or protocol association machine.
  # This ledger grants no event allowance; native interior/copy qualification and
  # the main comparator's consumption remain separate obligations.
  def build(indexed, binding) do
    pairs = NativeTransport.pairs(indexed.events)

    state =
      Enum.reduce(indexed.events, %{pairs: pairs, writes: [], reads: [], errors: []}, fn
        %{event: {_, :call, {:ssl, :send, [socket, data]}}} = source, state
        when socket == binding.socket ->
          write(state, source, binding.port, IO.iodata_to_binary(data))

        %{event: {_, :call, {:ssl, :recv, [socket, length, timeout]}}} = source, state
        when socket == binding.socket ->
          read(state, source, binding.port, length, timeout)

        %{event: {_, :call, {:ssl, function, _arguments}}} = source, state
        when function in [:send, :recv] ->
          %{state | errors: [{source.index, :tls_socket_source} | state.errors]}

        _, state ->
          state
      end)

    helper = sender_copies(indexed.events, pairs, binding)

    %{
      pairs: pairs,
      writes: Enum.reverse(state.writes),
      reads: Enum.reverse(state.reads),
      active: [],
      historical: %{},
      terms: Enum.reverse(helper.terms),
      errors: Enum.reverse(state.errors) ++ Enum.reverse(helper.errors)
    }
  end

  defp sender_copies(events, pairs, binding) do
    Enum.reduce(events, %{terms: [], errors: []}, fn
      %{event: {pid, :call, {:tls_sender, :send_application_data, arguments}}} = source, state
      when pid == binding.sender ->
        sender_copy(state, source, arguments, pairs)

      _source, state ->
        state
    end)
  end

  defp sender_copy(state, source, [data, from, :connection, actual], pairs) do
    parent =
      pairs
      |> Map.values()
      |> Enum.filter(fn pair ->
        pair.source.pid == source.pid and pair.source.mfa == {:tls_sender, :connection, 3} and
          pair.source.index < source.index and pair.returned.index > source.index
      end)
      |> Enum.max_by(& &1.source.index, fn -> nil end)

    case parent do
      %{source: %{event: {_, :call, {_, _, [{:call, expected_from},
        {:application_data, expected_data}, expected]}}} = origin} ->
        state
        |> tls_copy(source, [2, 2, 0], data, expected_data, origin.index)
        |> tls_copy(source, [2, 2, 1], from, expected_from, origin.index)
        |> tls_copy(source, [2, 2, 3], actual, expected, origin.index)

      _ ->
        tls_failure(state, source, :tls_state_origin)
    end
  end

  defp sender_copy(state, source, _arguments, _pairs),
    do: tls_failure(state, source, :tls_state_origin)

  defp tls_copy(state, source, path, actual, expected, origin) do
    state = tls_exact(state, source, :tls_state_copy, actual, expected)
    copy = %{index: source.index, path: path, origin: {:tls_callback, origin}}
    Map.update!(state, :terms, &[copy | &1])
  end

  defp tls_exact(state, _source, _rule, actual, expected) when actual === expected, do: state
  defp tls_exact(state, source, rule, _actual, _expected), do: tls_failure(state, source, rule)

  defp tls_failure(state, source, rule) do
    error = %{
      index: source.index,
      at: Map.take(source, [:mfa, :role, :stack]),
      rule: rule,
      actual: false,
      expected: true
    }
    Map.update!(state, :errors, &[error | &1])
  end

  defp write(state, source, port, bytes) do
    case Map.fetch(state.pairs, source.index) do
      {:ok, %{returned: %{event: {_, :return_from, {:ssl, :send, 2}, :ok}} = returned}} ->
        write = %{
          source: source,
          command: source,
          returned: returned,
          port: port,
          bytes: bytes,
          header_size: 0,
          copies: [copy(source, [2, 2, 1], bytes)]
        }

        %{state | writes: [write | state.writes]}

      _ ->
        %{state | errors: [{source.index, :tls_write_return} | state.errors]}
    end
  end

  defp read(state, source, port, length, timeout) do
    case Map.fetch(state.pairs, source.index) do
      {:ok, %{returned: %{event: {_, :return_from, {:ssl, :recv, 3}, {:ok, bytes}}} = returned}}
      when is_binary(bytes) ->
        read = %{
          source: source,
          returned: returned,
          delivered: returned,
          port: port,
          length: length,
          timeout: timeout,
          result: {:ok, bytes},
          bytes: bytes,
          provenance: source.index,
          copies: [copy(returned, [3, 1], bytes)]
        }

        %{state | reads: [read | state.reads]}

      _ ->
        %{state | errors: [{source.index, :tls_read_return} | state.errors]}
    end
  end

  defp copy(source, path, bytes),
    do: %{index: source.index, path: path, offset: 0, length: byte_size(bytes)}

  defp mismatch(errors, _rule, true), do: errors
  defp mismatch(errors, rule, false), do: errors ++ [rule]
end
