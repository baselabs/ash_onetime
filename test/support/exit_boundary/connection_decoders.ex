defmodule AshOnetime.Test.ExitBoundary.ConnectionDecoders do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.ConnectionTypes
  alias AshOnetime.Test.ExitBoundary.NativeTransport
  alias AshOnetime.Test.ExitBoundary.Wire

  # Decoder buffers are copies of one physical connection's unconsumed bytes.
  # Their source is the native receive ledger and the pre-observation snapshot,
  # never the buffer or decoded result currently being checked. This ledger
  # grants no observation exemption.
  def build(indexed, native, streams, historical, origins \\ []) do
    replies = Map.new(native.reads ++ native.active, &{&1.returned.index, &1})
    cursors = Map.get_lazy(indexed, :connection_decoders, fn -> initial_cursors(historical) end)

    initial = %{
      ports: %{},
      cursors: cursors,
      initial_cursors: cursors,
      pending_cursors: %{},
      versions: [],
      timeline: [],
      descriptors:
        Map.merge(historical_descriptors(historical), owner_descriptors(origins, historical)),
      executing: %{},
      executions: [],
      query_inputs: %{},
      query_outputs: %{},
      query_params: %{},
      # Bind the loaded code version while the native owner is still installed.
      # A mutation's teardown may restore the module before copy validation.
      factory_identities: %{
        notify: Compiled.identity(Postgrex.Protocol, :"-notify/1-fun-0-", 2)
      },
      factory_observations: historical_factories(historical, indexed.events),
      instances: [],
      programs: [],
      native: native,
      replays: [],
      replay_sends: MapSet.new(),
      replay_receives: MapSet.new(),
      errors: [],
      events: Map.get(indexed, :connection_program_events, indexed.events),
      pairs: native.pairs,
      returns: Map.new(native.pairs, fn {index, pair} -> {pair.returned.index, index} end),
      streams: streams.connections
    }

    initial = Map.put(initial, :type_roots, Map.get(indexed, :connection_type_roots, %{}))

    saved = Map.get(indexed, :connection_decoder_program, %{})

    observations =
      Map.merge(Map.get(saved, :factory_observations, %{}), initial.factory_observations)

    initial = initial |> Map.merge(saved) |> Map.put(:factory_observations, observations)
    continuation = %{initial: initial, events: indexed.events, replies: replies}

    state = Enum.reduce(indexed.events, initial, &event(&1, &2, replies))
    state = decoder_programs(state)

    %{
      cursors: state.cursors,
      instances: Enum.reverse(state.instances),
      programs: Enum.reverse(state.programs),
      versions: Enum.reverse(state.versions),
      timeline: Enum.reverse(state.timeline),
      executions: Enum.reverse(state.executions),
      query_inputs: state.query_inputs,
      query_outputs: state.query_outputs,
      factory_identities: state.factory_identities,
      factory_observations: state.factory_observations,
      reload_factories:
        Map.new(historical, fn {pid, history} -> {pid, Map.get(history, :reload_factory)} end),
      protocol_copies: protocol_copies(indexed, historical),
      replays: Enum.reverse(state.replays),
      continuation: continuation,
      errors: Enum.reverse(state.errors)
    }
  end

  # Retain the actual reducer state before the cut, including open decoder
  # calls and their independently computed results. Native return terms and
  # the next capture's pair index are supplied only when those returns arrive.
  def checkpoint(%{continuation: input}, before) do
    input.events
    |> Enum.take_while(&(&1.index < before))
    |> Enum.reduce(input.initial, &event(&1, &2, input.replies))
    |> Map.drop([:native, :events, :pairs, :returns, :streams, :programs])
  end

  # Every direct event stays in this index, including arrivals and events that
  # do not belong to a decoder. A return carries its own frame on the captured
  # stack; remove exactly that frame when locating its caller's direct program.
  # The index changes neither the capture nor the whole-observation comparison.
  defp decoder_programs(state) do
    direct = Enum.group_by(state.events, &{&1.pid, direct_stack(&1)})

    context = %{
      state: state,
      direct: direct,
      instances: Map.new(state.instances, &{&1.source.index, &1}),
      ingress: decoder_ingress(state)
    }

    pairs =
      state.pairs
      |> Map.values()
      |> Enum.filter(fn pair ->
        pair.source.mfa in [
          {Postgrex.Protocol, :msg_recv, 3},
          {Postgrex.Protocol, :msg_recv, 4},
          {Postgrex.Protocol, :rows_recv, 4},
          {Postgrex.Protocol, :rows_recv, 5}
        ]
      end)
      |> Enum.sort_by(& &1.source.index, :desc)

    context = Map.put(context, :active_inputs, active_inputs(context, pairs))

    # Inner calls start later. Build each semantic result once, then use that
    # result in its callers without recursively walking the same program again.
    plans =
      Enum.reduce(pairs, %{}, fn pair, plans ->
        events = decoder_direct(context, pair)
        ingress = Enum.filter(events, &Map.has_key?(context.ingress, &1.index))
        execution = Enum.reject(events, &Map.has_key?(context.ingress, &1.index))

        {expected, terminal, origins} =
          decoder_branch(Map.put(context, :plans, plans), pair, execution)

        program = %{
          source: pair.source,
          returned: pair.returned,
          events: events,
          execution: execution,
          ingress: Enum.map(ingress, &Map.fetch!(context.ingress, &1.index)),
          origins: origins,
          expected: {expected, terminal}
        }

        Map.put(plans, pair.source.index, program)
      end)

    pairs
    |> Enum.reverse()
    |> Enum.reduce(state, fn pair, state ->
      program = Map.fetch!(plans, pair.source.index)

      actual =
        {Enum.map(program.execution, &program_event/1), program_terminal(pair.returned.event)}

      state = %{state | programs: [program | state.programs]}

      if decoder_program_equal?(actual, program.expected),
        do: state,
        else: failure(state, pair.source, :decoder_program, false)
    end)
  end

  defp direct_stack(%{event: {_, tag, mfa, _}, stack: [mfa | stack]})
       when tag in [:return_from, :exception_from],
       do: stack

  defp direct_stack(source), do: source.stack

  # An arrival is reported when it enters the mailbox, possibly before the
  # selective receive that consumes it. Its native source/copy proof owns its
  # position independently of the executing call stack. Keep every raw event
  # in the program and keep these exact ingress receipts in a separate lane;
  # they grant no allowance for any non-transport or later event.
  defp decoder_ingress(state) do
    active = for delivery <- state.native.active, do: delivery.returned
    passive = for delivery <- state.native.passive, do: delivery.received
    replay = for delivery <- state.replays, do: delivery.received
    Map.new(active ++ passive ++ replay, &{&1.index, &1})
  end

  defp active_inputs(context, pairs) do
    versions = Map.new(context.state.timeline, &{&1.index, &1})
    initial = context.state.initial_cursors

    active =
      for delivery <- context.state.native.active,
          %{cursor: cursor} <- [versions[delivery.returned.index]],
          span <- cursor.spans,
          span.index == delivery.returned.index,
          do: %{received: delivery.returned, start: span.offset, port: delivery.port}

    replay =
      for delivery <- context.state.replays,
          do: %{received: delivery.received, start: delivery.start, port: delivery.port}

    deliveries = Enum.sort_by(active ++ replay, & &1.received.index)

    {inputs, _used} =
      pairs
      |> Enum.reverse()
      |> Enum.reduce({%{}, MapSet.new()}, &active_input(&1, &2, context, initial, deliveries))

    inputs
  end

  defp active_input(pair, {inputs, used}, context, initial, deliveries) do
    events = decoder_direct(context, pair)

    if pair.source.mfa == {Postgrex.Protocol, :msg_recv, 3} and
         is_nil(direct_call(events, {Postgrex.Protocol, :msg_decode, 1})) do
      delivery = active_input_delivery(context, pair, events, initial, deliveries, used)
      bind_active_input(delivery, pair.source.index, inputs, used)
    else
      {inputs, used}
    end
  end

  defp active_input_delivery(context, pair, events, initial, deliveries, used) do
    {_, :call, {_, _, [protocol, _, _]}} = pair.source.event
    {module, socket} = protocol.sock
    tag = if module == :gen_tcp, do: :tcp, else: :ssl
    child = direct_call(events, {Postgrex.Protocol, :msg_recv, 3})
    port = NativeTransport.physical_port(context.state.native, protocol.sock)
    cursor = active_cursor(context, port, pair.source.index, initial)

    if child && cursor do
      Enum.find(deliveries, fn delivery ->
        eligible_active_delivery?(delivery, pair, child, cursor, {tag, socket, port}, used)
      end)
    end
  end

  defp active_cursor(context, socket, index, initial) do
    context.state.timeline
    |> Enum.filter(&(&1.port == socket and &1.index < index))
    |> Enum.max_by(& &1.index, fn -> nil end)
    |> case do
      %{cursor: cursor} -> cursor
      nil -> initial[socket]
    end
  end

  defp eligible_active_delivery?(delivery, pair, child, cursor, {tag, socket, port}, used) do
    received = delivery.received

    delivery.port == port and delivery.start >= cursor.offset and
      received.index < child.index and received.pid == pair.source.pid and
      not MapSet.member?(used, received.index) and
      match?({_, :receive, {^tag, ^socket, _}}, received.event)
  end

  defp bind_active_input(nil, _index, inputs, used), do: {inputs, used}

  defp bind_active_input(%{received: received}, index, inputs, used),
    do: {Map.put(inputs, index, received), MapSet.put(used, received.index)}

  defp decoder_program_equal?(actual, expected), do: actual === expected

  defp decoder_direct(context, pair) do
    context.direct
    |> Map.get({pair.source.pid, [pair.source.mfa | pair.source.stack]}, [])
    |> Enum.filter(&(&1.index > pair.source.index and &1.index < pair.returned.index))
  end

  # The control program uses independently decoded leaf results and actual
  # native receive returns. State/helper ledgers own the qualified coordinates
  # of each call and return; those checks remain necessary and are not repeated
  # here. This proof owns the full direct event sequence and terminal variant.
  defp decoder_branch(context, %{source: source} = pair, events) do
    case source.event do
      {_, :call, {Postgrex.Protocol, :msg_recv, [_, _, _]}} ->
        # The State ledger qualifies this branch's buffer argument. Use the
        # native receipt or leaf origin to retain the same program when a
        # source-copy control corrupts that argument before the callee restores
        # it; the State guard must remain its sole catcher.
        if direct_call(events, {Postgrex.Protocol, :msg_decode, 1}),
          do: leaf_program(context, pair, events, {Postgrex.Protocol, :msg_decode, 1}),
          else: active_program(context, pair, events)

      {_, :call, {Postgrex.Protocol, :rows_recv, [_, _, _, _]}} ->
        leaf_program(context, pair, events, {Postgrex.Types, :decode_rows, 4})

      {_, :call, {Postgrex.Protocol, function, _}} ->
        continuation_program(context, pair, events, function)
    end
  end

  defp leaf_program(context, _pair, events, mfa) do
    with %{index: index} <- direct_call(events, mfa),
         %{expected: result} <- context.instances[index] do
      prefix = program_call(mfa)

      leaf_result(context, events, mfa, result, prefix, index)
    else
      _ -> {[:missing_decoder_origin], :missing_decoder_origin, []}
    end
  end

  defp leaf_result(
         _context,
         _events,
         {Postgrex.Protocol, :msg_decode, 1},
         {:ok, _, _},
         prefix,
         index
       ),
       do: {prefix, {:return_from, :ok, 3}, [index]}

  defp leaf_result(
         context,
         events,
         {Postgrex.Protocol, :msg_decode, 1},
         {:more, _},
         prefix,
         index
       ),
       do: child_program(context, events, {Postgrex.Protocol, :msg_recv, 4}, prefix, [index])

  defp leaf_result(
         context,
         events,
         {Postgrex.Types, :decode_rows, 4},
         {:ok, _, _},
         prefix,
         index
       ) do
    # rows_msg/3 is an untraced pure bridge: exactly one msg_recv/3,
    # then the row accumulator accompanies that message in the return.
    {program, terminal, origins} =
      child_program(context, events, {Postgrex.Protocol, :msg_recv, 3}, prefix, [index])

    {program, row_terminal(terminal), origins}
  end

  defp leaf_result(
         context,
         events,
         {Postgrex.Types, :decode_rows, 4},
         {:more, _, _, _},
         prefix,
         index
       ),
       do: child_program(context, events, {Postgrex.Protocol, :rows_recv, 5}, prefix, [index])

  defp row_terminal({:return_from, :ok, 3}), do: {:return_from, :ok, 4}
  defp row_terminal(terminal), do: terminal

  defp continuation_program(context, pair, events, function) do
    {_, :call, {_, _, [protocol | _]}} = pair.source.event
    {module, _socket} = protocol.sock
    mfa = {module, :recv, 3}

    with %{index: index} <- direct_call(events, mfa),
         %{returned: %{event: {_, :return_from, ^mfa, result}}} <-
           context.state.pairs[index] do
      prefix = program_call(mfa)

      continuation_result(context, pair, events, function, result, prefix, index)
    else
      _ -> {[:missing_native_receive], :missing_native_receive, []}
    end
  end

  defp continuation_result(context, pair, events, function, {:ok, data}, prefix, index) do
    kind = if function == :msg_recv, do: :message, else: :rows

    case program_demand(context, pair.source, kind) do
      {:ok, more, origins} ->
        arity = continuation_arity(function, byte_size(data) < more)

        child_program(
          context,
          events,
          {Postgrex.Protocol, function, arity},
          prefix,
          [index | origins]
        )

      :error ->
        {prefix, :missing_decoder_demand, [index]}
    end
  end

  defp continuation_result(_context, _pair, _events, _function, {:error, _}, prefix, index),
    do: {prefix, {:return_from, :disconnect, 3}, [index]}

  defp continuation_arity(:msg_recv, true), do: 4
  defp continuation_arity(:msg_recv, false), do: 3
  defp continuation_arity(:rows_recv, true), do: 5
  defp continuation_arity(:rows_recv, false), do: 4

  defp program_demand(context, source, kind) do
    mfa =
      if kind == :message,
        do: {Postgrex.Protocol, :msg_decode, 1},
        else: {Postgrex.Types, :decode_rows, 4}

    instance =
      context.state.instances
      |> Enum.filter(fn instance ->
        instance.source.pid == source.pid and instance.source.mfa == mfa and
          instance.returned.index < source.index
      end)
      |> Enum.max_by(& &1.returned.index, fn -> nil end)

    with %{expected: expected} <- instance,
         {:more, more} <- program_remaining(expected) do
      reads =
        Enum.filter(context.state.native.reads, fn read ->
          read.port == instance.port and read.returned.pid == source.pid and
            read.returned.index > instance.returned.index and read.returned.index < source.index
        end)

      {:ok, more - Enum.sum(Enum.map(reads, &byte_size(&1.bytes))),
       [instance.returned.index | Enum.map(reads, & &1.returned.index)]}
    else
      _ -> :error
    end
  end

  defp program_remaining({:more, more}), do: {:more, more}
  defp program_remaining({:more, _, _, more}), do: {:more, more}
  defp program_remaining(_result), do: :error

  defp active_program(context, pair, events) do
    {_, :call, {_, _, [protocol, _, _]}} = pair.source.event
    {module, socket} = protocol.sock
    tag = if module == :gen_tcp, do: :tcp, else: :ssl

    received =
      Map.get(context.active_inputs, pair.source.index) ||
        Enum.find(events, &(elem(&1.event, 1) == :receive))

    active_message(received, context, events, tag, socket)
  end

  defp active_message(
         %{event: {_, :receive, {tag, socket, _}}, index: index},
         context,
         events,
         tag,
         socket
       ),
       do: child_program(context, events, {Postgrex.Protocol, :msg_recv, 3}, [], [index])

  defp active_message(
         %{event: {_, :receive, message}} = received,
         _context,
         _events,
         tag,
         socket
       ) do
    closed = if tag == :tcp, do: :tcp_closed, else: :ssl_closed
    error = if tag == :tcp, do: :tcp_error, else: :ssl_error

    case message do
      {^closed, ^socket} -> active_disconnect(received)
      {^error, ^socket, _reason} -> active_disconnect(received)
      :timeout -> active_disconnect(received)
      _ -> {[:unexpected_active_message], :unexpected_active_message, []}
    end
  end

  defp active_message(nil, _context, _events, _tag, _socket),
    do: {[:missing_active_origin], :missing_active_origin, []}

  defp active_disconnect(received),
    do: {[program_event(received)], {:return_from, :disconnect, 3}, [received.index]}

  defp child_program(context, events, mfa, prefix, origins) do
    case direct_call(events, mfa) do
      %{index: index} ->
        case context.plans[index] do
          %{expected: {_, terminal}, origins: child_origins} ->
            {prefix ++ program_call(mfa), terminal, origins ++ [index | child_origins]}

          nil ->
            {prefix ++ program_call(mfa), :missing_decoder_child, origins}
        end

      nil ->
        {prefix ++ program_call(mfa), :missing_decoder_child, origins}
    end
  end

  defp direct_call(events, mfa),
    do: Enum.find(events, &(&1.mfa == mfa and elem(&1.event, 1) == :call))

  defp program_call(mfa), do: [{:call, mfa}, {:return_from, mfa}]
  defp program_event(%{event: {_, :call, _}, mfa: mfa}), do: {:call, mfa}

  defp program_event(%{event: {_, tag, mfa, _}})
       when tag in [:return_from, :exception_from],
       do: {tag, mfa}

  defp program_event(source), do: source.event

  defp program_terminal({_, :return_from, _, result}) when is_tuple(result),
    do: {:return_from, elem(result, 0), tuple_size(result)}

  defp program_terminal(event), do: event

  # A local fun's name becomes [] after its code is unloaded. Freeze observed
  # metadata while the native owner is installed; expected identities still
  # come independently from that owner's object code and declared environment.
  def freeze_factories(events) do
    events
    |> Enum.flat_map(fn
      %{event: {_, :return_from, {Postgrex.Protocol, :notify, 1}, callback}}
      when is_function(callback) ->
        [callback]

      %{event: {_, :call, {:erlang, :spawn_monitor, [callback]}}}
      when is_function(callback) ->
        [callback]

      %{event: {_, :call, {Postgrex.Protocol, _, [_, %{notify: callback} | _]}}}
      when is_function(callback) ->
        [callback]

      _ ->
        []
    end)
    |> Enum.filter(&(Function.info(&1, :type) == {:type, :local}))
    |> Map.new(fn callback ->
      info = Map.new(Function.info(callback))
      identity = {info.module, info.name, info.arity, info.new_uniq, info.index}
      {callback, {:compiled_factory, identity, info.env}}
    end)
  end

  defp historical_factories(historical, events) do
    Enum.reduce(historical, freeze_factories(events), fn {_pid, history}, observations ->
      Map.merge(observations, Map.get(history, :factory_observations, %{}))
    end)
  end

  # A census of native coordinates, not a qualification or a projection. Each
  # Protocol occurrence needs its own version/origin rule before any buffer copy
  # can leave O5. Public SSL socket arguments/results remain opaque throughout.
  defp protocol_copies(indexed, historical) do
    sockets =
      for {_holder, %{protocol: %{sock: {:ssl, socket}}}} <- historical, do: socket

    opaque = MapSet.new(sockets ++ Enum.flat_map(indexed.events, &ssl_socket/1))

    for source <- indexed.events,
        {path, protocol} <- protocol_terms(source.event, [], opaque) do
      source
      |> Map.take([:index, :mfa, :role, :stack])
      |> Map.put(:tag, elem(source.event, 1))
      |> Map.put(:path, path)
      |> Map.put(:buffer_kind, buffer_kind(protocol.buffer))
    end
  end

  defp ssl_socket(%{event: {_, :call, {:ssl, function, [socket | _]}}})
       when function in [
              :send,
              :recv,
              :close,
              :sockname,
              :peername,
              :getopts,
              :setopts,
              :shutdown,
              :controlling_process,
              :connection_information,
              :peercert
            ],
       do: [socket]

  defp ssl_socket(%{event: {_, :return_from, {:ssl, function, _}, {:ok, socket}}})
       when function in [:connect, :transport_accept, :handshake],
       do: [socket]

  defp ssl_socket(_event), do: []

  defp protocol_terms(value, path, opaque) do
    if MapSet.size(opaque) == 0 or not MapSet.member?(opaque, value),
      do: protocol_term(value, path, opaque),
      else: []
  end

  defp protocol_term(%Postgrex.Protocol{} = protocol, path, _opaque), do: [{path, protocol}]

  defp protocol_term(value, path, opaque) when is_function(value) do
    {:env, environment} = Function.info(value, :env)
    protocol_terms(environment, path ++ [:function, :env], opaque)
  end

  defp protocol_term(value, path, opaque) when is_map(value) do
    Enum.flat_map(Map.to_list(value), fn {key, item} ->
      protocol_terms(key, path ++ [{:map_key, key}], opaque) ++
        protocol_terms(item, path ++ [key], opaque)
    end)
  end

  defp protocol_term(value, path, opaque) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> protocol_terms(item, path ++ [index], opaque) end)
  end

  defp protocol_term([_head | _tail] = list, path, opaque),
    do: protocol_list(list, path, opaque, 0)

  defp protocol_term(_value, _path, _opaque), do: []

  defp protocol_list([head | tail], path, opaque, index),
    do:
      protocol_terms(head, path ++ [index], opaque) ++
        protocol_list(tail, path, opaque, index + 1)

  defp protocol_list([], _path, _opaque, _index), do: []

  defp protocol_list(tail, path, opaque, index),
    do: protocol_terms(tail, path ++ [{:improper_tail, index}], opaque)

  defp buffer_kind(buffer) when is_binary(buffer), do: :bytes
  defp buffer_kind(buffer) when buffer in [nil, :active_once], do: buffer
  defp buffer_kind(_buffer), do: :invalid

  defp owner_descriptors(origins, historical) do
    for %{sock: socket, query: query} = origin <- origins,
        port = NativeTransport.physical_port(%{historical: historical}, socket),
        into: %{},
        do: {query.ref, Map.put(origin, :port, port)}
  end

  defp historical_descriptors(historical) do
    for {_holder, %{protocol: %{sock: socket} = protocol} = history} <- historical,
        port = NativeTransport.physical_port(%{historical: historical}, socket),
        origin <- Map.get(history, :descriptors, []),
        origin.port == port and origin.query.types === protocol.types,
        into: %{},
        do: {origin.query.ref, origin}
  end

  def initial_cursors(historical) do
    for {holder, %{protocol: %{sock: socket} = protocol}} <- historical,
        into: %{} do
      port = NativeTransport.physical_port(%{historical: historical}, socket)
      buffer = if is_binary(protocol.buffer), do: protocol.buffer, else: <<>>
      source = %{index: {:historical, holder}, path: [:protocol, :buffer], offset: 0}
      copies = [Map.put(source, :length, byte_size(buffer))]

      span = %{
        index: source.index,
        offset: 0,
        source_offset: 0,
        copies: copies,
        length: byte_size(buffer)
      }

      spans = if buffer == <<>>, do: [], else: [span]
      {port, %{buffer: buffer, offset: 0, rows: [], types: protocol.types, spans: spans}}
    end
  end

  defp event(e, state, replies) do
    state = commit_cursor(e, state)

    state =
      case Map.fetch(replies, e.index) do
        {:ok, %{bytes: bytes, port: port, copies: copies}} when is_binary(bytes) ->
          receive_bytes(state, e, port, bytes, copies)

        _ ->
          state
      end

    state = query_event(e, state)
    decoder_event(e, state)
  end

  defp query_event(
         %{event: {_, :call, {Postgrex.Protocol, function, _arguments}}} = source,
         state
       )
       when function in [
              :describe,
              :describe_params,
              :describe_result,
              :reload_describe_result,
              :redescribe,
              :recv_describe,
              :columns
            ] do
    case query_root(state, source) do
      %{query: query, protocol: protocol} = root ->
        port = NativeTransport.physical_port(state.native, protocol.sock)
        description = query_description(state, source, root, port)

        query =
          if function in [:describe, :describe_params],
            do: query,
            else: Map.get(state.query_params, root.index, query)

        input =
          Map.merge(description, %{
            query: query,
            types: protocol.types,
            root: root.index,
            pid: source.pid,
            parameter_accumulator: recv_parameter_input(state, source, root)
          })

        put_in(state.query_inputs[source.index], input)

      nil ->
        failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, :recv_describe, _}, {:ok, _, _, _, _, _, _}}
         } = source,
         state
       ) do
    case query_root(state, source) do
      %{query: query, protocol: protocol} = root ->
        port = NativeTransport.physical_port(state.native, protocol.sock)
        input = query_description(state, source, root, port)

        input =
          Map.merge(input, %{
            query: query,
            types: protocol.types,
            root: root.index,
            pid: source.pid
          })

        put_in(state.query_inputs[source.index], input)

      nil ->
        failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(
         %{event: {_, :return_from, {Postgrex.Protocol, function, _}, {:ok, actual}}} = source,
         state
       )
       when function in [:describe_params, :describe_result] do
    with %{source: call} <- returned_pair(state, source),
         {:ok, input} <- Map.fetch(state.query_inputs, call.index),
         {:ok, expected} <- query_factory(state, source, call, input, function) do
      _ = actual

      state =
        put_in(state.query_outputs[source.index], %{
          query: expected,
          origin: {call.index, input.origin},
          pid: source.pid
        })

      if function == :describe_params,
        do: put_in(state.query_params[input.root], expected),
        else: state
    else
      _ -> failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, function, _},
              {:ok, %Postgrex.Query{}, _protocol, _buffer}}
         } = source,
         state
       )
       when function in [:describe, :redescribe] do
    with %{source: call} <- returned_pair(state, source),
         %{query: query, origin: origin} <- earlier_query_factory(state, source, call.index) do
      put_in(state.query_outputs[source.index], %{query: query, origin: origin, pid: source.pid})
    else
      _ -> failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, :handle_prepare, 3},
              {:ok, %Postgrex.Query{}, _protocol}}
         } = source,
         state
       ) do
    with %{source: call} <- returned_pair(state, source),
         %{query: query, origin: origin} <-
           earlier_query_factory(state, source, call.index) || cached_query_origin(state, call) do
      put_in(state.query_outputs[source.index], %{query: query, origin: origin, pid: source.pid})
    else
      _ -> failure(state, source, :decoder_query_factory_origin, false)
    end
  end

  defp query_event(_source, state), do: state

  defp returned_pair(state, source) do
    state.pairs
    |> Map.values()
    |> Enum.find(&(&1.returned.index == source.index))
  end

  defp query_root(state, source) do
    state.pairs
    |> Map.values()
    |> Enum.filter(fn pair ->
      pair.source.pid == source.pid and pair.source.index < source.index and
        pair.returned.index > source.index and
        pair.source.mfa in [
          {Postgrex.Protocol, :handle_prepare, 3},
          {Postgrex.Protocol, :handle_execute, 4}
        ]
    end)
    |> Enum.max_by(& &1.source.index, fn -> nil end)
    |> case do
      %{
        source: %{
          index: index,
          event: {_, :call, {_, _, [%Postgrex.Query{} = query | arguments]}}
        }
      } ->
        %{query: query, protocol: List.last(arguments), index: index}

      _ ->
        nil
    end
  end

  defp query_description(state, source, root, port) do
    messages =
      state.instances
      |> Enum.filter(
        &(&1.port == port and &1.source.pid == source.pid and
            &1.source.index > root.index and &1.returned.index < source.index)
      )

    description =
      Enum.find(
        messages,
        &(match?({:ok, {:msg_row_desc, _}, _}, &1.expected) or
            match?({:ok, {:msg_no_data}, _}, &1.expected))
      )

    parameters = Enum.find(messages, &match?({:ok, {:msg_parameter_desc, _}, _}, &1.expected))

    {oids, mods, columns, fields, origin} = query_columns(description)
    param_oids = query_parameter_oids(parameters, root.query)

    %{
      result_oids: oids,
      result_mods: mods,
      columns: columns,
      fields: fields,
      param_oids: param_oids,
      origin: origin
    }
  end

  defp recv_parameter_input(state, source, root) do
    parent =
      state.pairs
      |> Map.values()
      |> Enum.filter(fn pair ->
        pair.source.pid == source.pid and pair.source.index < source.index and
          pair.returned.index > source.index and
          pair.source.mfa in [
            {Postgrex.Protocol, :recv_describe, 3},
            {Postgrex.Protocol, :recv_describe, 4}
          ]
      end)
      |> Enum.max_by(& &1.source.index, fn -> nil end)

    case parent do
      %{source: %{mfa: {Postgrex.Protocol, :recv_describe, 3}}} ->
        []

      %{source: owner} ->
        recv_parameter_oids(state, source, owner)

      nil ->
        root.query.param_oids || []
    end
  end

  defp recv_parameter_oids(state, source, owner) do
    parameters =
      state.instances
      |> Enum.filter(fn instance ->
        instance.source.pid == source.pid and instance.source.index > owner.index and
          instance.returned.index < source.index and
          match?({:ok, {:msg_parameter_desc, _}, _}, instance.expected)
      end)
      |> Enum.max_by(& &1.returned.index, fn -> nil end)

    case parameters do
      %{expected: {:ok, {:msg_parameter_desc, oids}, _}} -> oids
      nil -> Map.fetch!(state.query_inputs, owner.index).parameter_accumulator
    end
  end

  defp query_columns(%{expected: {:ok, {:msg_row_desc, fields}, _}, returned: returned}),
    do:
      {Enum.map(fields, &elem(&1, 4)), Enum.map(fields, &elem(&1, 6)),
       Enum.map(fields, &elem(&1, 1)), fields, returned.index}

  defp query_columns(%{expected: {:ok, {:msg_no_data}, _}, returned: returned}),
    do: {nil, nil, nil, nil, returned.index}

  defp query_columns(nil), do: {nil, nil, nil, nil, :no_description}

  defp query_parameter_oids(%{expected: {:ok, {:msg_parameter_desc, values}, _}}, _query),
    do: values

  defp query_parameter_oids(nil, query), do: query.param_oids || []

  defp query_factory(state, source, call, input, :describe_params) do
    with {:ok, infos} <- query_type_info(state, source, call) do
      {formats, types} = Enum.unzip(infos)

      {:ok,
       %{input.query | param_oids: input.param_oids, param_formats: formats, param_types: types}}
    end
  end

  defp query_factory(state, source, call, input, :describe_result) do
    references =
      for {_index, pair} <- state.pairs,
          pair.source.pid == source.pid,
          pair.source.index > call.index and pair.returned.index < source.index,
          pair.source.mfa == {:erlang, :make_ref, 0},
          {_, :return_from, _, ref} = pair.returned.event,
          do: ref

    with [ref] <- references,
         true <- is_reference(ref),
         {:ok, formats, types} <- query_result_types(state, source, call, input) do
      {:ok,
       %{
         input.query
         | ref: ref,
           types: input.types,
           columns: input.columns,
           result_oids: input.result_oids,
           result_formats: formats,
           result_types: types
       }}
    else
      _ -> :error
    end
  end

  defp query_result_types(_state, _source, _call, %{result_oids: nil}), do: {:ok, [], nil}

  defp query_result_types(state, source, call, input) do
    with {:ok, infos} <- query_type_info(state, source, call) do
      {formats, types} = Enum.unzip(infos)

      types =
        Enum.zip_with(types, input.result_mods, fn
          {extension, sub_oids, sub_types}, mod -> {extension, sub_oids, sub_types, mod}
          extension, mod -> {extension, mod}
        end)

      {:ok, formats, types}
    end
  end

  defp query_type_info(state, source, call) do
    input = Map.fetch!(state.query_inputs, call.index)
    oids = if elem(call.mfa, 1) == :describe_params, do: input.param_oids, else: input.result_oids

    pairs =
      state.pairs
      |> Map.values()
      |> Enum.filter(fn pair ->
        pair.source.pid == source.pid and pair.source.index > call.index and
          pair.returned.index < source.index and
          pair.source.mfa == {Postgrex.Types, :fetch, 2}
      end)
      |> Enum.sort_by(& &1.source.index)

    if length(pairs) == length(oids) do
      Enum.zip(pairs, oids)
      |> Enum.reduce_while({:ok, []}, fn {pair, oid}, {:ok, infos} ->
        query_type_step(state.pairs, pair, oid, input.types, infos)
      end)
      |> case do
        {:ok, infos} -> {:ok, Enum.reverse(infos)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp query_type_step(pairs, pair, oid, types, infos) do
    case ConnectionTypes.fetch(pairs, pair, oid, types) do
      {:ok, {:ok, info}, _origins} -> {:cont, {:ok, [info | infos]}}
      _ -> {:halt, :error}
    end
  end

  defp earlier_query_factory(state, source, first) do
    state.query_outputs
    |> Enum.filter(fn {index, query} ->
      index > first and index < source.index and query.pid == source.pid
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {_index, value} -> value
      nil -> nil
    end
  end

  defp cached_query_origin(state, %{
         event:
           {_, :call,
            {_, :handle_prepare, [%Postgrex.Query{cache: :statement} = query, _options, protocol]}}
       }) do
    matches =
      for {_ref, descriptor} <- state.descriptors,
          descriptor.port == NativeTransport.physical_port(state.native, protocol.sock),
          descriptor.query.name == query.name,
          descriptor.query.statement === query.statement,
          descriptor.query.types === protocol.types,
          do: descriptor

    case matches do
      [descriptor] ->
        %{query: descriptor.query, origin: {:cached_query, descriptor.index, descriptor.path}}

      _ ->
        nil
    end
  end

  defp cached_query_origin(_state, _call), do: nil

  defp commit_cursor(source, state) do
    call = Map.get(state.returns, source.index)

    case Map.pop(state.pending_cursors, call) do
      {nil, _pending} ->
        state

      {%{port: port, cursor: cursor, returned_buffer: buffer, instance: instance}, pending} ->
        version = %{index: source.index, port: port, cursor: cursor, returned_buffer: buffer}
        pair = Map.fetch!(state.pairs, call)
        consumed = instance.stop - instance.start
        remaining = byte_size(instance.tail)
        copies = buffer_copies(pair, consumed, remaining, instance.expected)
        instance = Map.merge(instance, %{returned: source, copies: copies})

        state
        |> exact(pair.source, :decoder_result, returned(pair), instance.expected)
        |> Map.put(:pending_cursors, pending)
        |> put_in([:cursors, port], cursor)
        |> Map.update!(:versions, &[version | &1])
        |> Map.update!(:timeline, &[Map.put(version, :kind, :decoder_return) | &1])
        |> Map.update!(:instances, &[instance | &1])
    end
  end

  defp receive_bytes(state, source, port, bytes, copies) do
    case Map.fetch(state.cursors, port) do
      {:ok, cursor} ->
        span = %{
          index: source.index,
          offset: cursor.offset + byte_size(cursor.buffer),
          source_offset: 0,
          copies: copies,
          length: byte_size(bytes)
        }

        cursor = %{cursor | buffer: cursor.buffer <> bytes, spans: cursor.spans ++ [span]}
        version = %{index: source.index, port: port, cursor: cursor, kind: :native_delivery}

        state
        |> put_in([:cursors, port], cursor)
        |> Map.update!(:timeline, &[version | &1])

      :error ->
        failure(state, source, :decoder_history, false)
    end
  end

  defp decoder_event(
         %{event: {_, :return_from, {Postgrex.TypeServer, :fetch, 1}, {:lock, _ref, _types}}} =
           source,
         state
       ) do
    port = state.ports[source.pid]

    case state.cursors[port] do
      %{types: nil} = cursor ->
        initialize_types(state, source, port, cursor)

      _ ->
        state
    end
  end

  defp decoder_event(
         %{event: {_, :return_from, {:gen_tcp, :connect, 4}, {:ok, port}}} = source,
         state
       ) do
    case returned_pair(state, source) do
      %{source: %{stack: stack}} ->
        if {Postgrex.Protocol, :connect, 1} in stack do
          cursor = %{buffer: <<>>, offset: 0, rows: [], types: nil, spans: []}
          version = %{index: source.index, port: port, cursor: cursor, kind: :connection_open}

          state
          |> exact(source, :decoder_connection_origin, Map.has_key?(state.cursors, port), false)
          |> put_in([:cursors, port], cursor)
          |> Map.update!(:timeline, &[version | &1])
        else
          state
        end

      _ ->
        state
    end
  end

  defp decoder_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, :redescribe, 6},
              {:ok, %Postgrex.Query{}, %{sock: socket}, _buffer}}
         } = e,
         state
       ) do
    port = NativeTransport.physical_port(state.native, socket)

    case state.query_outputs[e.index] do
      %{query: query} ->
        origin = %{query: query, port: port, index: e.index, path: [3, 1]}

        state
        |> put_in([:descriptors, query.ref], origin)
        |> put_in([:executing, port], origin)
        |> execution_version(e, port, origin)

      nil ->
        failure(state, e, :decoder_query_factory_origin, false)
    end
  end

  defp decoder_event(
         %{
           event:
             {_, :return_from, {Postgrex.Protocol, :handle_prepare, 3},
              {:ok, %Postgrex.Query{}, %{sock: socket}}}
         } = e,
         state
       ) do
    port = NativeTransport.physical_port(state.native, socket)

    case state.query_outputs[e.index] do
      %{query: expected} ->
        origin = %{query: expected, port: port, index: e.index, path: [3, 1]}
        put_in(state.descriptors[expected.ref], origin)

      nil ->
        failure(state, e, :decoder_query_factory_origin, false)
    end
  end

  defp decoder_event(
         %{event: {pid, :call, {Postgrex.Protocol, function, args}}} = e,
         state
       )
       when function in [
              :msg_recv,
              :rows_recv,
              :handle_prepare,
              :handle_execute,
              :handle_declare,
              :handle_fetch
            ] do
    protocol = List.last(args)
    protocol = if function in [:msg_recv, :rows_recv], do: hd(args), else: protocol

    case protocol do
      %{sock: socket} ->
        port = NativeTransport.physical_port(state.native, socket)
        state = put_in(state.ports[pid], port)

        starts_rows? = function in [:handle_execute, :handle_fetch]
        state = if starts_rows?, do: reset_rows(state, e, port), else: state

        state =
          if starts_rows?,
            do: executing(state, e, port, hd(args)),
            else: state

        if Map.has_key?(state.cursors, port),
          do: state,
          else: failure(state, e, :decoder_history, false)

      _ ->
        failure(state, e, :decoder_transport, false)
    end
  end

  defp decoder_event(
         %{event: {_, :call, {Postgrex.Protocol, :msg_decode, [buffer]}}} = e,
         state
       ),
       do: decode(e, buffer, :message, state)

  defp decoder_event(
         %{
           event: {_, :call, {Postgrex.Protocol, :activate, [%{sock: socket} = protocol, buffer]}}
         } = e,
         state
       )
       when is_binary(buffer) do
    port = NativeTransport.physical_port(state.native, socket)

    case Map.fetch(state.cursors, port) do
      {:ok, cursor} ->
        state = exact(state, e, :decoder_replay_buffer, buffer, cursor.buffer)

        if buffer == <<>>,
          do: state,
          else: replay(e, protocol, buffer, port, cursor, state)

      :error ->
        failure(state, e, :decoder_replay_origin, false)
    end
  end

  defp decoder_event(%{event: {pid, :send, {tag, _socket, _bytes}, pid}} = e, state)
       when tag in [:tcp, :ssl] do
    bound? = MapSet.member?(state.replay_sends, e.index)
    if bound?, do: state, else: failure(state, e, :decoder_replay_source, false)
  end

  defp decoder_event(
         %{event: {_, :call, {Postgrex.Types, :decode_rows, args}}} = e,
         state
       ) do
    [buffer, types, rows, type_state] = args
    decode(e, buffer, {:rows, types, rows, type_state}, state)
  end

  defp decoder_event(_event, state), do: state

  defp initialize_types(state, source, port, cursor) do
    with %{source: %{event: {_, :call, {_, _, [server]}}}} <- returned_pair(state, source),
         %{types: types} <- state.type_roots[server] do
      {_, :return_from, _, {:lock, _ref, actual}} = source.event
      state = exact(state, source, :decoder_type_origin, actual, types)
      cursor = %{cursor | types: types}
      version = %{index: source.index, port: port, cursor: cursor, kind: :type_lock}

      state
      |> put_in([:cursors, port], cursor)
      |> Map.update!(:timeline, &[version | &1])
    else
      _ -> failure(state, source, :decoder_type_origin, false)
    end
  end

  defp replay(e, protocol, buffer, port, cursor, state) do
    pair = Map.fetch!(state.pairs, e.index)
    pid = e.pid
    {module, socket} = protocol.sock
    tag = if module == :gen_tcp, do: :tcp, else: :ssl
    message = {tag, socket, buffer}

    program =
      Enum.filter(state.events, fn event ->
        event.pid == pid and event.index >= e.index and event.index <= pair.returned.index
      end)

    expected = [
      e.event,
      {pid, :call, {:erlang, :send, [pid, message]}},
      {pid, :send, message, pid},
      {pid, :return_from, {:erlang, :send, 2}, message},
      {pid, :return_from, {Postgrex.Protocol, :activate, 2}, {:ok, protocol}}
    ]

    state = exact(state, e, :decoder_replay_program, Enum.map(program, & &1.event), expected)

    received =
      Enum.find(state.events, fn event ->
        event.index > pair.returned.index and event.event === {pid, :receive, message} and
          not MapSet.member?(state.replay_receives, event.index)
      end)

    case {program, received} do
      {[_source, call, sent, returned, _stop], %{index: _index}} ->
        record_replay(
          e,
          pair,
          cursor,
          buffer,
          port,
          [call, sent, returned],
          received,
          state
        )

      _ ->
        failure(state, e, :decoder_replay_copy, false)
    end
  end

  defp record_replay(
         e,
         pair,
         cursor,
         buffer,
         port,
         [call, sent, returned],
         %{index: index} = received,
         state
       ) do
    size = byte_size(buffer)

    copies = [
      %{index: e.index, path: [2, 2, 1], offset: 0, length: size},
      %{index: call.index, path: [2, 2, 1, 2], offset: 0, length: size},
      %{index: sent.index, path: [2, 2], offset: 0, length: size},
      %{index: returned.index, path: [3, 2], offset: 0, length: size},
      %{index: received.index, path: [2, 2], offset: 0, length: size}
    ]

    replay = %{
      port: port,
      source: e,
      returned: pair.returned,
      received: received,
      start: cursor.offset,
      input: buffer,
      copies: copies,
      provenance: Wire.spans(cursor.spans, cursor.offset, cursor.offset + size)
    }

    state
    |> Map.update!(:replays, &[replay | &1])
    |> Map.update!(:replay_sends, &MapSet.put(&1, sent.index))
    |> Map.update!(:replay_receives, &MapSet.put(&1, index))
  end

  defp executing(state, e, port, %Postgrex.Query{} = query) do
    case Map.fetch(state.descriptors, query.ref) do
      {:ok, origin} ->
        state = exact(state, e, :decoder_query_copy, query, origin.query)

        state
        |> put_in([:executing, port], origin)
        |> execution_version(e, port, origin)

      _ ->
        failure(state, e, :decoder_query_origin, false)
    end
  end

  defp executing(state, _e, _port, _query), do: state

  defp execution_version(state, source, port, origin) do
    version = %{index: source.index, pid: source.pid, port: port, descriptor: origin}
    Map.update!(state, :executions, &[version | &1])
  end

  defp reset_rows(state, source, port) do
    case Map.fetch(state.cursors, port) do
      {:ok, cursor} ->
        cursor = %{cursor | rows: []}
        version = %{index: source.index, port: port, cursor: cursor, kind: :execution_start}

        state
        |> put_in([:cursors, port], cursor)
        |> Map.update!(:timeline, &[version | &1])

      :error ->
        state
    end
  end

  defp decode(e, buffer, kind, state) do
    with {:ok, port} <- Map.fetch(state.ports, e.pid),
         {:ok, cursor} <- Map.fetch(state.cursors, port),
         {:ok, pair} <- Map.fetch(state.pairs, e.index) do
      state = exact(state, e, :decoder_buffer, buffer, cursor.buffer)
      validate_result(pair, port, cursor, kind, state)
    else
      _ -> failure(state, e, :decoder_origin, false)
    end
  rescue
    _error in [ArgumentError, MatchError, KeyError, FunctionClauseError] ->
      failure(state, e, :decoder_protocol, false)
  end

  defp validate_result(pair, port, cursor, :message, state) do
    {expected, consumed} = message_result(cursor.buffer)
    retain(state, pair, port, cursor, consumed, cursor.rows, expected)
  end

  defp validate_result(pair, port, cursor, {:rows, types, rows, type_state}, state) do
    stream = Map.fetch!(state.streams, port)
    messages = Map.get(stream, :historical_messages, []) ++ stream.protocol.messages
    context = row_context(messages, cursor.offset)
    origin = Map.fetch!(state.executing, port)
    query = origin.query
    state = query_metadata(state, pair.source, query, context, cursor.types)
    expected_types = query.result_types
    state = exact(state, pair.source, :decoder_types, types, expected_types)
    state = exact(state, pair.source, :decoder_type_state, type_state, cursor.types)
    state = exact(state, pair.source, :decoder_rows, rows, cursor.rows)

    expected =
      Postgrex.Types.decode_rows(cursor.buffer, expected_types, cursor.rows, cursor.types)

    {rest, rows} = row_result(expected)
    consumed = byte_size(cursor.buffer) - byte_size(IO.iodata_to_binary(rest))
    state = retain(state, pair, port, cursor, consumed, rows, expected)

    update_in(
      state.pending_cursors[pair.source.index].instance,
      &Map.put(&1, :descriptor, Map.take(origin, [:index, :path]))
    )
  end

  defp message_result(<<tag, size::signed-32, bytes::binary>> = buffer)
       when size >= 4 and byte_size(bytes) >= size - 4 do
    length = size - 4
    <<payload::binary-size(^length), rest::binary>> = bytes
    message = Postgrex.Messages.parse(payload, tag, length)
    {{:ok, message, rest}, byte_size(buffer) - byte_size(rest)}
  end

  defp message_result(buffer) do
    {{:more, Wire.frame_remaining(buffer)}, 0}
  end

  defp row_context(messages, offset) do
    # Unsolicited messages have no command context. They remain in the stream;
    # the next associated backend message supplies this execution's descriptor.
    %{context: context} =
      Enum.find(messages, fn message ->
        message.direction == :backend and message.start >= offset and message.context != nil
      end)

    context
  end

  # Postgrex owns the decoder types, including modifiers and composite types.
  # Keep its prepared Query return as the origin; opaque values are only copied
  # and passed back to their owner. The independent wire catalog checks the
  # descriptor's statement, OIDs, column names and execution formats.
  defp query_metadata(state, source, query, context, types) do
    names =
      if context.description == :none, do: nil, else: Enum.map(context.columns, &elem(&1, 0))

    oids = if context.description == :none, do: nil, else: Enum.map(context.columns, &elem(&1, 3))
    formats = for {_, _, _, _, _, _, format} <- context.columns, do: format
    encodings = Enum.map(formats, &if(&1 == 1, do: :binary, else: :text))

    state
    |> exact(source, :decoder_statement, IO.iodata_to_binary(query.statement), context.sql)
    |> exact(source, :decoder_columns, query.columns, names)
    |> exact(source, :decoder_oids, query.result_oids, oids)
    |> exact(source, :decoder_formats, query.result_formats, encodings)
    |> exact(source, :decoder_query_types, query.types, types)
  end

  defp row_result({:ok, rows, rest}), do: {rest, rows}
  defp row_result({:more, rest, rows, _required}), do: {rest, rows}

  defp retain(state, pair, port, cursor, consumed, rows, expected) do
    remaining = byte_size(cursor.buffer) - consumed
    rest = binary_part(cursor.buffer, consumed, remaining)
    provenance = Wire.spans(cursor.spans, cursor.offset, cursor.offset + byte_size(cursor.buffer))

    instance = %{
      port: port,
      source: pair.source,
      start: cursor.offset,
      stop: cursor.offset + consumed,
      input: cursor.buffer,
      tail: rest,
      provenance: provenance,
      expected: expected
    }

    offset = cursor.offset + consumed
    spans = Enum.filter(cursor.spans, &(&1.offset + &1.length > offset))
    cursor = %{cursor | offset: offset, buffer: rest, rows: rows, spans: spans}
    # The paired return proves the result, but its cursor becomes available only
    # at that actual return event. Copies observed inside the decoder still see
    # the preceding version, even when another role interleaves there.
    returned_buffer =
      case expected do
        {:ok, _value, buffer} -> buffer
        {:more, buffer, _rows, _required} -> buffer
        {:more, _required} -> cursor.buffer
      end

    pending = %{port: port, cursor: cursor, returned_buffer: returned_buffer, instance: instance}
    put_in(state.pending_cursors[pair.source.index], pending)
  end

  defp buffer_copies(pair, consumed, remaining, expected) do
    output =
      case expected do
        {:ok, _message, _rest} -> [3, 2]
        {:more, _required} -> nil
        {:more, _rest, _rows, _required} -> [3, 1]
      end

    input = %{index: pair.source.index, path: [2, 2, 0], offset: 0, length: consumed + remaining}
    copies = [input]

    if output,
      do: copies ++ [%{index: pair.returned.index, path: output, offset: 0, length: remaining}],
      else: copies
  end

  defp returned(%{returned: %{event: {_, :return_from, _, result}}}), do: result
  defp returned(_pair), do: :missing_decoder_return

  defp exact(state, _source, _rule, actual, expected) when actual === expected, do: state
  defp exact(state, source, rule, _actual, _expected), do: failure(state, source, rule, false)

  defp failure(state, source, rule, actual) do
    error = %{
      index: source.index,
      at: Map.take(source, [:mfa, :role, :stack]),
      rule: rule,
      actual: actual,
      expected: true
    }

    %{state | errors: [error | state.errors]}
  end
end
