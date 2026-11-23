defmodule AshOnetime.Test.ExitBoundary.ConnectionHistory do
  @moduledoc false
  use GenServer

  alias AshOnetime.Test.ExitBoundary.ConnectionDecoders
  alias AshOnetime.Test.ExitBoundary.ConnectionReads
  alias AshOnetime.Test.ExitBoundary.ConnectionStates
  alias AshOnetime.Test.ExitBoundary.ConnectionTls
  alias AshOnetime.Test.ExitBoundary.ConnectionTypes
  alias AshOnetime.Test.ExitBoundary.NativeTransport

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

  defp native_history(indexed, connections, []), do: NativeTransport.build(indexed, connections)

  defp native_history(indexed, connections, bindings) do
    transport = NativeTransport.build(indexed, connections, Enum.map(bindings, & &1.transport))
    tls = ConnectionTls.build(Map.put(indexed, :native_transport, transport), bindings)
    ports = MapSet.new(bindings, & &1.port)

    # Ciphertext keeps its complete native/worker proof. Only each independently
    # bound public SSL boundary supplies bytes to PostgreSQL's logical stream.
    Map.merge(transport, %{
      reads: Enum.reject(transport.reads, &MapSet.member?(ports, &1.port)) ++ tls.reads,
      writes: Enum.reject(transport.writes, &MapSet.member?(ports, &1.port)) ++ tls.writes,
      active: Enum.reject(transport.active, &MapSet.member?(ports, &1.port)) ++ tls.active,
      errors: tls.errors,
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
