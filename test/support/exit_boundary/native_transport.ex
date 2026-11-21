defmodule AshOnetime.Test.ExitBoundary.NativeTransport do
  @moduledoc false
  @control_magic 0x03F1A300

  # Validate the concrete inet driver program of each read independently. This
  # ledger does not grant any event exemption: the stream consumer must also prove
  # that framing and the protocol state machine required that particular read.
  def build(indexed) do
    pairs = call_pairs(indexed.events)
    initial = %{pairs: pairs, events: indexed.events, reads: [], writes: [], errors: []}

    state =
      Enum.reduce(indexed.events, initial, fn
        %{event: {_, :call, {:gen_tcp, :recv, [port, length, timeout]}}} = source, state
        when is_port(port) ->
          read(source, port, length, timeout, state)

        %{event: {_, :call, {:gen_tcp, :send, [port, data]}}} = source, state
        when is_port(port) ->
          write(source, port, data, state)

        _, state ->
          state
      end)

    %{
      reads: Enum.reverse(state.reads),
      writes: Enum.reverse(state.writes),
      errors: Enum.reverse(state.errors)
    }
  end

  defp write(source, port, data, state) do
    with {:ok, outer} <- Map.fetch(state.pairs, source.index),
         {:ok, :ok} <- return_value(outer),
         {:ok, transfer} <- write_chain(state, outer, port, data) do
      write = Map.merge(transfer, %{source: source, returned: outer.returned, port: port})
      %{state | writes: [write | state.writes]}
    else
      {:error, reason} -> failure(state, source, reason)
      _ -> failure(state, source, :native_write_program)
    end
  end

  defp write_chain(state, outer, port, data) do
    bytes = IO.iodata_to_binary(data)

    with {:ok, monitor} <- unique_call(state, outer, {:erlang, :monitor, 2}, [:port, port]),
         {:ok, ref} <- return_value(monitor),
         true <- is_reference(ref),
         {:ok, send3} <- unique_call(state, outer, {:prim_inet, :send, 3}, [port, data, []]),
         {:ok, :ok} <- return_value(send3),
         {:ok, send4} <- write_send(state, outer, port, ref, bytes),
         {:ok, command} <- write_command(state.events, outer, port, send4.data),
         {:ok, driver} <- write_driver(state, outer, port, send4.data),
         {:ok, signals} <- write_signals(state.events, outer, port, ref),
         {:ok, demonitor} <-
           unique_call(state, outer, {:erlang, :demonitor, 2}, [ref, [:flush]]),
         {:ok, true} <- return_value(demonitor),
         true <-
           write_order?([outer, send3, monitor, send4.pair, demonitor | driver.pairs], command) do
      pairs = [outer, monitor, send3, send4.pair, demonitor | driver.pairs]

      {:ok,
       %{
         bytes: bytes,
         reference: ref,
         header_size: send4.header_size,
         command: command,
         indexes:
           Enum.uniq(
             [command.index | signals] ++ driver.signals ++
               Enum.flat_map(pairs, &[&1.source.index, &1.returned.index])
           )
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :native_write_program}
    end
  end

  defp write_order?([outer, send3, monitor, send4, demonitor, erlang, internal], command) do
    nested = [
      {outer, send3},
      {send3, monitor},
      {send3, send4},
      {send4, erlang},
      {erlang, internal},
      {send4, demonitor}
    ]

    monitor.returned.index < send4.source.index and
      command.index > internal.source.index and command.index < demonitor.source.index and
      Enum.all?(nested, fn {parent, child} ->
        parent.source.index < child.source.index and child.returned.index < parent.returned.index
      end)
  end

  defp write_send(state, outer, port, ref, bytes) do
    pid = outer.source.pid

    sends =
      in_interval(state.events, outer, fn
        %{event: {^pid, :call, {:prim_inet, :send, [^port, _, [], ^ref]}}} -> true
        _ -> false
      end)

    with [%{index: index, event: {_, :call, {_, _, [_, data, [], _]}}}] <- sends,
         <<size::16, encoded::binary-size(size), ^bytes::binary>> <- IO.iodata_to_binary(data),
         {^ref, ^size} <- :erlang.binary_to_term(encoded, [:safe, :used]),
         {:ok, pair} <- Map.fetch(state.pairs, index),
         {:ok, :ok} <- return_value(pair) do
      {:ok, %{data: data, pair: pair, header_size: size + 2}}
    else
      _ -> {:error, :native_write_header}
    end
  rescue
    ArgumentError -> {:error, :native_write_header}
  end

  defp write_command(events, outer, port, data) do
    pid = outer.source.pid
    bytes = IO.iodata_to_binary(data)

    commands =
      in_interval(events, outer, fn
        %{event: {^port, :receive, {^pid, {:command, _}}}} -> true
        _ -> false
      end)

    case commands do
      [%{event: {_, :receive, {_, {:command, copy}}}} = command] ->
        if IO.iodata_to_binary(copy) === bytes,
          do: {:ok, command},
          else: {:error, :native_write_copy}

      _ ->
        {:error, :native_write_multiplicity}
    end
  end

  defp write_driver(state, outer, port, data) do
    args = [port, data, []]

    with {:ok, erlang} <- unique_call(state, outer, {:erlang, :port_command, 3}, args),
         {:ok, internal} <- unique_call(state, outer, {:erts_internal, :port_command, 3}, args),
         {:ok, true} <- return_value(erlang),
         {:ok, signals} <- command_result(state.events, outer, internal, port) do
      {:ok, %{pairs: [erlang, internal], signals: signals}}
    end
  end

  defp command_result(events, outer, internal, port) do
    case return_value(internal) do
      {:ok, true} ->
        {:ok, []}

      {:ok, ref} when is_reference(ref) ->
        case deferred_reply(events, outer, ref, port) do
          {:ok, true, signals} -> {:ok, signals}
          _ -> {:error, :native_deferred_write}
        end

      _ ->
        {:error, :native_write_result}
    end
  end

  defp write_signals(events, outer, port, ref) do
    pid = outer.source.pid
    message = {:inet_reply, port, :ok, ref}

    with [sent] <- in_interval(events, outer, &(&1.event == {port, :send, message, pid})),
         [received] <- in_interval(events, outer, &(&1.event == {pid, :receive, message})),
         true <- sent.index < received.index do
      {:ok, [sent.index, received.index]}
    else
      _ -> {:error, :native_write_reply}
    end
  end

  defp call_pairs(events) do
    {_pending, pairs} = Enum.reduce(events, {%{}, %{}}, &pair_event/2)
    pairs
  end

  defp pair_event(%{event: {pid, :call, {m, f, args}}} = e, {pending, pairs}) do
    key = {pid, {m, f, length(args)}}
    {Map.update(pending, key, [e], &[e | &1]), pairs}
  end

  defp pair_event(%{event: {pid, tag, mfa, _}} = e, {pending, pairs})
       when tag in [:return_from, :exception_from] do
    key = {pid, mfa}

    case Map.get(pending, key, []) do
      [source | rest] ->
        pair = %{source: source, returned: e}
        {Map.put(pending, key, rest), Map.put(pairs, source.index, pair)}

      [] ->
        {pending, pairs}
    end
  end

  defp pair_event(_event, state), do: state

  defp read(source, port, length, timeout, state) do
    with {:ok, outer} <- Map.fetch(state.pairs, source.index),
         {:ok, result} <- return_value(outer),
         {:ok, bytes} <- receive_bytes(result),
         {:ok, chain} <- read_chain(state, outer, port, length, timeout, result),
         {:ok, signals} <- read_signals(state, outer, chain, port, result) do
      read = %{
        source: source,
        returned: outer.returned,
        port: port,
        length: length,
        timeout: timeout,
        bytes: bytes,
        result: result,
        id: chain.id,
         delivered: signals.sent,
         received: signals.received,
         indexes: Enum.uniq(chain.indexes ++ signals.indexes),
        provenance: chain.origin
      }

      %{state | reads: [read | state.reads]}
    else
      {:error, reason} -> failure(state, source, reason)
      :error -> failure(state, source, :missing_native_return)
    end
  end

  defp receive_bytes({:ok, bytes}) when is_binary(bytes), do: {:ok, bytes}
  defp receive_bytes({:error, reason}) when is_atom(reason), do: {:ok, nil}
  defp receive_bytes(_result), do: {:error, :native_receive_result}

  defp read_chain(state, outer, port, length, timeout, result) do
    native_timeout = if timeout == :infinity, do: -1, else: timeout
    control = [uint32(native_timeout), uint32(length)]
    native_args = [port, length, native_timeout]
    driver_args = [port, @control_magic + 42, control]

    with {:ok, socket} <- unique_call(state, outer, {:erlang, :port_get_data, 1}, [port]),
         {:ok, module} <- return_value(socket),
         true <- module in [:inet_tcp, :inet6_tcp, :local_tcp],
         {:ok, recv} <-
           unique_call(state, outer, {:prim_inet, :recv, 3}, [port, length, timeout]),
         {:ok, recv0} <- unique_call(state, outer, {:prim_inet, :recv0, 3}, native_args),
         {:ok, async} <- unique_call(state, outer, {:prim_inet, :async_recv, 3}, native_args),
         {:ok, time} <- unique_call(state, outer, {:prim_inet, :enc_time, 1}, [native_timeout]),
         {:ok, expected_time} <- return_value(time),
         true <- expected_time === uint32(native_timeout),
         {:ok, ctl} <- unique_call(state, outer, {:prim_inet, :ctl_cmd, 3}, [port, 42, control]),
         {:ok, erlang} <- unique_call(state, outer, {:erlang, :port_control, 3}, driver_args),
         {:ok, internal} <-
           unique_call(state, outer, {:erts_internal, :port_control, 3}, driver_args),
         {:ok, reply, deferred} <- driver_reply(state, outer, internal, port),
         [1, hi, lo] <- reply,
         {:ok, ^reply} <- return_value(erlang),
         {:ok, {:ok, [^hi, ^lo]}} <- return_value(ctl),
         {:ok, {:ok, id}} <- return_value(async),
         true <- id == hi * 256 + lo,
         {:ok, ^result} <- return_value(recv0),
         {:ok, ^result} <- return_value(recv) do
      pairs = [outer, socket, recv, recv0, async, time, ctl, erlang, internal]

      if program_order?(pairs) do
        {:ok,
         %{
           id: id,
           origin: internal.returned.index,
           indexes: deferred ++ Enum.flat_map(pairs, &[&1.source.index, &1.returned.index])
         }}
      else
        {:error, :native_program_order}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :native_receive_program}
    end
  end

  defp program_order?([outer, socket, recv, recv0, async, time, ctl, erlang, internal]) do
    nested = [
      {outer, socket},
      {outer, recv},
      {recv, recv0},
      {recv0, async},
      {async, time},
      {async, ctl},
      {ctl, erlang},
      {erlang, internal}
    ]

    socket.returned.index < recv.source.index and time.returned.index < ctl.source.index and
      Enum.all?(nested, fn {parent, child} ->
        parent.source.index < child.source.index and child.returned.index < parent.returned.index
      end)
  end

  defp read_signals(state, outer, chain, port, result) do
    pid = outer.source.pid
    id = chain.id
    message = {:inet_async, port, id, result}

    with [received] <- in_interval(state.events, outer, &(&1.event == {pid, :receive, message})),
         [sent] <- in_interval(state.events, outer, &(&1.event == {port, :send, message, pid})),
         true <- sent.index < received.index,
         true <- chain.origin < received.index,
         true <- outer.returned.index > received.index,
         {:ok, controls} <- control_signals(state.events, outer, port, id, pid) do
      {:ok, %{sent: sent, received: received, indexes: [received.index, sent.index | controls]}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :native_receive_copy}
    end
  end

  defp control_signals(events, outer, port, id, pid) do
    controls =
      in_interval(events, outer, fn
        %{event: {^port, :send, {^port, {:control, _}}, ^pid}} ->
          true

        _ ->
          false
      end)

    case controls do
      [] ->
        {:ok, []}

      [%{event: {_, :send, {_, {:control, <<1, hi, lo>>}}, _}} = control]
      when id == hi * 256 + lo ->
        {:ok, [control.index]}

      [_] ->
        {:error, :native_control_copy}

      _ ->
        {:error, :duplicate_native_control}
    end
  end

  defp driver_reply(state, outer, internal, port) do
    case return_value(internal) do
      {:ok, [1, _, _] = reply} -> {:ok, reply, []}
      {:ok, ref} when is_reference(ref) -> deferred_reply(state.events, outer, ref, port)
      _ -> {:error, :native_control_origin}
    end
  end

  defp deferred_reply(events, outer, ref, port) do
    pid = outer.source.pid

    with [received] <-
           in_interval(events, outer, fn
             %{event: {^pid, :receive, {^ref, _}}} -> true
             _ -> false
           end),
         {_, :receive, {^ref, reply}} <- received.event,
         [sent] <- in_interval(events, outer, &(&1.event == {port, :send, {ref, reply}, pid})),
         true <- sent.index < received.index do
      {:ok, reply, [received.index, sent.index]}
    else
      _ -> {:error, :native_deferred_control}
    end
  end

  defp unique_call(state, outer, mfa, expected_args) do
    pid = outer.source.pid
    {module, function, arity} = mfa

    candidates =
      in_interval(state.events, outer, fn
        %{event: {^pid, :call, {^module, ^function, args}}} -> length(args) == arity
        _ -> false
      end)

    case candidates do
      [%{event: {_, :call, {_, _, ^expected_args}}, index: index}] ->
        case Map.fetch(state.pairs, index) do
          {:ok, pair} ->
            if pair.returned.index <= outer.returned.index,
              do: {:ok, pair},
              else: {:error, {:native_return_order, mfa}}

          :error ->
            {:error, {:native_missing_return, mfa}}
        end

      _ ->
        {:error, {:native_call, mfa}}
    end
  end

  defp in_interval(events, outer, predicate) do
    Enum.filter(events, fn e ->
      e.index >= outer.source.index and e.index <= outer.returned.index and predicate.(e)
    end)
  end

  defp return_value(%{returned: %{event: {_, :return_from, _, value}}}), do: {:ok, value}
  defp return_value(_pair), do: {:error, :native_exception}

  defp uint32(value) do
    <<bytes::binary-size(4)>> = <<value::signed-32>>
    :binary.bin_to_list(bytes)
  end

  defp failure(state, source, reason) do
    rule = if source.mfa == {:gen_tcp, :send, 2}, do: :native_write, else: :native_receive

    error = %{
      index: source.index,
      at: Map.take(source, [:mfa, :role, :stack]),
      rule: rule,
      actual: reason,
      expected: :own_complete_native_program
    }

    %{state | errors: [error | state.errors]}
  end
end
