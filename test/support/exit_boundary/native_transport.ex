defmodule AshOnetime.Test.ExitBoundary.NativeTransport do
  @moduledoc false
  @control_magic 0x03F1A300

  # Validate the concrete inet driver program of each read independently. This
  # ledger does not grant any event exemption: the stream consumer must also prove
  # that framing and the protocol state machine required that particular read.
  def build(indexed, historical \\ %{}, transports \\ []) do
    pairs = pairs(indexed.events)

    initial = %{
      pairs: pairs,
      events: indexed.events,
      reads: [],
      writes: [],
      options: [],
      active: [],
      active_modes: Map.merge(historical_modes(historical), transport_modes(transports)),
      active_receives: %{},
      errors: []
    }

    state =
      Enum.reduce(indexed.events, initial, fn
        %{event: {_, :call, {:gen_tcp, :recv, [port, length, timeout]}}} = source, state
        when is_port(port) ->
          read(source, port, length, timeout, state)

        %{event: {_, :call, {:gen_tcp, :send, [port, data]}}} = source, state
        when is_port(port) ->
          write(source, port, data, state)

        %{event: {_, :call, {:prim_inet, :setopts, [port, [active: mode]]}}} = source, state
        when is_port(port) and (mode in [:once, false] or is_integer(mode)) ->
          option(source, port, mode, state)

        _, state ->
          state
      end)

    state = option_sources(state)
    state = active_deliveries(state)

    %{
      pairs: pairs,
      reads: Enum.reverse(state.reads),
      writes: Enum.reverse(state.writes),
      options: Enum.reverse(state.options),
      active: Enum.reverse(state.active),
      historical: historical,
      errors: Enum.reverse(state.errors)
    }
  end

  defp historical_modes(historical) do
    for {holder, %{protocol: %{sock: {:gen_tcp, port}, buffer: :active_once}}} <- historical,
        into: %{},
        do: {port, %{mode: :once, origin: {:historical_active_mode, holder}}}
  end

  defp transport_modes(transports) do
    for %{port: port, active: mode} <- transports,
        is_port(port) and (mode in [:once, true, false] or (is_integer(mode) and mode > 0)),
        into: %{},
        do: {port, %{mode: mode, origin: {:historical_transport_option, port}}}
  end

  defp option_sources(state) do
    Enum.reduce(state.events, state, &option_source/2)
  end

  defp option_source(
         %{event: {_, :call, {:erts_internal, :port_control, [port, command, data]}}} = source,
         state
       )
       when is_port(port) and command == @control_magic + 7 do
    case IO.iodata_to_binary(data) do
      <<22, _::binary>> ->
        bound? = Enum.any?(state.options, &(source.index in &1.indexes))
        if bound?, do: state, else: failure(state, source, :native_option_source)

      _ ->
        state
    end
  end

  defp option_source(_source, state), do: state

  defp active_deliveries(state) do
    modes = for option <- state.options, do: {option.requested.index, :mode, option}

    data =
      for %{event: {port, :send, {:tcp, port, _bytes}, _pid}} = source <- state.events,
          is_port(port),
          do: {source.index, :data, source}

    (modes ++ data)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(state, &active_event/2)
  end

  defp active_event({_index, :mode, option}, state) do
    current = Map.get(state.active_modes, option.port, %{mode: false}).mode

    mode =
      if is_integer(option.mode) do
        previous = if is_integer(current), do: current, else: 0
        count = previous + option.mode
        if count > 0, do: count, else: false
      else
        option.mode
      end

    put_in(state.active_modes[option.port], %{option | mode: mode})
  end

  defp active_event({_index, :data, source}, state) do
    case Map.fetch(state.active_modes, source.pid) do
      {:ok, %{mode: mode} = option}
      when mode in [:once, true] or (is_integer(mode) and mode > 0) ->
        active_delivery(source, option, state)

      _ ->
        failure(state, source, :native_active_mode)
    end
  end

  defp active_delivery(
         %{event: {port, :send, {:tcp, port, bytes}, pid}} = source,
         option,
         state
       ) do
    expected = {pid, :receive, {:tcp, port, bytes}}

    received =
      Enum.find(state.events, fn event ->
        event.index > source.index and event.event === expected and
          not Map.has_key?(state.active_receives, event.index)
      end)

    with %{index: index} <- received,
         true <- is_binary(bytes) and byte_size(bytes) > 0 do
      delivery = %{
        port: port,
        source: source,
        returned: received,
        delivered: source,
        activation: option,
        bytes: bytes,
        indexes: [source.index, index],
        copies: [
          copy(source, [2, 2], 0, byte_size(bytes)),
          copy(received, [2, 2], 0, byte_size(bytes))
        ]
      }

      state
      |> put_in([:active_modes, port], %{option | mode: after_delivery(option.mode)})
      |> put_in([:active_receives, index], true)
      |> Map.update!(:active, &[delivery | &1])
    else
      _ -> failure(state, source, :native_active_copy)
    end
  end

  defp after_delivery(:once), do: false
  defp after_delivery(true), do: true
  defp after_delivery(1), do: false
  defp after_delivery(count) when is_integer(count) and count > 1, do: count - 1

  # The once fast path and the passive enum path have different native programs.
  # Build each from the option supplied to this instance, including every helper
  # argument and return. No helper's result is inferred from a different call.
  defp option(source, port, mode, state) do
    encoded = option_bytes(mode)
    args = [port, @control_magic + 7, encoded]

    with {:ok, outer} <- Map.fetch(state.pairs, source.index),
         {:ok, :ok} <- return_value(outer),
         {:ok, internal} <- unique_call(state, outer, {:erts_internal, :port_control, 3}, args),
         {:ok, [1], deferred} <- driver_reply(state, outer, internal, port),
         {:ok, native_return} <- return_value(internal),
         {:ok, signals} <- option_controls(state.events, outer, port, encoded),
         events <- in_interval(state.events, outer, &(&1.pid == source.pid)),
         calls <- Enum.flat_map(events, &program_event/1),
         :ok <- option_events(calls, option_program(port, mode, encoded, native_return)) do
      indexes = for event <- events, program_event(event) != [], do: event.index

      option = %{
        port: port,
        mode: mode,
        source: source,
        returned: outer.returned,
        requested: signals.requested,
        replied: signals.replied,
        indexes: indexes ++ signals.indexes ++ deferred,
        copies: [copy(signals.requested, [2, 1, 1, 1], 0, IO.iodata_length(encoded))],
        bytes: IO.iodata_to_binary(encoded)
      }

      %{state | options: [option | state.options]}
    else
      {:error, reason} -> failure(state, source, reason)
      _ -> failure(state, source, :native_option_program)
    end
  end

  defp option_bytes(:once), do: [<<22, 2::32>>]
  defp option_bytes(false), do: [22, [0, 0, 0, 0]]
  defp option_bytes(count), do: [<<22, 3::32, count::signed-16>>]

  defp option_events(calls, expected) when calls === expected, do: :ok

  defp option_events(calls, expected) do
    positions = 0..max(length(calls), length(expected))
    n = Enum.find(positions, &(Enum.at(calls, &1) != Enum.at(expected, &1)))

    diagnostic = %{
      position: n,
      actual: program_signature(Enum.at(calls, n)),
      expected: program_signature(Enum.at(expected, n))
    }

    {:error, {:native_option_program, diagnostic}}
  end

  defp program_signature({:call, {m, f, args}}), do: {:call, {m, f, length(args)}}
  defp program_signature({tag, mfa, _result}), do: {tag, mfa}
  defp program_signature(nil), do: :absent

  defp option_controls(events, outer, port, encoded) do
    pid = outer.source.pid
    command = @control_magic + 7
    bytes = IO.iodata_to_binary(encoded)

    requests =
      in_interval(events, outer, fn
        %{event: {^port, :receive, {^pid, {:control, _}}}} -> true
        _ -> false
      end)

    replies =
      in_interval(events, outer, fn
        %{event: {^port, :send, {^port, {:control, _}}, ^pid}} -> true
        _ -> false
      end)

    with [%{event: {_, :receive, {_, {:control, {^command, ^bytes}}}}} = requested] <- requests,
         [%{event: {_, :send, {_, {:control, <<1>>}}, _}} = replied] <- replies,
         true <- requested.index < replied.index do
      {:ok, %{requested: requested, replied: replied, indexes: [requested.index, replied.index]}}
    else
      _ -> {:error, :native_option_control}
    end
  end

  defp option_program(port, mode, encoded, native_return) do
    args = [port, @control_magic + 7, encoded]
    internal = program(:erts_internal, :port_control, args, native_return)
    erlang = program(:erlang, :port_control, args, [1], internal)
    control = program(:prim_inet, :ctl_cmd, [port, 7, encoded], {:ok, []}, erlang)
    encoder = option_encoder(mode, encoded)
    program(:prim_inet, :setopts, [port, [active: mode]], :ok, encoder ++ control)
  end

  defp option_encoder(mode, encoded) when mode == :once or is_integer(mode) do
    tail = program(:prim_inet, :enc_opt_val, [[], encoded], encoded)
    body = program(:prim_inet, :enc_opt_val, [[active: mode], []], encoded, tail)
    program(:prim_inet, :encode_opt_val, [[active: mode]], {:ok, encoded}, body)
  end

  defp option_encoder(false, encoded) do
    type = {:enum, [{false, 0}, {true, 1}, {:once, 2}, {:multi, 3}]}
    table = elem(type, 1)
    enum = program(:prim_inet, :enum_val, [false, table], {:value, 0})
    lookup = program(:prim_inet, :type_opt_1, [:active], type)
    lookup = program(:prim_inet, :type_opt, [:set, :active], type, lookup)
    check = program(:prim_inet, :type_value_2, [type, false], true, enum)

    check =
      Enum.reduce([:type_value_1, :type_value_default, :type_value], check, fn function, child ->
        program(:prim_inet, function, [:set, type, false], true, child)
      end)

    value = program(:prim_inet, :enc_value_2, [type, false], [0, 0, 0, 0], enum)

    value =
      Enum.reduce([:enc_value_1, :enc_value_default, :enc_value], value, fn function, child ->
        program(:prim_inet, function, [:set, type, false], [0, 0, 0, 0], child)
      end)

    name = program(:prim_inet, :enc_opt, [:active], 22)
    tail = program(:prim_inet, :enc_opt_val, [[], encoded], encoded)

    body =
      program(
        :prim_inet,
        :enc_opt_val,
        [[], [], :active, false],
        encoded,
        lookup ++ check ++ name ++ value ++ tail
      )

    body = program(:prim_inet, :enc_opt_val, [[active: false], []], encoded, body)
    program(:prim_inet, :encode_opt_val, [[active: false]], {:ok, encoded}, body)
  end

  defp program(module, function, args, result, children \\ []) do
    [{:call, {module, function, args}}] ++
      children ++
      [{:return_from, {module, function, length(args)}, result}]
  end

  defp program_event(%{event: {_, :call, mfa}}), do: [{:call, mfa}]

  defp program_event(%{event: {_, tag, mfa, result}})
       when tag in [:return_from, :exception_from],
       do: [{tag, mfa, result}]

  defp program_event(_event), do: []

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
         {:ok, driver} <- write_driver(state, outer, port, send4.data, command),
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
         copies: write_copies(outer, send3, send4, driver.pairs, command, byte_size(bytes)),
         indexes:
           Enum.uniq(
             [command.index | signals] ++
               driver.signals ++
               Enum.flat_map(pairs, &[&1.source.index, &1.returned.index])
           )
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :native_write_program}
    end
  end

  defp write_copies(outer, send3, send4, driver, command, size) do
    plain = for pair <- [outer, send3], do: copy(pair.source, [2, 2, 1], 0, size)

    encoded =
      for pair <- [send4.pair | driver],
          do: copy(pair.source, [2, 2, 1], send4.header_size, size)

    plain ++ encoded ++ [copy(command, [2, 1, 1], send4.header_size, size)]
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

  defp write_driver(state, outer, port, data, command) do
    args = [port, data, []]

    with {:ok, erlang} <- unique_call(state, outer, {:erlang, :port_command, 3}, args),
         {:ok, internal} <- unique_call(state, outer, {:erts_internal, :port_command, 3}, args),
         {:ok, true} <- return_value(erlang),
         {:ok, signals} <- command_result(state.events, outer, internal, port, command) do
      {:ok, %{pairs: [erlang, internal], signals: signals}}
    end
  end

  defp command_result(events, outer, internal, port, command) do
    case return_value(internal) do
      {:ok, true} ->
        {:ok, []}

      {:ok, ref} when is_reference(ref) ->
        case deferred_receive(events, outer, internal, port, ref) do
          {:ok, true, received} when command.index < received.index -> {:ok, [received.index]}
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

  def pairs(events) do
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
        control_request: chain.requested,
        control_reply: chain.replied,
        copies: read_copies(chain.returned, signals, bytes),
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
         {:ok, controls} <- read_controls(state.events, outer, internal, driver_args, id),
         {:ok, ^result} <- return_value(recv0),
         {:ok, ^result} <- return_value(recv) do
      pairs = [outer, socket, recv, recv0, async, time, ctl, erlang, internal]

      if program_order?(pairs) do
        {:ok,
         %{
           id: id,
           started: internal.source.index,
           origin: internal.returned.index,
           requested: controls.requested,
           replied: controls.replied,
           returned: Enum.map([outer, recv, recv0], & &1.returned),
           indexes:
             controls.indexes ++
               deferred ++ Enum.flat_map(pairs, &[&1.source.index, &1.returned.index])
         }}
      else
        {:error, :native_program_order}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :native_receive_program}
    end
  end

  defp read_copies(_returned, _signals, nil), do: []

  defp read_copies(returned, signals, bytes) do
    size = byte_size(bytes)
    results = for source <- returned, do: copy(source, [3, 1], 0, size)

    results ++
      [copy(signals.sent, [2, 3, 1], 0, size), copy(signals.received, [2, 3, 1], 0, size)]
  end

  defp copy(source, path, offset, size),
    do: %{index: source.index, path: path, offset: offset, length: size}

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
         true <- chain.requested.index < sent.index,
         true <- outer.returned.index > received.index do
      {:ok, %{sent: sent, received: received, indexes: [received.index, sent.index]}}
    else
      _ ->
        diagnostic = receive_diagnostic(state.events, outer, chain, port, result)
        {:error, {:native_receive_copy, diagnostic}}
    end
  end

  defp receive_diagnostic(events, outer, chain, port, result) do
    pid = outer.source.pid

    signals =
      in_interval(events, outer, fn e ->
        e.pid in [pid, port] and elem(e.event, 1) in [:send, :receive]
      end)
      |> Enum.map(&receive_signal(&1, pid, port, chain.id, result))

    %{
      source: outer.source.index,
      returned: outer.returned.index,
      control_origin: chain.origin,
      control_started: chain.started,
      id: chain.id,
      result: receive_result(result),
      signals: signals
    }
  end

  defp receive_signal(%{event: {port, :send, message, pid}, index: index}, pid, port, id, result),
    do: signal_metadata(index, :sent, message, port, id, result)

  defp receive_signal(%{event: {pid, :receive, message}, index: index}, pid, port, id, result),
    do: signal_metadata(index, :received, message, port, id, result)

  defp receive_signal(
         %{event: {port, :receive, {pid, {:control, {command, bytes}}}}, index: index},
         pid,
         port,
         _id,
         _result
       )
       when is_integer(command) and is_binary(bytes),
       do: %{index: index, kind: :control_request, command: command, bytes: byte_size(bytes)}

  defp receive_signal(%{event: event, index: index}, _pid, _port, _id, _result),
    do: %{index: index, kind: elem(event, 1), own_endpoint?: false}

  defp signal_metadata(index, kind, {:inet_async, port, id, value}, port, expected_id, result),
    do: %{
      index: index,
      kind: kind,
      message: :inet_async,
      id: id,
      own_id?: id == expected_id,
      exact_copy?: value === result,
      result: receive_result(value)
    }

  defp signal_metadata(index, kind, {port, {:control, bytes}}, port, _id, _result)
       when is_binary(bytes),
       do: %{index: index, kind: kind, message: :control, bytes: byte_size(bytes)}

  defp signal_metadata(index, kind, message, _port, _id, _result)
       when is_tuple(message) and tuple_size(message) > 0,
       do: %{index: index, kind: kind, tuple_size: tuple_size(message)}

  defp signal_metadata(index, kind, _message, _port, _id, _result),
    do: %{index: index, kind: kind, message: :other}

  defp receive_result({:ok, bytes}) when is_binary(bytes), do: {:ok, :binary, byte_size(bytes)}
  defp receive_result({:ok, bytes}) when is_list(bytes), do: {:ok, :list, length(bytes)}
  defp receive_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp receive_result(_result), do: :other

  defp read_controls(events, outer, internal, [port, command, data], id) do
    pid = outer.source.pid

    requests =
      in_interval(events, outer, fn
        %{event: {^port, :receive, {^pid, {:control, _}}}} ->
          true

        _ ->
          false
      end)

    replies =
      in_interval(events, outer, fn
        %{event: {^port, :send, {^port, {:control, _}}, ^pid}} ->
          true

        _ ->
          false
      end)

    with [%{event: {_, :receive, {_, {:control, {^command, bytes}}}}} = requested] <- requests,
         true <- bytes === IO.iodata_to_binary(data),
         [%{event: {_, :send, {_, {:control, <<1, hi, lo>>}}, _}} = replied] <- replies,
         true <- id == hi * 256 + lo,
         true <- internal.source.index < requested.index,
         true <- requested.index < replied.index,
         true <- replied.index < outer.returned.index do
      {:ok,
       %{
         requested: requested,
         replied: replied,
         indexes: [requested.index, replied.index]
       }}
    else
      _ ->
        signals =
          (requests ++ replies)
          |> Enum.sort_by(& &1.index)
          |> Enum.map(&receive_signal(&1, pid, port, id, :control))

        diagnostic = %{id: id, started: internal.source.index, signals: signals}
        {:error, {:native_control_copy, diagnostic}}
    end
  end

  defp driver_reply(state, outer, internal, port) do
    case return_value(internal) do
      {:ok, [1 | _] = reply} ->
        {:ok, reply, []}

      {:ok, ref} when is_reference(ref) ->
        deferred_reply(state.events, outer, internal, port, ref)

      _ ->
        {:error, :native_control_origin}
    end
  end

  defp deferred_reply(events, outer, internal, port, ref) do
    pid = outer.source.pid

    with {:ok, reply, received} <- deferred_receive(events, outer, internal, port, ref),
         true <- is_list(reply) or is_binary(reply),
         bytes <- IO.iodata_to_binary(reply),
         [sent] <-
           in_interval(
             events,
             outer,
             &(&1.event == {port, :send, {port, {:control, bytes}}, pid})
           ),
         true <- sent.index < received.index do
      {:ok, reply, [received.index, sent.index]}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :native_deferred_control_copy}
    end
  end

  # Scheduled port operations queue their reference reply inside the VM. The
  # caller's receive is bound to that operation's returned reference, while the
  # driver command/control and its actual trace copies are checked separately.
  defp deferred_receive(events, outer, internal, port, ref) do
    pid = outer.source.pid

    with [received] <-
           in_interval(events, outer, fn
             %{event: {^pid, :receive, {^ref, _}}} -> true
             _ -> false
           end),
         {_, :receive, {^ref, reply}} <- received.event,
         true <- internal.returned.index < received.index do
      {:ok, reply, received}
    else
      _ ->
        signals =
          Enum.flat_map(events, fn
            %{event: {^pid, :receive, {^ref, reply}}, index: index} ->
              [%{index: index, kind: :receive, result: control_result(reply)}]

            %{event: {sender, :send, {^ref, reply}, ^pid}, index: index} ->
              signal = %{index: index, kind: :send, own_port?: sender == port}
              [Map.put(signal, :result, control_result(reply))]

            _ ->
              []
          end)

        diagnostic = %{start: outer.source.index, stop: outer.returned.index, signals: signals}
        {:error, {:native_deferred_receive, diagnostic}}
    end
  end

  defp control_result(value) when is_list(value), do: {:list, length(value)}
  defp control_result(value) when is_binary(value), do: {:binary, byte_size(value)}
  defp control_result(value) when is_atom(value), do: value
  defp control_result(_value), do: :other

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
        returned_pair(state.pairs, index, outer.returned.index, mfa)

      _ ->
        {:error, {:native_call, mfa}}
    end
  end

  defp returned_pair(pairs, index, stop, mfa) do
    case Map.fetch(pairs, index) do
      {:ok, %{returned: %{index: returned}} = pair} when returned <= stop -> {:ok, pair}
      {:ok, _pair} -> {:error, {:native_return_order, mfa}}
      :error -> {:error, {:native_missing_return, mfa}}
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
    rule =
      case source.mfa do
        {:gen_tcp, :send, 2} -> :native_write
        {:prim_inet, :setopts, 2} -> :native_option
        {:erts_internal, :port_control, 3} -> :native_option
        _ -> :native_receive
      end

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
