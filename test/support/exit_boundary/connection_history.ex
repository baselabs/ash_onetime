defmodule AshOnetime.Test.ExitBoundary.ConnectionHistory do
  @moduledoc false
  use GenServer

  alias AshOnetime.Test.ExitBoundary.ConnectionDecoders
  alias AshOnetime.Test.ExitBoundary.ConnectionReads
  alias AshOnetime.Test.ExitBoundary.ConnectionStates
  alias AshOnetime.Test.ExitBoundary.ConnectionTls
  alias AshOnetime.Test.ExitBoundary.ConnectionTypes
  alias AshOnetime.Test.ExitBoundary.NativeTransport
  alias AshOnetime.Test.ExitBoundary.Wire

  import Postgrex.Messages,
    only: [msg_parameter_desc: 1, msg_row_desc: 1, msg_no_data: 0, row_field: 1]

  @native_functions [
    handle_prepare: 3,
    handle_prepare_execute: 4,
    recv_parse_describe: 4,
    redescribe: 6,
    msg_recv: 3,
    msg_recv: 4
  ]

  # Start before the fixture opens its pools. Only successful native prepare
  # returns and their own server descriptions can create a historical descriptor.
  # Opaque decoder types are retained as the Query their owner returned.
  def start_link(options) do
    owner = Keyword.fetch!(options, :owner)
    GenServer.start_link(__MODULE__, owner, Keyword.delete(options, :owner))
  end

  def snapshot(kind \\ :origins) when kind in [:origins, :preparations] do
    GenServer.call(__MODULE__, {:snapshot, kind}, 30_000)
  end

  def traced?(pid), do: GenServer.call(__MODULE__, {:traced, pid})

  def function_coverage, do: GenServer.call(__MODULE__, :function_coverage)

  # Loading native owner code clears that code's local trace breakpoints. The
  # owner loaders rearm this same session before any query uses the new code.
  # Standalone native peers do not run the fixture application or this history.
  def owner_loaded(Postgrex.Protocol) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      owner -> GenServer.call(owner, :owner_loaded)
    end
  end

  def owner_loaded(_module), do: :ok

  # Build one authoritative history for the complete raw capture, before origin
  # pairing, scheduling moves or interval selection.
  def build(side) do
    historical = side.historical

    indexed = %{
      events:
        side.run.events
        |> Enum.with_index(Map.get(historical, :event_offset, 0))
        |> Enum.map(fn {event, index} -> Map.put_new(event, :index, index) end),
      query_cache: historical.query_cache,
      connection_decoders: historical.connection_decoders,
      connection_owners: Map.get(historical, :connection_owners, %{}),
      connection_holder_origins:
        Map.get(historical, :connection_holder_origins, historical.connections),
      connection_decoder_program: Map.get(historical, :connection_decoder_program, %{}),
      connection_state_program: Map.get(historical, :connection_state_program, %{})
    }

    indexed = Map.put(indexed, :connection_services, side.run.snapshot.services || %{})

    # Earlier real records finish the validation of calls that cross the cut.
    # They remain program evidence; this observation retains its own events
    # and source indexes for origins and the whole comparison.
    program_events = Map.get(historical, :connection_program_events, []) ++ indexed.events
    indexed = Map.put(indexed, :connection_program_events, program_events)
    program = %{indexed | events: program_events}
    roots = Map.get(historical, :connection_native_roots, historical.connections)

    initial_state = side.run.initial_state

    native =
      program
      |> native_history(roots, side.run.tls_bindings || [])
      |> Map.put(:historical, historical.connections)
      |> Map.put(:connection_roots, roots)
      |> Map.put(:event_offset, Map.get(historical, :event_offset, 0))
      |> Map.put(:connection_framing, historical.connection_framing)

    types = ConnectionTypes.history(program, native.pairs, indexed.connection_services)
    type_roots = types.roots
    indexed = Map.put(indexed, :connection_type_roots, type_roots)

    # This labels exact frontend writes for statement ordinals only. It grants
    # no event allowance. Backend ownership remains the protocol machine's exact
    # request association; Readback must independently prove the complete call.
    readback =
      for write <- native.writes,
          {AshOnetime.Store, :committed_completion, 2} in write.source.stack,
          into: MapSet.new(),
          do: write.command.index

    reads = ConnectionReads.build(native, readback, historical.connection_protocols)

    decoders =
      ConnectionDecoders.build(
        indexed,
        native,
        reads,
        historical.connections,
        historical.query_origins
      )

    states =
      ConnectionStates.build(
        indexed,
        native,
        decoders,
        historical.connections,
        {:initial, initial_state}
      )

    errors =
      Enum.map(
        native.errors ++ types.errors ++ reads.errors ++ decoders.errors ++ states.errors,
        fn
          %{index: index} = error when is_integer(index) ->
            error

          error ->
            connection = Map.fetch!(reads.connections, error.port)
            offset = Map.get(error, :offset)

            frame =
              Enum.find(connection.framing.messages, &(&1.start == offset)) ||
                List.last(connection.framing.messages)

            index =
              if frame do
                frame.provenance |> Enum.map(& &1.index) |> Enum.max()
              else
                (native.writes ++ native.reads ++ native.active)
                |> Enum.filter(&(&1.port == error.port))
                |> Enum.sort_by(& &1.source.index)
                |> List.last()
                |> Map.fetch!(:source)
                |> Map.fetch!(:index)
              end

            source = Enum.find(program_events, &(&1.index == index))

            %{
              index: index,
              at: Map.take(source, [:mfa, :role, :stack]),
              rule: error.rule,
              actual: Map.get(error, :actual, Map.take(error, [:direction, :offset, :received])),
              expected: Map.get(error, :expected, :complete_protocol_frame)
            }
        end
      )

    %{
      indexed: indexed,
      program_events: program_events,
      native_roots: roots,
      native: native,
      types: types,
      reads: reads,
      decoders: decoders,
      states: states,
      errors: errors
    }
  end

  # A rendering is a view of this exact whole proof. Its stream addresses use
  # the original physical port; they introduce no identity map. Only complete,
  # successful native receive programs can leave the ordinary event sequence.
  # Writes and events outside those receive programs keep their occurrences.
  def render(proof, indexed) do
    errors =
      proof.errors ++
        proof.native.errors ++
        proof.reads.errors ++
        proof.decoders.errors ++
        proof.states.errors

    cond do
      errors != [] ->
        %{events: indexed.events, consumed: MapSet.new(), errors: Enum.uniq(errors)}

      indexed.events !== proof.indexed.events ->
        source = List.first(indexed.events)

        error = %{
          index: if(source, do: source.index, else: 0),
          at: if(source, do: Map.take(source, [:mfa, :stack]), else: %{}),
          rule: :connection_render_source,
          actual: false,
          expected: :whole_raw_observation
        }

        %{events: indexed.events, consumed: MapSet.new(), errors: [error]}

      true ->
        render_native(proof, indexed)
    end
  end

  defp render_native(proof, indexed) do
    spans = connection_spans(proof.reads)

    consumed =
      (proof.native.reads ++ proof.native.active)
      |> Enum.filter(fn read ->
        is_binary(read.bytes) and byte_size(read.bytes) > 0 and
          complete_span?(spans, read.delivered.index, byte_size(read.bytes))
      end)
      |> Enum.flat_map(&Map.get(&1, :indexes, []))
      |> MapSet.new()

    consumed = MapSet.union(consumed, decoder_transfers(proof, consumed))

    # A write program is never an incidental receive. Keep every one of its
    # instructions even if another validated native interval overlaps it.
    consumed =
      Enum.reduce(proof.native.writes, consumed, fn write, indexes ->
        Enum.reduce(Map.get(write, :indexes, []), indexes, &MapSet.delete(&2, &1))
      end)

    copies =
      (frontend_spans(proof, spans) ++ backend_spans(proof, spans) ++ backend_rows(proof))
      |> Enum.group_by(& &1.index)

    messages =
      ConnectionReads.messages(proof.reads, %{
        events: Map.get(proof, :program_events, indexed.events)
      })

    retained =
      indexed.events
      |> Enum.reject(&MapSet.member?(consumed, &1.index))
      |> Enum.map(fn source ->
        event =
          Enum.reduce(Map.get(copies, source.index, []), source.event, fn copy, event ->
            replace_connection_copy(event, copy.path, copy.value)
          end)

        %{source | event: event}
      end)

    events =
      (retained ++ messages)
      |> Enum.sort_by(fn source ->
        {source.index, if(Map.has_key?(source, :message_address), do: 1, else: 0),
         get_in(source, [:wire_frame, :start]) || 0}
      end)

    %{events: events, consumed: consumed, errors: []}
  end

  # A delivery can make Postgrex repeat a receive instruction. The raw
  # programs already established its exact branch, arguments and return.
  # A successful copy of the same receive belongs to the enclosing receive
  # only when every transport occurrence it used has a complete wire image.
  defp decoder_transfers(proof, consumed) do
    programs = Map.new(proof.decoders.programs, &{&1.source.index, &1})
    leaves = Map.new(proof.decoders.instances, &{&1.source.index, &1})
    transports = decoder_transport_sources(proof)

    Enum.reduce(proof.decoders.programs, MapSet.new(), fn program, copies ->
      promoted =
        for %{index: index, event: {_, :call, _}} <- program.execution,
            %{expected: {_, {:return_from, :ok, _}}} = child <- [Map.get(programs, index)],
            same_receive?(program, child),
            covered_delivery?(program, transports, consumed),
            do: child

      case promoted do
        [child] ->
          copies = MapSet.put(copies, child.source.index) |> MapSet.put(child.returned.index)
          incorporate_partial_decoders(copies, program, child, leaves)

        _ ->
          copies
      end
    end)
  end

  defp decoder_transport_sources(proof) do
    for delivery <- proof.native.reads ++ proof.native.active,
        index <- [delivery.source.index, delivery.returned.index, delivery.delivered.index],
        into: %{},
        do: {index, delivery}
  end

  defp same_receive?(%{source: parent, expected: {_, {:return_from, :ok, _}}}, %{source: child}) do
    {module, function, _} = parent.mfa
    match?({^module, ^function, _}, child.mfa)
  end

  defp same_receive?(_program, _child), do: false

  defp covered_delivery?(program, transports, consumed) do
    records =
      program.origins
      |> Enum.map(&Map.get(transports, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.source.index)

    records != [] and
      Enum.all?(records, fn delivery ->
        Enum.all?(delivery.indexes, &MapSet.member?(consumed, &1))
      end)
  end

  defp incorporate_partial_decoders(copies, program, child, leaves) do
    Enum.reduce(program.execution, copies, fn source, copies ->
      case Map.get(leaves, source.index) do
        %{expected: {:more, _}, returned: returned} when returned.index < child.source.index ->
          copies |> MapSet.put(source.index) |> MapSet.put(returned.index)

        %{expected: {:more, _, _, _}, returned: returned} when returned.index < child.source.index ->
          copies |> MapSet.put(source.index) |> MapSet.put(returned.index)

        _ ->
          copies
      end
    end)
  end

  # The one reassembly already bound every byte to its native write. Copies
  # refer to that exact span, while the logical messages retain all its content.
  # No binary outside the native ledger is inspected or rewritten.
  defp frontend_spans(proof, spans) do
    constructions =
      for %{origin: {:frontend_encoding, _, _} = origin} = copy <- proof.states.terms,
          into: %{},
          do: {{copy.index, copy.path}, origin}

    qualified =
      constructions |> Map.keys() |> MapSet.new()

    for write <- proof.native.writes,
        write.bytes != <<>>,
        {:ok, origin} <- [Map.fetch(constructions, {write.source.index, [2, 2, 1]})],
        complete_span?(spans, write.command.index, byte_size(write.bytes)),
        Enum.all?(write.copies, fn copy ->
          copy.index == write.command.index or MapSet.member?(qualified, {copy.index, copy.path})
        end),
        [%{port: port, span: first} | _] = Map.fetch!(spans, write.command.index),
        port == write.port,
        start = first.offset - first.source_offset + write.header_size,
        copy <- frontend_copies(proof, write, constructions, origin) do
      %{
        index: copy.index,
        path: copy.path,
        value:
          {:connection_byte_span, port, :frontend, start, start + byte_size(write.bytes),
           if(Map.get(copy, :offset, 0) > 0, do: Map.fetch!(write, :reference), else: nil)}
      }
    end
  end

  defp frontend_copies(proof, write, constructions, origin) do
    message_path = [2, 2, 1]
    {:frontend_encoding, owner, message_origin} = origin

    owners =
      Enum.count(proof.native.writes, fn candidate ->
        Map.get(constructions, {candidate.source.index, message_path}) == origin
      end)

    # An upstream IOdata construction can name this span only when its complete
    # native program issued exactly this write. Its helpers are byte copies,
    # not additional writes or an allowance to erase their call occurrences.
    copies =
      if owners == 1 do
        Enum.filter(proof.states.terms, fn
          %{origin: ^origin} -> true
          %{index: ^owner, path: ^message_path, origin: ^message_origin} -> true
          _ -> false
        end)
      else
        []
      end

    Enum.uniq_by(write.copies ++ copies, &{&1.index, &1.path})
  end

  defp backend_spans(proof, spans) do
    # A decoder indexes its native return. The wire ledger indexes the ingress
    # receipt. Their physical offsets must agree for every projected byte.
    deliveries =
      for read <- proof.native.reads ++ proof.native.active,
          is_binary(read.bytes),
          size = byte_size(read.bytes),
          size > 0,
          complete_span?(spans, read.delivered.index, size),
          [%{port: port, direction: :backend, span: first} | _] <-
            [Map.get(spans, read.delivered.index, [])],
          port == read.port,
          into: %{} do
        {read.returned.index, {port, first.offset - first.source_offset, size}}
      end

    versions = Map.new(proof.decoders.timeline, &{{&1.port, &1.index}, &1.cursor})

    decoder_copies =
      for instance <- proof.decoders.instances, copy <- instance.copies do
        first = if copy.index == instance.source.index, do: instance.start, else: instance.stop
        first = first + copy.offset
        {copy, instance.port, first, first + copy.length, instance.provenance}
      end

    helper_copies =
      for copy <- proof.states.buffers,
          port = NativeTransport.physical_port(proof.native, copy.sock),
          %{offset: first, buffer: bytes, spans: provenance} <-
            [backend_cursor(copy.origin, port, versions)] do
        {copy, port, first, first + byte_size(bytes), provenance}
      end

    for {copy, port, first, last, provenance} <- decoder_copies ++ helper_copies,
        complete_backend_span?(deliveries, port, first, last, provenance) do
      %{
        index: copy.index,
        path: copy.path,
        value: {:connection_byte_span, port, :backend, first, last, nil}
      }
    end
  end

  defp backend_cursor({kind, origin_port, index}, port, versions)
       when origin_port == port and kind in [:decoder_return_buffer, :decoder_cursor],
       do: Map.get(versions, {port, index})

  defp backend_cursor({:continuation_buffer, _parent, index}, port, versions),
    do: Map.get(versions, {port, index})

  defp backend_cursor(_origin, _port, _versions), do: nil

  defp complete_backend_span?(deliveries, port, first, last, provenance) when last > first do
    stop =
      provenance
      |> Wire.spans(first, last)
      |> Enum.sort_by(& &1.offset)
      |> Enum.reduce_while(first, fn span, cursor ->
        case Map.get(deliveries, span.index) do
          {^port, start, size}
          when span.offset == cursor and start + span.source_offset == cursor and
                 span.source_offset + span.length <= size ->
            {:cont, cursor + span.length}

          _ ->
            {:halt, nil}
        end
      end)

    stop == last
  end

  defp complete_backend_span?(_deliveries, _port, _first, _last, _provenance), do: false

  defp backend_rows(proof) do
    addresses = backend_row_addresses(proof.reads)

    direct =
      for %{input_rows: input, returned_rows: output} = instance <- proof.decoders.instances,
          {index, path, sources} <- [
            {instance.source.index, [2, 2, 2], input},
            {instance.returned.index, backend_row_path(instance.expected), output}
          ],
          copy <- backend_row_copies(addresses, instance.port, index, path, sources),
          do: copy

    versions = Map.new(proof.decoders.timeline, &{{&1.port, &1.index}, &1.cursor})

    helpers =
      for %{origin: {:decoder_rows, port, origin}} = copy <- proof.states.terms,
          %{row_sources: sources} <- [Map.get(versions, {port, origin})],
          row <- backend_row_copies(addresses, port, copy.index, copy.path, sources),
          do: row

    direct ++ helpers
  end

  defp backend_row_addresses(reads) do
    for {port, connection} <- reads.connections,
        messages = Map.get(connection, :historical_messages, []) ++ connection.protocol.messages,
        rows = Enum.filter(messages, &match?(%{direction: :backend, decoded: {:data_row, _}}, &1)),
        {statement, rows} <- Enum.group_by(rows, & &1.statement),
        statement != nil,
        {row, occurrence} <- Enum.with_index(rows),
        into: %{},
        do: {{port, row.start}, {:connection_row, port, statement, occurrence}}
  end

  defp backend_row_copies(addresses, port, index, path, sources) do
    for {offset, position} <- Enum.with_index(sources),
        {:ok, address} <- [Map.fetch(addresses, {port, offset})],
        do: %{index: index, path: path ++ [position], value: address}
  end

  defp backend_row_path({:ok, _rows, _buffer}), do: [3, 1]
  defp backend_row_path({:more, _buffer, _rows, _required}), do: [3, 2]

  defp connection_spans(reads) do
    for {port, connection} <- reads.connections,
        message <- connection.protocol.messages,
        span <- message.provenance do
      %{index: span.index, port: port, direction: message.direction, span: span}
    end
    |> Enum.group_by(& &1.index)
  end

  defp complete_span?(spans, index, length) do
    parts = Map.get(spans, index, [])
    intervals = parts |> Enum.map(& &1.span) |> Enum.sort_by(& &1.offset)

    case intervals do
      [first | _] ->
        {stop, contiguous?} =
          Enum.reduce(intervals, {first.offset, true}, fn span, {stop, valid?} ->
            {span.offset + span.length, valid? and span.offset == stop}
          end)

        contiguous? and stop - first.offset == length and
          length(Enum.uniq_by(parts, &{&1.port, &1.direction})) == 1

      [] ->
        false
    end
  end

  defp replace_connection_copy(_value, [], replacement), do: replacement

  defp replace_connection_copy(value, [position | path], replacement) when is_tuple(value),
    do:
      put_elem(
        value,
        position,
        replace_connection_copy(elem(value, position), path, replacement)
      )

  defp replace_connection_copy(value, [position | path], replacement) when is_list(value),
    do: List.update_at(value, position, &replace_connection_copy(&1, path, replacement))

  defp native_history(indexed, connections, bindings) do
    births = ConnectionTls.births(indexed)
    native_history(indexed, connections, bindings ++ births.bindings, births.errors)
  end

  defp native_history(indexed, connections, [], errors) do
    transport = NativeTransport.build(indexed, connections)
    %{transport | errors: transport.errors ++ errors}
  end

  defp native_history(indexed, connections, bindings, errors) do
    transport = NativeTransport.build(indexed, connections, Enum.map(bindings, & &1.transport))
    tls = ConnectionTls.build(Map.put(indexed, :native_transport, transport), bindings)
    upgrades = Map.new(bindings, &{&1.port, Map.get(&1, :upgrade_index, -1)})

    plaintext? = fn instance ->
      case Map.fetch(upgrades, instance.port) do
        {:ok, upgrade} -> instance.source.index < upgrade
        :error -> true
      end
    end

    # Ciphertext keeps its complete native/worker proof. Only each independently
    # bound public SSL boundary supplies bytes to PostgreSQL's logical stream.
    Map.merge(transport, %{
      reads: Enum.filter(transport.reads, plaintext?) ++ tls.reads,
      writes: Enum.filter(transport.writes, plaintext?) ++ tls.writes,
      active: Enum.filter(transport.active, plaintext?) ++ tls.active,
      errors: tls.errors ++ errors,
      tls: tls,
      tls_bindings: bindings
    })
  end

  @impl true
  def init(owner) do
    Process.flag(:trap_exit, true)
    Code.ensure_loaded!(Postgrex.Protocol)
    session = :trace.session_create(:ash_onetime_connection_history, self(), [])

    trace_functions(session)

    flags = [:call, :procs, :strict_monotonic_timestamp]
    :trace.process(session, :new, true, flags)
    1 = :trace.process(session, owner, true, flags)

    {:ok,
     %{session: session, events: [], frames: %{}, origins: %{}, preparations: %{}, waiting: %{}}}
  end

  defp trace_functions(session) do
    for {function, arity} <- @native_functions do
      :trace.function(
        session,
        {Postgrex.Protocol, function, arity},
        [{:_, [], [{:exception_trace}]}],
        [:local]
      )
    end

    :ok
  end

  @impl true
  def handle_call(:owner_loaded, _from, state) do
    :ok = trace_functions(state.session)
    {:reply, :ok, state}
  end

  def handle_call(:function_coverage, _from, state) do
    coverage =
      Enum.map(@native_functions, fn {function, arity} ->
        mfa = {Postgrex.Protocol, function, arity}
        %{mfa: mfa, traced?: :trace.info(state.session, mfa, :traced) == {:traced, :local}}
      end)

    {:reply, coverage, state}
  end

  def handle_call({:traced, pid}, _from, state) do
    traced? =
      case :trace.info(state.session, pid, :flags) do
        {:flags, flags} -> :call in flags
        :undefined -> false
      end

    {:reply, traced?, state}
  end

  def handle_call({:snapshot, kind}, from, state) do
    fence = :trace.delivered(state.session, :all)
    {:noreply, put_in(state.waiting[fence], {from, kind})}
  end

  @impl true
  def handle_info({:trace_delivered, :all, fence}, state) do
    {request, waiting} = Map.pop(state.waiting, fence)
    state = Enum.reduce(Enum.sort_by(state.events, &elem(&1, 0)), state, &record/2)

    if request do
      {from, kind} = request
      GenServer.reply(from, Map.values(Map.fetch!(state, kind)))
    end

    {:noreply, %{state | events: [], waiting: waiting}}
  end

  def handle_info(message, state) when is_tuple(message) and elem(message, 0) == :trace_ts do
    [_tag | fields] = Tuple.to_list(message)
    {fields, [stamp]} = Enum.split(fields, -1)

    # Select named fields before retaining anything. Authentication messages,
    # protocol credentials, execution values and exception reasons are not kept.
    case select(List.to_tuple(fields)) do
      nil -> {:noreply, state}
      event -> {:noreply, %{state | events: [{stamp, event} | state.events]}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _value} -> {:log, []}
      {key, _value} when key in [:state, :message, :reason] -> {key, :native_connection_history}
      entry -> entry
    end)
  end

  @impl true
  def terminate(_reason, state), do: :trace.session_destroy(state.session)

  defp select({pid, :call, {Postgrex.Protocol, :handle_prepare, [_query, _opts, %{sock: sock}]}}),
    do: {pid, :prepare, sock}

  defp select(
         {pid, :call,
          {Postgrex.Protocol, :handle_prepare_execute, [_query, _params, _opts, %{sock: sock}]}}
       ),
       do: {pid, :prepare, sock}

  defp select(
         {pid, :call,
          {Postgrex.Protocol, :recv_parse_describe, [%{sock: sock}, _status, _query, _buffer]}}
       ),
       do: {pid, :prepare, sock}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :recv_parse_describe, 4},
          {:ok, %Postgrex.Query{} = query, %{sock: sock}, _buffer}}
       ),
       do: {pid, :parsed, {sock, query}}

  defp select({pid, tag, {Postgrex.Protocol, :recv_parse_describe, 4}, _result})
       when tag in [:return_from, :exception_from],
       do: {pid, :refused, nil}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :redescribe, 6},
          {:ok, %Postgrex.Query{} = query, %{sock: sock}, _buffer}}
       ),
       do: {pid, :described, {sock, query}}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :handle_prepare, 3},
          {:ok, %Postgrex.Query{} = query, %{sock: sock}}}
       ),
       do: {pid, :prepared, {sock, query}}

  defp select({pid, tag, {Postgrex.Protocol, :handle_prepare, 3}, _result})
       when tag in [:return_from, :exception_from],
       do: {pid, :refused, nil}

  defp select({pid, tag, {Postgrex.Protocol, :handle_prepare_execute, 4}, _result})
       when tag in [:return_from, :exception_from],
       do: {pid, :refused, nil}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :msg_recv, arity},
          {:ok, msg_parameter_desc(type_oids: oids), _buffer}}
       ),
       do: {pid, :parameters, {arity, oids}}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :msg_recv, arity},
          {:ok, msg_row_desc(fields: fields), _buffer}}
       ),
       do: {pid, :columns, {arity, columns(fields)}}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :msg_recv, arity}, {:ok, msg_no_data(), _buffer}}
       ),
       do: {pid, :columns, {arity, nil}}

  defp select({pid, :exit, _reason}), do: {pid, :exit, nil}
  defp select(_event), do: nil

  defp columns(fields) do
    for row_field(
          name: name,
          table_oid: table,
          column: number,
          type_oid: oid,
          type_size: width,
          type_mod: modifier,
          format: format
        ) <- fields,
        do: {name, {:table_oid, table}, number, oid, width, modifier, format}
  end

  defp record({_stamp, {pid, :prepare, sock}}, state) do
    frames = Map.get(state.frames, pid, [])
    put_in(state.frames[pid], [%{sock: sock} | frames])
  end

  defp record({stamp, {pid, kind, {arity, value}}}, state)
       when kind in [:parameters, :columns] do
    case Map.get(state.frames, pid, []) do
      [frame | rest] ->
        origin = %{index: {:historical, stamp}, mfa: {Postgrex.Protocol, :msg_recv, arity}}
        frame = Map.put_new(frame, kind, value) |> Map.put_new({:origin, kind}, origin)
        put_in(state.frames[pid], [frame | rest])

      [] ->
        state
    end
  end

  defp record({stamp, {pid, :prepared, {sock, query}}}, state) do
    {frame, state} = pop(state, pid)
    retain_origin(state, frame, stamp, sock, query, {Postgrex.Protocol, :handle_prepare, 3})
  end

  defp record({stamp, {pid, :parsed, {sock, query}}}, state) do
    {frame, state} = pop(state, pid)

    state
    |> retain_origin(
      frame,
      stamp,
      sock,
      query,
      {Postgrex.Protocol, :recv_parse_describe, 4},
      :preparations
    )
    |> complete_preparation(pid, frame, sock, query)
  end

  defp record({stamp, {pid, :described, {sock, query}}}, state) do
    frame = state.frames |> Map.get(pid, []) |> List.first()
    retain_origin(state, frame, stamp, sock, query, {Postgrex.Protocol, :redescribe, 6})
  end

  defp record({_stamp, {pid, :refused, _}}, state), do: elem(pop(state, pid), 1)

  defp record({_stamp, {pid, :exit, _}}, state),
    do: %{state | frames: Map.delete(state.frames, pid)}

  # The outer successful callback owns its child's server descriptions too.
  # Carry them only across this native return on the same physical socket,
  # and bind the later callback return to the Query that child actually returned.
  defp complete_preparation(
         state,
         pid,
         %{sock: sock, parameters: _parameters, columns: _columns} = frame,
         sock,
         query
       ) do
    case Map.get(state.frames, pid, []) do
      [%{sock: ^sock} = parent | rest] ->
        description =
          frame
          |> Map.take([:parameters, :columns, {:origin, :parameters}, {:origin, :columns}])
          |> Map.put(:prepared_query, query)

        put_in(state.frames[pid], [Map.merge(parent, description) | rest])

      _ ->
        state
    end
  end

  defp complete_preparation(state, _pid, _frame, _sock, _query), do: state

  defp retain_origin(state, frame, stamp, sock, query, mfa, collection \\ :origins) do
    key = {sock, query.ref}

    case frame do
      %{sock: ^sock, parameters: parameters, columns: columns} = frame
      when not is_map_key(frame, :prepared_query) or frame.prepared_query === query ->
        origin = %{
          index: {:historical, stamp},
          mfa: mfa,
          path: [3, 1],
          sock: sock,
          query: query,
          parameters: parameters,
          columns: columns,
          description_origins: Map.take(frame, [{:origin, :parameters}, {:origin, :columns}])
        }

        put_in(state, [collection, key], origin)

      _ ->
        # A cached return supplies no new server facts. Keep every owner version
        # by ref, including one that Ecto later sends to a different connection.
        state
    end
  end

  defp pop(state, pid) do
    case Map.get(state.frames, pid, []) do
      [frame | rest] -> {frame, put_in(state.frames[pid], rest)}
      [] -> {nil, state}
    end
  end
end
