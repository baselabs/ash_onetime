defmodule AshOnetime.Delivery.ComparatorControlsTest do
  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.Allocation
  alias AshOnetime.Test.ExitBoundary.Capture
  alias AshOnetime.Test.ExitBoundary.ClockExpressions
  alias AshOnetime.Test.ExitBoundary.Comparator
  alias AshOnetime.Test.ExitBoundary.ComparatorMutants
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.Completeness
  alias AshOnetime.Test.ExitBoundary.ConnectionDecoders
  alias AshOnetime.Test.ExitBoundary.ConnectionHistory
  alias AshOnetime.Test.ExitBoundary.ConnectionNative
  alias AshOnetime.Test.ExitBoundary.ConnectionProtocol
  alias AshOnetime.Test.ExitBoundary.ConnectionReads
  alias AshOnetime.Test.ExitBoundary.ConnectionStates
  alias AshOnetime.Test.ExitBoundary.ConnectionTls
  alias AshOnetime.Test.ExitBoundary.ConnectionTypes
  alias AshOnetime.Test.ExitBoundary.ContextCopies
  alias AshOnetime.Test.ExitBoundary.DatabaseOrigins
  alias AshOnetime.Test.ExitBoundary.Declarations
  alias AshOnetime.Test.ExitBoundary.Diagnostics
  alias AshOnetime.Test.ExitBoundary.FailureTrace
  alias AshOnetime.Test.ExitBoundary.Historical
  alias AshOnetime.Test.ExitBoundary.HostCall
  alias AshOnetime.Test.ExitBoundary.NativeTransport
  alias AshOnetime.Test.ExitBoundary.Origins
  alias AshOnetime.Test.ExitBoundary.PathFrameWitnesses
  alias AshOnetime.Test.ExitBoundary.PermittedTrace
  alias AshOnetime.Test.ExitBoundary.Persisted
  alias AshOnetime.Test.ExitBoundary.QueryOrigins
  alias AshOnetime.Test.ExitBoundary.Readback
  alias AshOnetime.Test.ExitBoundary.References
  alias AshOnetime.Test.ExitBoundary.Refusals
  alias AshOnetime.Test.ExitBoundary.Registry
  alias AshOnetime.Test.ExitBoundary.Returned
  alias AshOnetime.Test.ExitBoundary.Scenarios
  alias AshOnetime.Test.ExitBoundary.Scheduling
  alias AshOnetime.Test.ExitBoundary.Search
  alias AshOnetime.Test.ExitBoundary.TransportReferences
  alias AshOnetime.Test.ExitBoundary.Values
  alias AshOnetime.Test.ExitBoundary.Wire
  alias AshOnetime.Test.ExitBoundary.Withheld
  alias AshOnetime.Test.MutationFormatter
  alias AshOnetime.Test.Repo
  alias AshOnetime.Test.StoreCase
  alias AshOnetime.Test.TestFormatter
  alias Ecto.Adapters.SQL
  import Ecto.Query, only: [from: 2]
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false

  @helper_buffer_inputs %{
    msg_send: [2],
    msg_recv: [2],
    rows_recv: [3],
    redescribe: [5],
    describe: [6],
    recv_describe: [-1],
    reload_describe_result: [3],
    recv_ready: [2],
    recv_strict_ready: [3],
    recv_transaction: [-1],
    error_ready: [3],
    error_flushed: [3],
    rollback_flushed: [3],
    reload_ready: [4],
    reload_transaction: [4],
    reload_closed: [4],
    reload_flushed: [4],
    reload_spawn: [4],
    reload_init: [4],
    ping_recv: [2, 3],
    activate: [1]
  }

  @helper_term_inputs %{
    {:parse_describe, 3} => [1, 2],
    {:parse_describe_close, 3} => [1, 2],
    {:close_parse_describe, 3} => [1, 2],
    {:parse_describe_flush, 4} => [1, 2, 3],
    {:close_parse_describe_flush, 4} => [1, 2, 3],
    {:recv_ready, 3} => [1],
    {:recv_strict_ready, 4} => [1, 2],
    {:recv_transaction, 3} => [1],
    {:recv_transaction, 4} => [1, 2],
    {:error_ready, 4} => [1, 2],
    {:error_flushed, 4} => [1, 2],
    {:rollback_flushed, 4} => [1, 2],
    {:reload_ready, 5} => [1, 2, 3],
    {:reload_transaction, 5} => [1, 2, 3],
    {:reload_closed, 5} => [1, 2, 3],
    {:reload_flushed, 5} => [1, 2, 3],
    {:reload_spawn, 5} => [1, 2, 3],
    {:reload_init, 5} => [1, 2, 3],
    {:handle_msg, 3} => [1, 2],
    {:ping_recv, 4} => [1],
    {:redescribe, 6} => [1, 2, 3, 4],
    {:describe, 7} => [1, 2, 3, 4, 5],
    {:describe_params, 3} => [1, 2],
    {:describe_result, 5} => [1, 2, 3, 4],
    {:reload_describe_result, 4} => [1, 2],
    {:recv_describe, 3} => [1],
    {:recv_describe, 4} => [1, 2],
    {:fetch_type_info, 2} => [0, 1],
    {:fetch_type_info, 3} => [0, 1, 2],
    {:fetch_type_info, 4} => [0, 1, 2, 3],
    {:columns, 1} => [0],
    {:msg_send, 3} => [1],
    {:rows_recv, 4} => [1, 2],
    {:rows_recv, 5} => [1, 2, 4],
    {:msg_recv, 3} => [1],
    {:msg_recv, 4} => [1, 3],
    {:done, 2} => [1],
    {:done, 4} => [1, 2, 3],
    {:done, 5} => [1, 2, 3, 4]
  }

  @type_helper_inputs %{
    {Postgrex.Types, :owner, 1} => [0],
    {Postgrex.Types, :fetch, 2} => [0, 1],
    {Postgrex.Types, :build_type_info, 1} => [0],
    {Postgrex.TypeServer, :fetch, 1} => [0],
    {Postgrex.TypeServer, :update, 3} => [0, 1, 2]
  }

  @tag connection_streams: :transport
  test "Connection streams: native messages survive every header split", context do
    pair = observe(context, row!(:issue, :execute), Values.set()[:va])
    Code.ensure_loaded!(Wire)
    assert function_exported?(Wire, :frames, 1), "CONNECTION_STREAM_REASSEMBLY_WITNESS"

    streams = native_stream_chunks(pair.run)
    assert map_size(streams) > 0

    for {_port, chunks} <- streams do
      assert Enum.any?(chunks, &(&1.direction == :frontend))
      assert Enum.any?(chunks, &(&1.direction == :backend))
      baseline = Wire.frames(chunks)
      assert baseline.errors == []
      assert baseline.messages != []

      for width <- [1, 2, 3, 4, 5, 7, 31, 4096] do
        split = Enum.flat_map(chunks, &split_stream_chunk(&1, width))
        result = Wire.frames(split)
        assert result.errors == []
        assert stream_contents(result) == stream_contents(baseline)

        for message <- result.messages do
          copies = message.provenance
          assert copies != []
          assert Enum.sum(Enum.map(copies, & &1.length)) == message.stop - message.start
          assert hd(copies).offset == message.start
        end
      end

      # Comparator self-test on captured native bytes: one message cannot borrow
      # ownership from the protocol that supplied only the end of its frame.
      frontend = Enum.find(chunks, &(&1.direction == :frontend))
      [first | rest] = split_stream_chunk(frontend, 1)

      crossed = [
        Map.put(first, :phase, :shared) | Enum.map(rest, &Map.put(&1, :phase, :committed_read))
      ]

      rejected = Wire.frames(crossed)
      assert Enum.map(rejected.errors, & &1.rule) == [:frame_ownership]

      bypassed =
        ComparatorMutants.with_mutant(:stream_frame_ownership, fn -> Wire.frames(crossed) end)

      assert bypassed.errors == []
      assert Enum.map(Wire.frames(crossed).errors, & &1.rule) == [:frame_ownership]
      assert Wire.frames([frontend]).errors == []
    end
  end

  @tag connection_streams: :transport
  test "Connection streams: a native incomplete final frame is refused" do
    run = ConnectionNative.observe(:incomplete)
    assert run.result == :ok
    Code.ensure_loaded!(Wire)
    assert function_exported?(Wire, :frames, 1), "CONNECTION_STREAM_FINAL_FRAME_WITNESS"

    streams = native_stream_chunks(%{run: run})
    assert map_size(streams) == 1

    for {_port, chunks} <- streams do
      result = Wire.frames(chunks)
      assert [%{rule: :incomplete_frame, direction: :backend}] = result.errors
    end
  end

  defp native_stream_chunks(side) do
    side.run.events
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      case entry.event do
        {port, :receive, {_pid, {:command, data}}} when is_port(port) ->
          <<size::16, reference::binary-size(size), bytes::binary>> = IO.iodata_to_binary(data)
          assert is_reference(:erlang.binary_to_term(reference, [:safe]))
          [{port, %{index: index, direction: :frontend, bytes: bytes}}]

        {port, :send, {:inet_async, port, _id, {:ok, bytes}}, _pid} when is_port(port) ->
          [{port, %{index: index, direction: :backend, bytes: IO.iodata_to_binary(bytes)}}]

        {port, :send, {:tcp, port, bytes}, _pid} when is_port(port) ->
          [{port, %{index: index, direction: :backend, bytes: IO.iodata_to_binary(bytes)}}]

        _ ->
          []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp split_stream_chunk(chunk, width) do
    offsets =
      Stream.iterate(0, &(&1 + width))
      |> Enum.take_while(&(&1 < byte_size(chunk.bytes)))

    for offset <- offsets do
      chunk
      |> Map.put(:source_offset, offset)
      |> Map.put(
        :bytes,
        binary_part(chunk.bytes, offset, min(width, byte_size(chunk.bytes) - offset))
      )
    end
  end

  defp stream_contents(result),
    do: Enum.map(result.messages, &Map.take(&1, [:direction, :tag, :payload, :start, :stop]))

  @tag connection_streams: :driver
  test "Connection streams: native Parse Describe Flush and Bind Execute Sync associate",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)

    run =
      ExitBoundary.observe(
        fn ->
          Repo.put_dynamic_repo(context.repo)
          context.repo
        end,
        fn repo -> SQL.query!(repo, "SELECT 17::int4 AS connection_stream_probe", []) end,
        %{
          host: [],
          callbacks: [],
          frames: [
            {Postgrex.Protocol, :msg_recv, :_},
            {Postgrex.Protocol, :rows_recv, :_},
            {Postgrex.Protocol, :msg_decode, 1},
            {Postgrex.Types, :decode_rows, 4}
          ]
        }
      )

    assert native_result(run) == {:ok, [[17]]}
    streams = native_stream_chunks(%{run: run})
    assert map_size(streams) == 1

    indexed =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: indexed})
    assert native.errors == []
    assert native.reads != []
    assert native.writes != []

    for read <- native.reads do
      assert read.indexes != []
      assert read.source.index in read.indexes
      assert read.returned.index in read.indexes
      assert read.provenance in read.indexes
      assert read.control_request.index in read.indexes
      assert read.control_reply.index in read.indexes
      assert read.control_request.index < read.delivered.index
      assert is_integer(read.id)
      assert length(read.copies) == 5
      assert Enum.all?(read.copies, &(&1.index in read.indexes))
      assert Enum.all?(read.copies, &(&1.length == byte_size(read.bytes)))
      assert_native_copies(read.copies, indexed, read.bytes)
    end

    for write <- native.writes do
      assert write.command.index in write.indexes
      assert write.source.index in write.indexes
      assert write.returned.index in write.indexes
      assert is_reference(write.reference)
      assert length(write.copies) == 6
      assert Enum.all?(write.copies, &(&1.index in write.indexes))
      assert Enum.all?(write.copies, &(&1.length == byte_size(write.bytes)))
      assert_native_copies(write.copies, indexed, write.bytes)
    end

    demand = ConnectionReads.build(native)
    assert demand.errors == []
    assert length(demand.demands) == length(native.reads)
    assert map_size(demand.connections) == 1
    assert Enum.all?(Map.values(demand.connections), &(&1.framing.messages != []))

    for {_port, connection} <- demand.connections,
        frame <- connection.framing.messages,
        span <- frame.provenance do
      assert span.copies != []
      assert Enum.all?(span.copies, &(&1.length == span.length))
      bytes = <<frame.tag, byte_size(frame.payload) + 4::signed-32, frame.payload::binary>>
      expected = binary_part(bytes, span.offset - frame.start, span.length)
      assert_native_copies(span.copies, indexed, expected)
    end

    decoders =
      ConnectionDecoders.build(%{events: indexed}, native, demand, historical.connections)

    assert decoders.errors == []
    assert decoders.instances != []
    assert Enum.any?(decoders.instances, &(&1.source.mfa == {Postgrex.Protocol, :msg_decode, 1}))
    assert Enum.any?(decoders.instances, &(&1.source.mfa == {Postgrex.Types, :decode_rows, 4}))

    for %{source: %{mfa: {Postgrex.Types, :decode_rows, 4}}} = instance <- decoders.instances do
      assert %{index: index, path: [3, 1]} = instance.descriptor
      assert index < instance.source.index

      %{event: {_, :return_from, mfa, {:ok, %Postgrex.Query{}, _}}} = Enum.at(indexed, index)
      assert mfa == {Postgrex.Protocol, :handle_prepare, 3}
    end

    for instance <- decoders.instances, copy <- instance.copies do
      expected = if copy.index == instance.source.index, do: instance.input, else: instance.tail
      assert_native_copies([copy], indexed, expected)
    end

    for instance <- decoders.instances do
      assert Enum.sum(Enum.map(instance.provenance, & &1.length)) == byte_size(instance.input)

      for span <- instance.provenance do
        expected = binary_part(instance.input, span.offset - instance.start, span.length)
        assert_native_copies(span.copies, indexed, expected)
      end
    end

    for {_port, chunks} <- streams do
      framing = Wire.frames(chunks)
      assert framing.errors == []
      protocol = ConnectionProtocol.build(framing.messages)
      assert protocol.errors == []
      assert protocol.pending == []
      assert length(protocol.messages) == length(framing.messages)

      tags = Enum.map(protocol.messages, &{&1.direction, &1.tag})
      assert {:frontend, ?P} in tags
      assert {:frontend, ?D} in tags
      assert {:frontend, ?H} in tags
      assert {:frontend, ?B} in tags
      assert {:frontend, ?E} in tags
      assert {:frontend, ?S} in tags

      assert Enum.any?(protocol.messages, fn
               %{decoded: {:data_row, [{:data_column, _, _, 0, _, _, _, 23, 1, 17}]}} -> true
               _ -> false
             end)
    end
  end

  defp native_result(%{result: %Postgrex.Result{rows: rows}}), do: {:ok, rows}
  defp native_result(%{result: :ok}), do: :ok

  defp native_result(%{result: {:caught, kind, %{__struct__: module}}}),
    do: {:caught, kind, module}

  defp native_result(%{result: {:caught, kind, reason}}),
    do: {:caught, kind, native_reason_tag(reason)}

  defp native_result(_run), do: :unexpected_result

  defp native_reason_tag(reason)
       when reason in [:function_clause, :badarg, :undef, :timeout],
       do: reason

  defp native_reason_tag({tag, _}) when tag in [:badmatch, :case_clause], do: tag
  defp native_reason_tag(_reason), do: :term

  @tag connection_streams: :driver
  test "Connection streams: prepared metadata comes from the connection's native history" do
    %{run: run, history: history} = ConnectionNative.observe_prepared()
    assert run.result == :ok
    framing = Wire.frames(history.chunks)
    assert framing.errors == []
    prepared = ConnectionProtocol.build(framing.messages)
    assert prepared.errors == []
    assert prepared.pending == []
    assert prepared.statements["native_prepared"].parameter_types == [23]

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events})
    assert native.errors == []
    assert native.reads != [] and native.writes != []
    unbound = ConnectionReads.build(native)
    assert Enum.any?(unbound.errors, &(&1.rule == :protocol_message))
    result = ConnectionReads.build(native, MapSet.new(), %{history.port => prepared})
    assert result.errors == []
    assert map_size(result.connections) == 1

    messages = result.connections[history.port].protocol.messages

    assert Enum.any?(messages, fn
             %{decoded: {:bind, _, "native_prepared", _, [{:bind_column, 1, 23, 1, 17}], _}} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(messages, fn
             %{decoded: {:data_row, [{:data_column, _, _, 0, _, _, _, 23, 1, 17}]}} -> true
             _ -> false
           end)
  end

  @tag connection_streams: :transport
  test "Connection streams: history failures keep native terms out of logger diagnostics" do
    marker = "native-history-diagnostic-marker"
    unguarded = ComparatorMutants.with_mutant(:history_status, &history_failure_log/0)
    assert String.contains?(unguarded, marker)
    restored = history_failure_log()
    refute String.contains?(restored, marker)
    IO.puts("CONNECTION_HISTORY_STATUS: native logger RED; exact restore GREEN")
  end

  defp history_failure_log do
    ExUnit.CaptureLog.capture_log(fn ->
      history =
        start_supervised!({ConnectionHistory, owner: self()},
          id: make_ref(),
          restart: :temporary
        )

      monitor = Process.monitor(history)
      GenServer.cast(history, {:unexpected, "native-history-diagnostic-marker"})

      receive do
        {:DOWN, ^monitor, :process, ^history, _reason} -> :ok
      after
        5_000 -> flunk("the real history logger probe did not stop")
      end
    end)
  end

  @tag connection_streams: :driver
  @tag prepare: :named, pool_size: 1
  test "Connection streams: native owner replacement preserves historical observation", context do
    observer = Process.whereis(ConnectionHistory)
    assert is_pid(observer)
    {:memory, initial_memory} = Process.info(observer, :memory)
    before = native_history_query(context, "history_before_reload")
    assert Enum.all?(before.coverage, & &1.traced?)
    assert before.descriptors != []

    rejected =
      ComparatorMutants.with_mutant(:history_reload, fn ->
        ComparatorMutants.with_postgrex_mutant(:send_buffer_copy, fn ->
          native_history_query(context, "history_unobserved_reload")
        end)
      end)

    refute Enum.all?(rejected.coverage, & &1.traced?)
    assert rejected.descriptors == []

    for {loader, active, restored} <- [
          {&ComparatorMutants.with_postgrex_mutant(:send_buffer_copy, &1),
           "history_source_reload", "history_source_restored"},
          {&ComparatorMutants.with_postgrex_repeated_decoder(:message, &1),
           "history_object_reload", "history_object_restored"}
        ] do
      observed = loader.(fn -> native_history_query(context, active) end)
      assert Enum.all?(observed.coverage, & &1.traced?)
      assert observed.descriptors != []
      after_restore = native_history_query(context, restored)
      assert Enum.all?(after_restore.coverage, & &1.traced?)
      assert after_restore.descriptors != []
    end

    assert Process.whereis(ConnectionHistory) == observer
    {snapshot_us, origins} = :timer.tc(&ConnectionHistory.snapshot/0)
    {:memory, final_memory} = Process.info(observer, :memory)

    for original <- before.descriptors do
      source = Map.delete(original, :port)
      retained? = Enum.any?(origins, &(&1.query.ref === source.query.ref and &1 === source))
      assert retained?, "a live historical Query origin must survive native code replacement"
    end

    IO.puts(
      "CONNECTION_HISTORY_MEASUREMENT: " <>
        "initial_memory_bytes=#{initial_memory} final_memory_bytes=#{final_memory} " <>
        "snapshot_us=#{snapshot_us} origins=#{length(origins)}"
    )
  end

  defp native_history_query(context, name) do
    sql = "SELECT $1::int4 AS " <> name
    assert %{rows: [[17]]} = SQL.query!(context.repo, sql, [17], cache_statement: name)
    historical = Historical.capture(context.prefix)

    descriptors =
      for {_holder, connection} <- historical.connections,
          origin <- connection.descriptors,
          IO.iodata_to_binary(origin.query.statement) == sql,
          do: origin

    %{coverage: ConnectionHistory.function_coverage(), descriptors: descriptors}
  end

  @tag connection_streams: :driver
  @tag prepare: :named, pool_size: 1
  test "Connection streams: main snapshots retain native prepared catalogs and descriptors",
       context do
    Repo.put_dynamic_repo(context.repo)

    sql =
      ~s[SELECT id, amount FROM "#{context.prefix}".ash_onetime_boundary_records WHERE amount >= $1]

    SQL.query!(context.repo, sql, [1], cache_statement: "historical_native_catalog")
    historical = Historical.capture(context.prefix)
    catalogs? = Map.has_key?(historical, :prepared_catalogs)
    assert catalogs?, "the historical native prepared catalog is missing"

    descriptors =
      for {_holder, connection} <- historical.connections,
          origin <- Map.get(connection, :descriptors, []),
          IO.iodata_to_binary(origin.query.statement) == sql,
          do: origin

    if descriptors == [] do
      origins =
        for origin <- historical.query_origins,
            IO.iodata_to_binary(origin.query.statement) == sql,
            do: %{mfa: origin.mfa, parameters?: origin.parameters === origin.query.param_oids}

      cached =
        for {_holder, connection} <- historical.connections,
            {_name, _ref, %Postgrex.Query{} = query} <- connection.query_cache.rows,
            IO.iodata_to_binary(query.statement) == sql do
          %{
            owner_traced?: connection.history_owner_traced?,
            same_pool?: connection.pool === historical.repo_metadata.pid,
            origin?: Enum.any?(historical.query_origins, &(&1.query.ref === query.ref))
          }
        end

      IO.puts(
        "CONNECTION_HISTORY_CATALOG_SOURCE: " <>
          Diagnostics.render(%{
            patterns: ConnectionHistory.function_coverage(),
            origins: origins,
            cached: cached
          })
      )
    end

    assert descriptors != []

    for origin <- descriptors do
      assert origin.mfa == {Postgrex.Protocol, :handle_prepare, 3}
      assert origin.path == [3, 1]
      assert origin.query.param_oids == [20]
      assert origin.query.result_oids == [2950, 20]
      catalog = historical.prepared_catalogs[origin.port][origin.query.name]
      assert catalog.sql == sql
      assert catalog.parameter_types == [20]

      assert [
               {"id", {:table_oid, oid}, 1, 2950, 16, -1, _},
               {"amount", {:table_oid, oid}, 2, 20, 8, -1, _}
             ] = catalog.columns

      assert historical.relations[oid] == "ash_onetime_boundary_records"
    end

    tls? = SQL.query!(context.repo, "SHOW ssl", []).rows == [["on"]]
    IO.puts("CONNECTION_NATIVE_TLS_AVAILABLE=#{tls?}")
  end

  @tag connection_streams: :tls
  @tag native_tls: true, prepare: :named, pool_size: 1
  test "Connection streams: main TLS history retains its physical catalog and raw programs",
       context do
    sql = "SELECT $1::int4 AS tls_historical_catalog"

    assert %{rows: [[17]]} =
             SQL.query!(context.repo, sql, [17], cache_statement: "tls_native_catalog")

    historical = Historical.capture(context.prefix)

    [connection] =
      for {_holder, connection} <- historical.connections,
          connection.pool == historical.repo_metadata.pid,
          match?({:ssl, _}, connection.protocol.sock),
          do: connection

    descriptors =
      Enum.filter(connection.descriptors, fn origin ->
        IO.iodata_to_binary(origin.query.statement) == sql
      end)

    assert descriptors != [], "TLS descriptors must retain their native owner and physical port"
    binding = Map.fetch!(connection, :tls)
    assert ConnectionTls.validate(binding) == []

    for origin <- descriptors do
      assert origin.port == binding.port
      catalog = historical.prepared_catalogs[origin.port][origin.query.name]
      assert catalog.sql == sql
      assert catalog.parameter_types == [23]
    end

    run =
      ExitBoundary.observe(
        fn -> Repo.put_dynamic_repo(context.repo) end,
        fn _ -> SQL.query!(context.repo, sql, [29], cache_statement: "tls_native_catalog") end,
        %{host: [], callbacks: []}
      )

    assert %{rows: [[29]]} = run.result

    used_sockets =
      for %{event: {_, :call, {:ssl, :send, [socket, _bytes]}}} <- run.events,
          do: socket

    assert used_sockets != [], "the TLS witness must use the actual public plaintext boundary"

    used_bindings =
      for {_holder, %{protocol: %{sock: {:ssl, socket}}, tls: binding}} <- historical.connections,
          socket in used_sockets,
          do: binding

    complete_bindings? = MapSet.new(used_bindings, & &1.socket) === MapSet.new(used_sockets)
    assert complete_bindings?, "every used plaintext socket needs its independently bound history"

    armed_bindings = Enum.filter(run.tls_bindings, &(&1.socket in used_sockets))
    armed? = MapSet.new(armed_bindings, & &1.socket) === MapSet.new(used_sockets)
    assert armed?, "each persistent TLS socket needs its own pre-arm machine roots"

    for binding <- armed_bindings, worker <- [binding.owner, binding.sender] do
      assert Map.has_key?(binding.states, worker)
      assert Map.has_key?(binding.machines, worker)
    end

    for binding <- used_bindings, worker <- [binding.owner, binding.sender] do
      traced? = Enum.any?(run.events, &(&1.pid == worker and elem(&1.event, 1) == :call))

      assert traced?,
             "each used TLS connection must retain both actual persistent worker programs"
    end

    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)

    for error <- proof.errors do
      Diagnostics.emit(
        "CONNECTION_TLS_MAIN_FAILURE",
        Map.take(error, [:index, :at, :rule, :path, :context])
      )
    end

    assert proof.errors == [], "MAIN must prove the real TLS plaintext and worker programs"
  end

  for shape <- [
        :rows,
        :none,
        :cross_connection,
        :redescribe,
        :strict,
        :large_rows,
        :notice,
        :parameter,
        :notification,
        :bind_error,
        :execute_error
      ] do
    @tag connection_streams: :driver
    test "Connection streams: cached decoder descriptors retain native origins for #{shape}" do
      shape = unquote(shape)
      captured = cached_decoders(nil, shape)
      %{decoders: decoders, origin: origin, events: events, streams: streams} = captured

      assert decoders.errors == []

      states =
        ConnectionStates.build(
          %{events: events},
          captured.native,
          decoders,
          captured.historical,
          {:initial, captured.initial}
        )

      assert states.errors == []
      covered = MapSet.new(states.copies, &{&1.index, &1.path})

      unbound =
        Enum.reject(decoders.protocol_copies, &MapSet.member?(covered, {&1.index, &1.path}))

      for copy <- unbound do
        IO.puts("CONNECTION_STATE_UNBOUND: " <> Diagnostics.render(copy, limit: :infinity))
      end

      assert unbound == [], "every native Protocol copy needs its own owner-version binding"

      bound_buffers = MapSet.new(states.buffers, &{&1.index, &1.path})

      unbound_buffers =
        Enum.reject(native_helper_buffers(events), fn copy ->
          MapSet.member?(bound_buffers, {copy.index, copy.path})
        end)

      for copy <- unbound_buffers do
        IO.puts("CONNECTION_HELPER_BUFFER_UNBOUND: " <> Diagnostics.render(copy))
      end

      assert unbound_buffers == [], "every native helper buffer needs its own byte-copy origin"

      bound_terms = MapSet.new(Map.get(states, :terms, []), &{&1.index, &1.path})

      unbound_terms =
        Enum.reject(native_helper_terms(events), fn copy ->
          MapSet.member?(bound_terms, {copy.index, copy.path})
        end)

      for copy <- unbound_terms do
        IO.puts("CONNECTION_HELPER_TERM_UNBOUND: " <> Diagnostics.render(copy))
      end

      if unquote(shape == :large_rows) do
        assert Enum.any?(decoders.versions, &is_list(&1.returned_buffer))

        assert Enum.any?(states.buffers, fn
                 %{origin: {:continuation_buffer, _, _}} -> true
                 _ -> false
               end),
               "the real large DataRow must execute a partial-read continuation"
      end

      assert Enum.any?(decoders.protocol_copies, fn copy ->
               copy.mfa == {Postgrex.Protocol, :handle_execute, 4} and copy.tag == :call and
                 copy.path == [2, 2, 3] and is_integer(copy.index)
             end)

      rows =
        Enum.filter(decoders.instances, &(&1.source.mfa == {Postgrex.Types, :decode_rows, 4}))

      if unquote(shape == :bind_error), do: assert(rows == []), else: assert(rows != [])
      assert length(decoders.versions) == length(decoders.instances)

      assert Enum.all?(decoders.versions, fn version ->
               source = Enum.fetch!(events, version.index)

               elem(source.event, 1) == :return_from and
                 Enum.any?(decoders.instances, fn instance ->
                   instance.returned.index == version.index and
                     instance.stop == version.cursor.offset
                 end)
             end)

      descriptor =
        if unquote(shape == :redescribe) do
          source =
            Enum.find(
              events,
              &(&1.mfa == {Postgrex.Protocol, :redescribe, 6} and
                  elem(&1.event, 1) == :return_from)
            )

          assert source != nil
          %{index: source.index, path: [3, 1]}
        else
          Map.take(origin, [:index, :path])
        end

      assert Enum.all?(rows, &(&1.descriptor == descriptor))

      if unquote(shape in [:bind_error, :execute_error]) do
        expected = if unquote(shape == :bind_error), do: :bind, else: :execute

        assert Enum.any?(streams.connections, fn {_port, connection} ->
                 Enum.any?(connection.protocol.messages, fn
                   %{direction: :backend, tag: ?E, association: {^expected, _}} -> true
                   _ -> false
                 end)
               end)

        ready_errors =
          for %{
                event:
                  {_, :call,
                   {Postgrex.Protocol, :error_ready, [_, _, %Postgrex.Error{} = error, _]}}
              } <- events,
              do: error

        assert ready_errors != []
        assert Enum.all?(ready_errors, &is_nil(&1.connection_id))
        assert {:error, error} = captured.run.result
        protocol = captured.historical |> Map.values() |> hd() |> Map.fetch!(:protocol)
        assert error.connection_id === protocol.connection_id
      end

      if unquote(shape == :cross_connection) do
        [{port, connection}] =
          Enum.filter(streams.connections, fn {_port, connection} ->
            connection.protocol.messages != []
          end)

        assert port != origin.port
        idle = Map.fetch!(streams.connections, origin.port)
        assert idle.protocol.messages == []

        for direction <- [:frontend, :backend] do
          stream = Map.fetch!(idle.framing.directions, direction)

          assert Map.take(stream, [:buffer, :offset, :received, :provenance]) ==
                   %{buffer: <<>>, offset: 0, received: 0, provenance: []}
        end

        assert Enum.any?(connection.protocol.messages, fn message ->
                 message.direction == :frontend and message.tag == ?P
               end)
      end

      if unquote(shape in [:notice, :parameter, :notification]) do
        tag = %{notice: ?N, parameter: ?S, notification: ?A}[shape]

        assert Enum.any?(streams.connections, fn {_port, connection} ->
                 Enum.any?(connection.protocol.messages, fn message ->
                   message.direction == :backend and message.tag == tag
                 end)
               end),
               "the native observation must contain its unsolicited backend message"
      end

      assert unbound_terms == [],
             "every captured helper argument needs its own status, query, error, metadata or value origin"
    end
  end

  defp native_helper_buffers(events) do
    Enum.flat_map(events, &native_helper_buffer/1)
  end

  defp native_helper_buffer(
         %{index: index, event: {_, :call, {Postgrex.Protocol, function, arguments}}} = source
       ) do
    for position <- Map.get(@helper_buffer_inputs, function, []),
        position = if(position < 0, do: length(arguments) + position, else: position),
        do: %{index: index, mfa: source.mfa, path: [2, 2, position]}
  end

  defp native_helper_buffer(
         %{index: index, event: {_, :return_from, {Postgrex.Protocol, function, _}, result}} =
           source
       )
       when function in [
              :msg_recv,
              :rows_recv,
              :redescribe,
              :describe,
              :recv_describe,
              :reload_describe_result
            ] and
              is_tuple(result) do
    if elem(result, 0) in [:ok, :reload, :error],
      do: [%{index: index, mfa: source.mfa, path: [3, tuple_size(result) - 1]}],
      else: []
  end

  defp native_helper_buffer(_source), do: []

  defp native_helper_terms(events), do: Enum.flat_map(events, &native_helper_term/1)

  defp native_helper_term(
         %{index: index, event: {_, :call, {module, function, arguments}}} = source
       )
       when module in [Postgrex.Types, Postgrex.TypeServer] do
    for position <- Map.get(@type_helper_inputs, {module, function, length(arguments)}, []),
        do: %{index: index, mfa: source.mfa, path: [2, 2, position]}
  end

  defp native_helper_term(
         %{index: index, event: {_, :return_from, {module, function, _arity}, result}} = source
       )
       when module in [Postgrex.Types, Postgrex.TypeServer] do
    paths = native_type_return_paths(module, function, result)

    for path <- paths, do: %{index: index, mfa: source.mfa, path: path}
  end

  defp native_helper_term(
         %{index: index, event: {_, :call, {Postgrex.Protocol, function, arguments}}} = source
       ) do
    for position <- Map.get(@helper_term_inputs, {function, length(arguments)}, []),
        do: %{index: index, mfa: source.mfa, path: [2, 2, position]}
  end

  defp native_helper_term(
         %{index: index, event: {_, :return_from, {Postgrex.Protocol, function, _}, result}} =
           source
       )
       when function in [
              :done,
              :error_ready,
              :error_flushed,
              :rollback_flushed,
              :reload_ready,
              :reload_transaction,
              :reload_closed,
              :reload_flushed,
              :reload_spawn,
              :parse_describe,
              :parse_describe_close,
              :close_parse_describe,
              :parse_describe_flush,
              :close_parse_describe_flush,
              :redescribe,
              :describe,
              :describe_params,
              :describe_result,
              :reload_describe_result,
              :recv_describe,
              :fetch_type_info,
              :columns
            ] and
              is_tuple(result) do
    positions = native_helper_return_positions(function, result)

    for position <- positions, do: %{index: index, mfa: source.mfa, path: [3, position]}
  end

  defp native_helper_term(
         %{index: index, event: {_, :return_from, {Postgrex.Protocol, function, _}, result}} =
           source
       )
       when function in [:msg_recv, :rows_recv] and is_tuple(result) and elem(result, 0) == :ok do
    positions = if function == :rows_recv, do: [1, 2], else: [1]
    for position <- positions, do: %{index: index, mfa: source.mfa, path: [3, position]}
  end

  defp native_helper_term(_source), do: []

  defp native_type_return_paths(Postgrex.Types, :owner, {:ok, _owner}), do: [[3, 0], [3, 1]]
  defp native_type_return_paths(Postgrex.Types, :owner, :error), do: [[3]]
  defp native_type_return_paths(Postgrex.Types, :fetch, {:ok, _info}), do: [[3, 0], [3, 1]]

  defp native_type_return_paths(Postgrex.Types, :fetch, {:error, _info, _module}),
    do: [[3, 0], [3, 1], [3, 2]]

  defp native_type_return_paths(Postgrex.Types, :build_type_info, _info), do: [[3]]

  defp native_type_return_paths(Postgrex.TypeServer, :fetch, {:lock, _reference, _types}),
    do: [[3, 0], [3, 1], [3, 2]]

  defp native_type_return_paths(Postgrex.TypeServer, :fetch, status)
       when status in [:error, :noproc],
       do: [[3]]

  defp native_type_return_paths(Postgrex.TypeServer, :update, _status), do: [[3]]
  defp native_type_return_paths(_module, _function, _result), do: []

  defp native_helper_return_positions(
         :recv_describe,
         {:ok, _, _, _, _, %Postgrex.Protocol{}, _}
       ),
       do: [1, 2, 3, 4]

  defp native_helper_return_positions(:fetch_type_info, {tag, _})
       when tag in [:ok, :reload, :error],
       do: [1]

  defp native_helper_return_positions(:reload_describe_result, {:reload, _, _, _}), do: [0, 1]

  defp native_helper_return_positions(:columns, {_, _, _}), do: [0, 1, 2]
  defp native_helper_return_positions(:done, {%Postgrex.Result{}, %Postgrex.Protocol{}}), do: [0]

  defp native_helper_return_positions(function, {:error, _error, %Postgrex.Protocol{}})
       when function in [:error_ready, :error_flushed, :rollback_flushed],
       do: [1]

  defp native_helper_return_positions(function, {:ok, %Postgrex.Query{}, _protocol})
       when function != :done,
       do: [1]

  defp native_helper_return_positions(function, {:ok, %Postgrex.Query{}, _protocol, _buffer})
       when function in [:redescribe, :describe],
       do: [1]

  defp native_helper_return_positions(function, {:ok, %Postgrex.Query{}})
       when function in [:describe_params, :describe_result],
       do: [1]

  defp native_helper_return_positions(_function, _result), do: []

  @tag connection_streams: :driver
  test "Connection streams: intermediate owner returns retain their native state versions" do
    %{events: events, decoders: decoders} = cached_decoders(nil, :cross_connection)

    prepared =
      Enum.find(events, fn
        %{event: {_, :return_from, {Postgrex.Protocol, :close_parse_describe_flush, 4}, _}} ->
          true

        _ ->
          false
      end)

    assert prepared != nil,
           "the owner return constructing the intermediate state must be captured"

    {_, :return_from, _, {:ok, query, protocol}} = prepared.event
    assert protocol.postgres == {:idle, query.ref}

    sent =
      Enum.find(events, fn
        %{index: index, event: {_, :call, {Postgrex.Protocol, :msg_send, _}}} ->
          index > prepared.index

        _ ->
          false
      end)

    {_, :call, {_, _, [sending, _messages, buffer]}} = sent.event
    assert sending == %{protocol | buffer: nil}
    assert buffer == protocol.buffer

    ready =
      Enum.find(events, fn
        %{event: {_, :return_from, {Postgrex.Protocol, :recv_ready, 3}, _}} -> true
        _ -> false
      end)

    assert ready != nil, "the owner return installing the consumed buffer must be captured"
    {_, :return_from, _, {:ok, ready_protocol}} = ready.event
    version = decoders.versions |> Enum.filter(&(&1.index < ready.index)) |> List.last()
    assert ready_protocol.buffer == version.cursor.buffer
    assert ready_protocol.postgres == :idle

    completed =
      Enum.find(events, fn
        %{event: {_, :return_from, {Postgrex.Protocol, :handle_execute, 4}, _}} -> true
        _ -> false
      end)

    assert elem(completed.event, 3) |> Tuple.to_list() |> List.last() == ready_protocol
    assert prepared.index < sent.index and sent.index < ready.index
    assert ready.index < completed.index
  end

  @tag connection_streams: :transport
  test "Connection streams: PID timer cancellation has a monitored native receipt" do
    run =
      ExitBoundary.observe(
        fn -> :ok end,
        fn :ok ->
          recipient =
            spawn(fn ->
              receive do
                :finish -> :ok
              end
            end)

          monitor = Process.monitor(recipient)
          timer = :erlang.send_after(60_000, recipient, :native_recipient_timer)
          send(recipient, :finish)

          receive do
            {:DOWN, ^monitor, :process, ^recipient, :normal} -> :ok
          end

          {recipient, timer}
        end,
        %{host: [], callbacks: []}
      )

    {recipient, reference} = run.result
    timer = Map.fetch!(run.snapshot.timers, reference)
    assert timer.dest == recipient
    assert timer.state == :recipient_exit
    assert timer.terminal.process == recipient
    assert timer.terminal.monitor == Map.fetch!(run.snapshot.monitors, recipient)
    assert timer.terminal.timer_read == false
    assert MapSet.member?(run.snapshot.down, recipient)
    assert :erlang.read_timer(reference) == false

    refute Enum.any?(run.events, fn
             %{event: {_, :call, {:erlang, :cancel_timer, [^reference | _]}}} -> true
             _ -> false
           end)
  end

  @tag connection_streams: :transport
  test "Connection streams: a registered timer destination requires its own cancellation" do
    run =
      ExitBoundary.observe(
        fn -> :ok end,
        fn :ok ->
          root = self()

          recipient =
            spawn(fn ->
              true = Process.register(self(), :ash_onetime_native_timer_recipient)
              send(root, :native_timer_registered)

              receive do
                :finish -> :ok
              end
            end)

          receive do
            :native_timer_registered -> :ok
          end

          monitor = Process.monitor(recipient)

          timer =
            :erlang.send_after(60_000, :ash_onetime_native_timer_recipient, :native_named_timer)

          send(recipient, :finish)

          receive do
            {:DOWN, ^monitor, :process, ^recipient, :normal} -> :ok
          end

          active? = is_integer(:erlang.read_timer(timer))
          cancelled? = is_integer(:erlang.cancel_timer(timer))
          {timer, active?, cancelled?}
        end,
        %{host: [], callbacks: []}
      )

    {reference, active?, cancelled?} = run.result
    assert active? and cancelled?
    timer = Map.fetch!(run.snapshot.timers, reference)
    assert timer.dest == :ash_onetime_native_timer_recipient
    assert timer.state == :cancelled
    refute Map.has_key?(timer, :terminal)
  end

  @tag connection_streams: :transport
  test "Connection streams: a forged DOWN cannot close a live traced process" do
    observer = self()
    tag = make_ref()

    capture = fn ->
      try do
        ExitBoundary.observe(
          fn ->
            child =
              spawn(fn ->
                receive do
                  :finish -> :ok
                end
              end)

            send(observer, {tag, child})
            child
          end,
          fn child ->
            {:monitored_by, monitors} = Process.info(self(), :monitored_by)
            [collector] = Enum.reject(monitors, &(&1 == observer))
            send(collector, {:DOWN, make_ref(), :process, child, :normal})
            :ok
          end,
          %{host: [], callbacks: [], preexisting: fn child -> [child] end}
        )
      after
        receive do
          {^tag, child} -> Process.exit(child, :kill)
        after
          0 -> :ok
        end
      end
    end

    assert_raise ExUnit.AssertionError, capture

    bypassed = ComparatorMutants.with_mutant(:stream_monitor_source, capture)
    assert bypassed.result == :ok
    assert_raise ExUnit.AssertionError, capture

    restored =
      ExitBoundary.observe(fn -> :ok end, fn :ok -> :ok end, %{host: [], callbacks: []})

    assert restored.result == :ok
    IO.puts("CONNECTION_MONITOR_SOURCE: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :pool
  test "Connection streams: shared service timers require their completed native callback" do
    {:ok, _applications} = Application.ensure_all_started(:ssl)
    service = Process.whereis(:ssl_manager)
    assert is_pid(service)

    capture = fn callback ->
      ExitBoundary.observe(
        fn -> :ok end,
        fn :ok ->
          :erlang.send_after(1, :ssl_manager, {:ash_onetime_native_timer, make_ref()})
        end,
        %{host: [], callbacks: [], services: %{ssl_manager: callback}}
      )
    end

    positive = capture.({:ssl_manager, :handle_info, 2})
    timer = Map.fetch!(positive.snapshot.timers, positive.result)
    assert timer.state == :fired
    assert timer.terminal.pid == service
    assert {^service, :receive, message} = timer.terminal.received
    assert message == timer.expected

    assert {^service, :call, {:ssl_manager, :handle_info, [^message, _state]}} =
             timer.terminal.called

    assert {^service, :return_from, {:ssl_manager, :handle_info, 2}, {:noreply, _state}} =
             timer.terminal.returned

    assert Process.alive?(service)
    refute MapSet.member?(positive.snapshot.pids, service)

    wrong = fn -> capture.({:ssl_manager, :handle_cast, 2}) end
    assert_raise ExUnit.AssertionError, wrong

    for mutant <- [:stream_monitor_source, :stream_service_completion] do
      ComparatorMutants.with_mutant(mutant, fn ->
        if mutant == :stream_service_completion do
          bypassed = wrong.()
          assert Map.fetch!(bypassed.snapshot.timers, bypassed.result).state == :fired
        else
          assert_raise ExUnit.AssertionError, wrong
        end
      end)
    end

    assert_raise ExUnit.AssertionError, wrong
    restored = capture.({:ssl_manager, :handle_info, 2})
    assert Map.fetch!(restored.snapshot.timers, restored.result).state == :fired
    assert Process.alive?(service)

    IO.puts("CONNECTION_SERVICE_COMPLETION: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :pool
  test "Connection streams: native type-service casts retain their completed dispatch" do
    check = fn ->
      run = ConnectionNative.observe_startup()
      assert run.result == :ok

      owners =
        for {pid, %{callback: {Postgrex.TypeServer, :handle_call, 3}}} <-
              run.snapshot.services,
            do: pid

      completed =
        Enum.filter(run.snapshot.service_receipts, fn receipt ->
          receipt.pid in owners and match?({:"$gen_cast", {:done, _}}, receipt.message)
        end)

      assert completed != []

      for receipt <- completed do
        assert receipt.registered?
        assert receipt.called && receipt.returned
        pid = receipt.pid
        assert {^pid, :call, {Postgrex.TypeServer, :handle_cast, _arguments}} = receipt.called

        assert {^pid, :return_from, {Postgrex.TypeServer, :handle_cast, 2}, _result} =
                 receipt.returned

        assert receipt.received_stamp < receipt.called_stamp
        assert receipt.called_stamp < receipt.returned_stamp
      end
    end

    check.()

    ComparatorMutants.with_mutant(:stream_service_cast_dispatch, fn ->
      assert_raise ExUnit.AssertionError, check
    end)

    check.()
  end

  @tag connection_streams: :driver
  test "Connection streams: native row type copies have their own descriptor origin" do
    captured =
      ComparatorMutants.with_postgrex_mutant(:row_type_copy, fn -> cached_decoders(nil) end)

    assert captured.native.errors == []
    assert captured.decoders.errors == []

    [corrupted] =
      Enum.filter(captured.events, fn
        %{
          event:
            {_, :call,
             {Postgrex.Protocol, :rows_recv, [_protocol, {:native_foreign_types, _}, _, _]}}
        } ->
          true

        _ ->
          false
      end)

    IO.puts(
      "NATIVE_OWNER_ROW_TYPE_COPY: " <>
        Diagnostics.render(%{index: corrupted.index, mfa: corrupted.mfa})
    )

    states = native_copy_states(captured)
    assert Enum.map(states.errors, & &1.rule) == [:state_helper_copy]
    assert hd(states.errors).index == corrupted.index

    for mutant <- [:stream_buffer_copy, :stream_state_copy, :stream_helper_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_helper_copy, do: [], else: [:state_helper_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(native_copy_states(captured).errors, & &1.rule) == [:state_helper_copy]
    assert native_copy_states(cached_decoders(nil)).errors == []
    IO.puts("CONNECTION_ROW_TYPE_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :driver
  test "Connection streams: native receive helpers retain their caller timeout" do
    captured =
      ComparatorMutants.with_postgrex_mutant(:receive_timeout_copy, fn -> cached_decoders(nil) end)

    [corrupted] =
      Enum.filter(captured.events, fn
        %{
          event:
            {_, :call,
             {Postgrex.Protocol, :msg_recv, [_, {:native_foreign_timeout, :infinity}, _]}}
        } ->
          true

        _ ->
          false
      end)

    states = native_copy_states(captured)
    assert Enum.map(states.errors, & &1.rule) == [:state_helper_copy]
    assert hd(states.errors).index == corrupted.index

    for mutant <- [:stream_buffer_copy, :stream_state_copy, :stream_helper_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_helper_copy, do: [], else: [:state_helper_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(native_copy_states(captured).errors, & &1.rule) == [:state_helper_copy]
    assert native_copy_states(cached_decoders(nil)).errors == []

    IO.puts(
      "CONNECTION_HELPER_TIMEOUT_COPY: owning RED; sole catcher; exact restore; fresh GREEN"
    )
  end

  defp native_copy_states(captured) do
    ConnectionStates.build(
      %{events: captured.events},
      captured.native,
      captured.decoders,
      captured.historical,
      {:initial, captured.initial}
    )
  end

  defp native_transactions do
    run = ConnectionNative.observe_transactions()
    assert run.result == :ok

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events}, run.native_history)
    assert native.errors == []
    streams = ConnectionReads.build(native)
    assert streams.errors == []
    decoders = ConnectionDecoders.build(%{events: events}, native, streams, run.native_history)
    assert decoders.errors == []

    %{
      events: events,
      native: native,
      streams: streams,
      decoders: decoders,
      historical: run.native_history,
      initial: run.initial_state
    }
  end

  @tag connection_streams: :driver
  test "Connection streams: native transaction completions bind every tag and result" do
    captured = native_transactions()
    events = captured.events

    states = native_copy_states(captured)
    assert states.errors == []

    commands =
      for %{event: {_, :return_from, {Postgrex.Protocol, :done, 2}, {result, _}}} <- events,
          do: result.command

    assert commands == [:begin, :commit, :begin, :rollback]
    covered = MapSet.new(states.terms, &{&1.index, &1.path})

    unbound =
      Enum.reject(native_helper_terms(events), fn copy ->
        MapSet.member?(covered, {copy.index, copy.path})
      end)

    for copy <- unbound do
      IO.puts("CONNECTION_TRANSACTION_TERM_UNBOUND: " <> Diagnostics.render(copy))
    end

    assert unbound == [], "transaction tags and results need their own native origins"
  end

  for mutation <- [:inputs, :result] do
    @tag connection_streams: :driver
    test "Connection streams: native transaction #{mutation} retain their command origins" do
      mutation = unquote(mutation)
      targets = %{{:done, 2} => [1], {:recv_transaction, 4} => [2]}

      captured = native_transaction_corruption(mutation, targets)

      corrupted =
        Enum.flat_map(captured.events, &transaction_corrupted_coordinates(&1, mutation, targets))

      assert corrupted != []
      states = native_copy_states(captured)

      assert Enum.map(states.errors, & &1.rule) ==
               List.duplicate(:state_helper_copy, length(corrupted))

      assert Enum.map(states.errors, &{&1.index, &1.path}) == corrupted

      for mutant <- [:stream_helper_copy, :stream_buffer_copy, :stream_error_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
        expected = if mutant == :stream_helper_copy, do: [], else: states.errors
        assert checked.errors == expected
      end

      assert native_copy_states(captured).errors == states.errors
      assert native_copy_states(native_transactions()).errors == []
      IO.puts("CONNECTION_TRANSACTION_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
    end
  end

  defp native_transaction_corruption(:inputs, targets),
    do: ComparatorMutants.with_postgrex_inputs(targets, &native_transactions/0)

  defp native_transaction_corruption(:result, _targets) do
    ComparatorMutants.with_owner_outputs(
      Postgrex.Protocol,
      %{{:done, 2} => %{size: 2, position: 0, field: :num_rows}},
      &native_transactions/0
    )
  end

  defp transaction_corrupted_coordinates(
         %{event: {_, :call, {Postgrex.Protocol, function, arguments}}} = source,
         :inputs,
         targets
       ) do
    for position <- Map.get(targets, {function, length(arguments)}, []) do
      assert match?({:native_foreign_helper, _}, Enum.at(arguments, position))
      {source.index, [2, 2, position]}
    end
  end

  defp transaction_corrupted_coordinates(
         %{event: {_, :return_from, {Postgrex.Protocol, :done, 2}, {result, _protocol}}} = source,
         :result,
         _targets
       ) do
    assert match?({:native_foreign_return, _}, result.num_rows)
    [{source.index, [3, 0]}]
  end

  defp transaction_corrupted_coordinates(_source, _mutation, _targets), do: []

  @tag connection_streams: :driver
  test "Connection streams: private status copies retain their callback origin" do
    captured =
      ComparatorMutants.with_postgrex_mutant(:status_copy, fn -> cached_decoders(nil) end)

    assert captured.native.errors == []
    assert captured.decoders.errors == []

    [corrupted] =
      Enum.filter(captured.events, fn
        %{
          event: {_, :call, {Postgrex.Protocol, :recv_ready, [_, {:native_foreign_status, _}, _]}}
        } ->
          true

        _ ->
          false
      end)

    assert Enum.any?(captured.events, fn source ->
             source.index < corrupted.index and source.mfa == {Postgrex.Protocol, :notify, 1}
           end)

    states = native_copy_states(captured)
    assert Enum.map(states.errors, & &1.rule) == [:state_status_copy]
    assert hd(states.errors).index == corrupted.index

    for mutant <- [
          :stream_buffer_copy,
          :stream_state_copy,
          :stream_helper_copy,
          :stream_status_copy
        ] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_status_copy, do: [], else: [:state_status_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(native_copy_states(captured).errors, & &1.rule) == [:state_status_copy]
    assert native_copy_states(cached_decoders(nil)).errors == []

    IO.puts("CONNECTION_STATUS_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :driver
  test "Connection streams: native error helpers retain the server error origin" do
    for shape <- [:bind_error, :execute_error] do
      captured =
        ComparatorMutants.with_postgrex_mutant(:error_copy, fn -> cached_decoders(nil, shape) end)

      assert captured.native.errors == []
      assert captured.decoders.errors == []

      [corrupted] =
        Enum.filter(captured.events, fn
          %{
            event:
              {_, :call,
               {Postgrex.Protocol, :error_ready,
                [_, _, %Postgrex.Error{message: {:native_foreign_error, _}}, _]}}
          } ->
            true

          _ ->
            false
        end)

      states = native_copy_states(captured)
      assert Enum.map(states.errors, & &1.rule) == [:state_error_copy]
      assert hd(states.errors).index == corrupted.index

      for mutant <- [:stream_buffer_copy, :stream_helper_copy, :stream_error_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
        expected = if mutant == :stream_error_copy, do: [], else: [:state_error_copy]
        assert Enum.map(checked.errors, & &1.rule) == expected
      end

      assert Enum.map(native_copy_states(captured).errors, & &1.rule) == [:state_error_copy]
      assert native_copy_states(cached_decoders(nil, shape)).errors == []
    end

    IO.puts("CONNECTION_ERROR_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :driver
  test "Connection streams: native completion inputs retain query and command origins" do
    targets = %{{:done, 4} => [1, 3], {:done, 5} => [1, 3, 4]}

    for shape <- [:rows, :none] do
      assert_native_helper_inputs(targets, fn -> cached_decoders(nil, shape) end)
    end

    IO.puts("CONNECTION_COMPLETION_INPUTS: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  for {shape, targets} <- [
        {:cross_connection, %{{:close_parse_describe_flush, 4} => [2, 3], {:msg_send, 3} => [1]}},
        {:strict, %{{:recv_strict_ready, 4} => [2]}}
      ] do
    @tag connection_streams: :driver
    test "Connection streams: native #{shape} helper inputs retain their factories" do
      shape = unquote(shape)
      targets = unquote(Macro.escape(targets))
      assert_native_helper_inputs(targets, fn -> cached_decoders(nil, shape) end)
      IO.puts("CONNECTION_PREPARE_INPUTS: owning RED; sole catcher; exact restore; fresh GREEN")
    end
  end

  @tag connection_streams: :tls
  test "Connection streams: indexed native intervals retain the entire fragmented transport proof" do
    run = ConnectionNative.observe_tls(:fragmented)

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    indexed = %{events: events}
    transports = Enum.map(run.tls_binding.families, & &1.transport)

    {linear_us, linear} =
      :timer.tc(fn ->
        NativeTransport.build(Map.put(indexed, :linear_intervals?, true), %{}, transports)
      end)

    {indexed_us, indexed_result} =
      :timer.tc(fn -> NativeTransport.build(indexed, %{}, transports) end)

    assert indexed_result === linear
    assert indexed_result.errors == []

    IO.puts(
      "NATIVE_INTERVAL_MEASUREMENT: " <>
        Diagnostics.render(%{
          linear: %{length: linear_us},
          indexed: %{length: indexed_us},
          events: %{length: length(events)}
        })
    )
  end

  @tag connection_streams: :driver
  test "Connection streams: bounded diagnostics preserve every native error coordinate" do
    captured =
      ComparatorMutants.with_postgrex_inputs(
        %{{:fetch, 2} => [0, 1]},
        fn -> native_query_factory(:array_nested_composite_array_domain_reload) end,
        Postgrex.Types
      )

    assert captured.native.errors == []
    assert captured.streams.errors == []
    assert captured.decoders.errors == []
    states = native_copy_states(captured)
    assert length(states.errors) > 1

    {plain_us, sources} = :timer.tc(fn -> Enum.map(states.errors, &Diagnostics.location/1) end)

    {indexed_us, locations} = :timer.tc(fn -> Diagnostics.locations(states.errors) end)
    assert Enum.map(states.errors, &Diagnostics.location(&1, locations)) == sources

    record = %{occurrences: List.to_tuple(states.errors)}

    expected =
      Diagnostics.render(record, pretty: false, limit: :infinity, printable_limit: :infinity)

    assert byte_size(expected) > 4096

    {truncated, truncated_digest} =
      ComparatorMutants.with_mutant(:diagnostic_record_complete, fn ->
        native_diagnostic_archive(record)
      end)

    assert byte_size(truncated) == 4096
    assert Base.encode16(:crypto.hash(:sha256, truncated), case: :lower) != truncated_digest
    {complete, digest} = native_diagnostic_archive(record)
    assert complete == expected
    assert Base.encode16(:crypto.hash(:sha256, complete), case: :lower) == digest

    IO.puts(
      "NATIVE_DIAGNOSTIC_LOCATION: " <>
        Diagnostics.render(%{plain: %{length: plain_us}, indexed: %{length: indexed_us}})
    )
  end

  defp native_diagnostic_archive(record) do
    output = ExUnit.CaptureIO.capture_io(fn -> Diagnostics.emit("NATIVE_RECORD", record) end)
    lines = String.split(output, "\n", trim: true)
    assert Enum.all?(lines, &(byte_size(&1) <= 4200))
    [begin | rest] = lines
    {chunks, [ending]} = Enum.split(rest, -1)
    "NATIVE_RECORD_GZIP_BEGIN: " <> digest = begin
    "NATIVE_RECORD_GZIP_END: " <> count = ending
    assert String.to_integer(count) == length(chunks)

    decoded =
      chunks
      |> Enum.map_join(fn "NATIVE_RECORD_GZIP_CHUNK: " <> chunk -> chunk end)
      |> Base.decode64!()
      |> :zlib.gunzip()

    {decoded, digest}
  end

  defp assert_native_helper_inputs(targets, observe, module \\ Postgrex.Protocol) do
    captured = ComparatorMutants.with_postgrex_inputs(targets, observe, module)
    assert captured.native.errors == []
    assert captured.streams.errors == []
    assert captured.decoders.errors == []

    corrupted =
      for %{event: {_, :call, {^module, function, arguments}}} = source <-
            captured.events,
          positions = Map.get(targets, {function, length(arguments)}, []),
          position <- positions do
        wrapped? = match?({:native_foreign_helper, _}, Enum.at(arguments, position))

        unless wrapped?,
          do:
            IO.puts(
              "NATIVE_HELPER_INPUT_UNWRAPPED: " <>
                Diagnostics.render(%{mfa: source.mfa, path: [2, 2, position]})
            )

        assert wrapped?,
               "native helper input must be wrapped: #{inspect(source.mfa)} argument #{position}"

        {source.index, [2, 2, position]}
      end

    assert corrupted != []

    for {function, arity} <- Map.keys(targets) do
      assert Enum.any?(captured.events, &(&1.mfa == {module, function, arity}))
    end

    states = native_copy_states(captured)

    for error <- states.errors do
      IO.puts("CONNECTION_HELPER_INPUT_STATE: " <> Diagnostics.render(error))
    end

    assert Enum.map(states.errors, & &1.rule) ==
             List.duplicate(:state_helper_copy, length(corrupted))

    assert Enum.map(states.errors, &{&1.index, &1.path}) == corrupted

    for mutant <- [:stream_buffer_copy, :stream_helper_copy, :stream_error_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_helper_copy, do: [], else: states.errors
      assert checked.errors == expected
    end

    assert native_copy_states(captured).errors == states.errors
    assert native_copy_states(observe.()).errors == []
  end

  @tag connection_streams: :driver
  test "Connection streams: frontend IOdata retains its message construction origin" do
    assert_native_helper_inputs(%{{:do_send, 3} => [1]}, &native_query_factory/0)
  end

  @tag connection_streams: :driver
  test "Connection streams: frontend IOdata shape stays exact when its bytes are unchanged" do
    captured = ComparatorMutants.with_postgrex_iodata(&native_query_factory/0)
    assert captured.native.errors == []
    assert captured.streams.errors == []
    assert captured.decoders.errors == []

    calls =
      for %{event: {_, :call, {Postgrex.Protocol, :do_send, [_protocol, data, _buffer]}}} =
            source <- captured.events do
        [original] = data
        assert data !== original

        [%{bytes: bytes}] =
          Enum.filter(captured.native.writes, fn write ->
            write.source.pid == source.pid and source.index < write.source.index and
              write.returned.index < captured.native.pairs[source.index].returned.index
          end)

        assert IO.iodata_to_binary(original) == bytes
        {source.index, [2, 2, 1]}
      end

    assert calls != []

    copies =
      for write <- captured.native.writes,
          copy <- write.copies,
          %{source: source} <- [Map.get(captured.native.pairs, copy.index)],
          source.mfa in [
            {:gen_tcp, :send, 2},
            {:prim_inet, :send, 3},
            {:prim_inet, :send, 4},
            {:erlang, :port_command, 3},
            {:erts_internal, :port_command, 3}
          ],
          do: {copy.index, copy.path}

    assert copies != []
    states = native_copy_states(captured)
    coordinates = calls ++ copies

    assert Enum.map(states.errors, & &1.rule) ==
             List.duplicate(:state_helper_copy, length(coordinates))

    assert Enum.sort(Enum.map(states.errors, &{&1.index, &1.path})) == Enum.sort(coordinates)

    for mutant <- [:stream_buffer_copy, :stream_helper_copy, :stream_error_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_helper_copy, do: [], else: states.errors
      assert checked.errors == expected
    end

    assert native_copy_states(captured).errors == states.errors
    assert native_copy_states(native_query_factory()).errors == []
  end

  for {function, arity, size, field} <- [
        {:describe_params, 3, 2, :param_oids},
        {:describe_result, 5, 2, :ref},
        {:handle_prepare, 3, 3, :columns}
      ] do
    @tag connection_streams: :driver
    test "Connection streams: native #{function} Query returns retain earlier factories" do
      function = unquote(function)
      arity = unquote(arity)
      field = unquote(field)
      target = %{size: unquote(size), position: 1, field: field}

      captured =
        ComparatorMutants.with_owner_outputs(
          Postgrex.Protocol,
          %{{function, arity} => target},
          &native_query_factory/0
        )

      assert captured.native.errors == []
      assert captured.decoders.errors == []

      corrupted =
        for %{event: {_, :return_from, {Postgrex.Protocol, ^function, ^arity}, result}} = source <-
              captured.events,
            is_tuple(result) and elem(result, 0) == :ok,
            %Postgrex.Query{} = query <- [elem(result, 1)],
            match?({:native_foreign_return, _}, Map.fetch!(query, field)),
            do: {source.index, [3, 1]}

      assert corrupted != []
      states = native_copy_states(captured)

      assert Enum.map(states.errors, & &1.rule) ==
               List.duplicate(:state_helper_copy, length(corrupted))

      assert Enum.map(states.errors, &{&1.index, &1.path}) == corrupted

      for mutant <- [:stream_buffer_copy, :stream_helper_copy, :stream_status_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
        expected = if mutant == :stream_helper_copy, do: [], else: states.errors
        assert checked.errors == expected
      end

      assert native_copy_states(captured).errors == states.errors
      assert native_copy_states(native_query_factory()).errors == []

      IO.puts(
        "CONNECTION_QUERY_FACTORY_RETURN: owning RED; sole catcher; exact restore; fresh GREEN"
      )
    end
  end

  defp native_query_factory(shape \\ :rows, prepare \\ :named, options \\ []) do
    run = ConnectionNative.observe_query_factory(shape, prepare, options)
    expected = if shape in [:prepare_error, :unsupported_type], do: shape, else: :ok
    assert run.result == expected

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events}, run.native_history)
    streams = ConnectionReads.build(native)
    decoders = ConnectionDecoders.build(%{events: events}, native, streams, run.native_history)

    %{
      run: run,
      events: events,
      native: native,
      streams: streams,
      decoders: decoders,
      historical: run.native_history,
      initial: run.initial_state
    }
  end

  for shape <- [
        :rows,
        :none,
        :prepare_error,
        :external_notify,
        :enum_reload,
        :composite_reload,
        :domain_reload,
        :domain_array_reload,
        :composite_domain_reload,
        :composite_domain_array_reload,
        :nested_composite_domain_reload,
        :nested_composite_array_domain_reload,
        :array_composite_domain_reload,
        :array_nested_composite_array_domain_reload,
        :unsupported_type
      ] do
    @tag connection_streams: :driver
    test "Connection streams: fresh native #{shape} preparation binds every helper return coordinate" do
      captured = native_query_factory(unquote(shape))
      assert_query_factory_path(captured, unquote(shape))
      assert captured.native.errors == []
      assert captured.streams.errors == []

      for error <- captured.decoders.errors do
        IO.puts("CONNECTION_PREPARATION_DECODER: " <> Diagnostics.render(error))
      end

      assert captured.decoders.errors == []
      states = native_copy_states(captured)

      for error <- states.errors do
        IO.puts("CONNECTION_PREPARATION_STATE: " <> Diagnostics.render(error))
      end

      assert states.errors == []

      for {copies, covered} <- [
            {native_helper_buffers(captured.events), states.buffers},
            {native_helper_terms(captured.events), states.terms}
          ] do
        coordinates = MapSet.new(covered, &{&1.index, &1.path})
        unbound = Enum.reject(copies, &MapSet.member?(coordinates, {&1.index, &1.path}))

        for copy <- unbound do
          IO.puts("CONNECTION_PREPARATION_COORDINATE_UNBOUND: " <> Diagnostics.render(copy))
        end

        assert unbound == [], "every fresh preparation helper coordinate needs its own origin"
      end
    end
  end

  for shape <- [:enum_reload, :composite_reload],
      prepare <- [:named, :unnamed],
      postgrex_prepare <- [false, true],
      mode <- [:transaction, :savepoint],
      {prepare, postgrex_prepare, mode} != {:named, false, :transaction} do
    @tag connection_streams: :driver
    test "Connection streams: #{shape} reload closes #{prepare}/#{postgrex_prepare}/#{mode} origins" do
      options = [postgrex_prepare: unquote(postgrex_prepare), mode: unquote(mode)]
      captured = native_query_factory(unquote(shape), unquote(prepare), options)
      assert_query_factory_path(captured, unquote(shape))

      for {stage, errors} <- [
            native: captured.native.errors,
            stream: captured.streams.errors,
            decoder: captured.decoders.errors
          ],
          error <- errors do
        row = {unquote(shape), unquote(prepare), unquote(postgrex_prepare), unquote(mode)}

        IO.puts(
          "CONNECTION_RELOAD_CAPTURE: " <>
            Diagnostics.render(%{row: row, stage: stage, difference: error})
        )
      end

      assert captured.native.errors == []
      assert captured.streams.errors == []
      assert captured.decoders.errors == []
      states = native_copy_states(captured)

      for error <- states.errors do
        IO.puts("CONNECTION_RELOAD_STATE: " <> Diagnostics.render(error))
      end

      assert states.errors == []

      for {copies, covered} <- [
            {native_helper_buffers(captured.events), states.buffers},
            {native_helper_terms(captured.events), states.terms}
          ] do
        coordinates = MapSet.new(covered, &{&1.index, &1.path})
        unbound = Enum.reject(copies, &MapSet.member?(coordinates, {&1.index, &1.path}))

        for copy <- unbound do
          IO.puts("CONNECTION_RELOAD_COORDINATE_UNBOUND: " <> Diagnostics.render(copy))
        end

        assert unbound == [], "every reload helper coordinate needs its own origin"
      end
    end
  end

  for shape <- [:prepare_error, :unsupported_type],
      prepare <- [:named, :unnamed],
      postgrex_prepare <- [false, true],
      mode <- [:transaction, :savepoint],
      {prepare, postgrex_prepare, mode} != {:named, false, :transaction} do
    @tag connection_streams: :driver
    test "Connection streams: #{shape} preparation closes #{prepare}/#{postgrex_prepare}/#{mode} errors" do
      captured =
        native_query_factory(unquote(shape), unquote(prepare),
          postgrex_prepare: unquote(postgrex_prepare),
          mode: unquote(mode)
        )

      assert_query_factory_path(captured, unquote(shape))

      if unquote(shape) == :prepare_error and unquote(postgrex_prepare) and
           unquote(mode) == :savepoint do
        broken =
          ComparatorMutants.with_mutant(:stream_error_sync, fn ->
            ConnectionReads.build(captured.native)
          end)

        assert Enum.map(broken.errors, & &1.rule) == [
                 :protocol_association,
                 :protocol_association,
                 :protocol_incomplete
               ]

        assert ConnectionReads.build(captured.native).errors == []

        fresh =
          native_query_factory(:prepare_error, unquote(prepare),
            postgrex_prepare: true,
            mode: :savepoint
          )

        assert fresh.streams.errors == []
      end

      assert_native_caller_census(captured.run)
    end
  end

  for {prepare, mode, targets} <- [
        {:named, :transaction,
         %{
           {:close_parse_describe, 3} => [2],
           {:parse_describe, 3} => [2],
           {:reload_ready, 5} => [2, 3],
           {:reload_closed, 5} => [2, 3]
         }},
        {:unnamed, :transaction,
         %{{:parse_describe_close, 3} => [2], {:reload_closed, 5} => [2, 3]}},
        {:named, :savepoint,
         %{
           {:close_parse_describe, 3} => [2],
           {:parse_describe, 3} => [2],
           {:reload_transaction, 5} => [2, 3],
           {:reload_closed, 5} => [2, 3]
         }}
      ] do
    @tag connection_streams: :driver
    test "Connection streams: prepared reload #{prepare}/#{mode} inputs retain their origins" do
      targets = unquote(Macro.escape(targets))

      assert_native_helper_inputs(targets, fn ->
        native_query_factory(:composite_reload, unquote(prepare),
          postgrex_prepare: true,
          mode: unquote(mode)
        )
      end)
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: parameter reload inputs retain both type origins" do
    assert_native_helper_inputs(%{{:reload_describe_result, 4} => [1, 2]}, fn ->
      native_query_factory(:domain_reload)
    end)
  end

  @tag connection_streams: :driver
  test "Connection streams: type lookup inputs retain each recursive accumulator origin" do
    targets = %{{:fetch_type_info, 2} => [0, 1], {:fetch_type_info, 4} => [0, 1, 2, 3]}

    assert_native_helper_inputs(targets, fn -> native_query_factory(:domain_reload) end)
  end

  @tag connection_streams: :driver
  test "Connection streams: native type lookup arguments retain OID and table origins" do
    assert_native_helper_inputs(
      %{{:fetch, 2} => [0, 1]},
      fn -> native_query_factory(:domain_reload) end,
      Postgrex.Types
    )
  end

  @tag connection_streams: :driver
  test "Connection streams: native type owner and catalog inputs retain their sources" do
    assert_native_helper_inputs(
      %{{:owner, 1} => [0], {:build_type_info, 1} => [0]},
      fn -> native_query_factory(:domain_reload) end,
      Postgrex.Types
    )
  end

  @tag connection_streams: :driver
  test "Connection streams: native type lock and update retain owner, lock and catalog origins" do
    assert_native_helper_inputs(
      %{{:fetch, 1} => [0], {:update, 3} => [0, 1, 2]},
      fn -> native_query_factory(:domain_reload) end,
      Postgrex.TypeServer
    )
  end

  for {module, function, arity, size, position, shape} <- [
        {Postgrex.Types, :fetch, 2, 2, 0, :domain_reload},
        {Postgrex.Types, :fetch, 2, 2, 1, :domain_reload},
        {Postgrex.Types, :fetch, 2, 3, 0, :unsupported_type},
        {Postgrex.Types, :fetch, 2, 3, 1, :unsupported_type},
        {Postgrex.Types, :fetch, 2, 3, 2, :unsupported_type},
        {Postgrex.Types, :owner, 1, 2, 0, :domain_reload},
        {Postgrex.Types, :owner, 1, 2, 1, :domain_reload},
        {Postgrex.Types, :build_type_info, 1, nil, nil, :domain_reload},
        {Postgrex.TypeServer, :fetch, 1, 3, 0, :domain_reload},
        {Postgrex.TypeServer, :fetch, 1, 3, 1, :domain_reload},
        {Postgrex.TypeServer, :fetch, 1, 3, 2, :domain_reload},
        {Postgrex.TypeServer, :update, 3, nil, nil, :domain_reload}
      ] do
    @tag connection_streams: :driver
    test "Connection streams: #{module}.#{function}/#{arity} #{shape} return #{position} binds its native source" do
      module = unquote(module)
      function = unquote(function)
      arity = unquote(arity)
      size = unquote(size)
      position = unquote(position)
      shape = unquote(shape)

      target =
        if is_nil(size),
          do: %{kind: :value},
          else: %{kind: :element, size: size, position: position}

      captured =
        ComparatorMutants.with_native_type_outputs(module, %{{function, arity} => target}, fn ->
          native_query_factory(shape)
        end)

      assert captured.native.errors == []
      assert captured.streams.errors == []
      assert captured.decoders.errors == []

      coordinates =
        for %{event: {_, :return_from, {^module, ^function, ^arity}, result}} = source <-
              captured.events,
            path = if(is_nil(size), do: [3], else: [3, position]),
            value = native_type_return_field(result, size, position),
            match?({:native_foreign_return, _}, value),
            do: {source.index, path}

      assert coordinates != []
      states = native_copy_states(captured)

      assert Enum.map(states.errors, & &1.rule) ==
               List.duplicate(:state_helper_copy, length(coordinates))

      assert Enum.map(states.errors, &{&1.index, &1.path}) == coordinates

      for mutant <- [:stream_buffer_copy, :stream_state_copy, :stream_helper_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
        expected = if mutant == :stream_helper_copy, do: [], else: states.errors
        assert checked.errors == expected
      end

      assert native_copy_states(captured).errors == states.errors
      assert native_copy_states(native_query_factory(shape)).errors == []
    end
  end

  defp native_type_return_field(result, nil, _position), do: result

  defp native_type_return_field(result, size, position)
       when is_tuple(result) and tuple_size(result) == size,
       do: elem(result, position)

  defp native_type_return_field(_result, _size, _position), do: :other_return

  @tag connection_streams: :pool
  test "Connection streams: native type requests retain their completed server callbacks" do
    captured = native_query_factory(:domain_reload)
    assert captured.native.errors == []
    assert captured.streams.errors == []
    pairs = NativeTransport.pairs(captured.events)

    requests =
      for {_index, pair} <- pairs,
          pair.source.mfa in [
            {Postgrex.TypeServer, :fetch, 1},
            {Postgrex.TypeServer, :update, 3}
          ],
          do: pair

    for function <- [:fetch, :update] do
      assert Enum.any?(requests, &(elem(&1.source.mfa, 1) == function))
    end

    for pair <- requests do
      {caller, :call, {_, function, [server | arguments]}} = pair.source.event
      assert is_pid(server)
      request = if function == :fetch, do: :fetch, else: List.to_tuple([:update | arguments])

      callback =
        Enum.find(captured.events, fn
          %{
            pid: ^server,
            event: {_, :call, {Postgrex.TypeServer, :handle_call, [actual, {^caller, _}, _]}}
          } = source ->
            actual === request and source.index > pair.source.index and
              source.index < pair.returned.index

          _ ->
            false
        end)

      assert callback, "every native type request needs its actual server callback"
      assert Map.has_key?(pairs, callback.index)

      # The update sends its reply before next/1 finishes. Completion is owed
      # by the terminal drain, rather than an invented callback-before-reply edge.
      assert elem(pairs[callback.index].returned.event, 1) == :return_from
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: savepoint tags retain the active transaction receive origin" do
    targets = %{{:recv_transaction, 4} => [2], {:done, 2} => [1]}

    assert_native_helper_inputs(targets, fn ->
      native_query_factory(:composite_reload, :named, mode: :savepoint)
    end)
  end

  for {kind, owner} <- [
        message: {Postgrex.Protocol, :msg_recv, 3},
        rows: {Postgrex.Protocol, :rows_recv, 4}
      ] do
    @tag connection_streams: :driver
    test "Connection streams: an extra no-progress #{kind} decoder remains observable" do
      kind = unquote(kind)

      captured =
        ComparatorMutants.with_postgrex_repeated_decoder(kind, fn ->
          native_decoder_program(kind)
        end)

      assert captured.native.errors == []
      assert captured.streams.errors == []
      pairs = NativeTransport.pairs(captured.events)

      duplicated =
        for {_index, %{source: owner, returned: terminal}} <- pairs,
            owner.mfa == unquote(Macro.escape(owner)),
            children =
              Enum.filter(captured.decoders.instances, fn instance ->
                instance.source.pid == owner.pid and instance.source.index > owner.index and
                  instance.returned.index < terminal.index and
                  instance.source.stack == [owner.mfa | owner.stack]
              end),
            length(children) == 2,
            Enum.all?(
              children,
              &(elem(&1.expected, 0) == :more and &1.start == &1.stop and &1.input == <<>>)
            ),
            do: owner.index

      assert duplicated != [], "the loaded native program must repeat a no-progress decoder"

      for error <- captured.decoders.errors do
        IO.puts("CONNECTION_DECODER_PROGRAM: " <> Diagnostics.render(error))
      end

      assert Enum.map(captured.decoders.errors, & &1.rule) ==
               List.duplicate(:decoder_program, length(duplicated))

      assert Enum.map(captured.decoders.errors, & &1.index) == Enum.sort(duplicated)

      # Rebuild from these same raw events and genuine native facts. Disabling
      # only the program obligation must admit precisely this extra execution.
      for mutant <- [:stream_decoder_program, :stream_buffer_copy, :stream_helper_copy] do
        checked =
          ComparatorMutants.with_mutant(mutant, fn ->
            ConnectionDecoders.build(
              %{events: captured.events},
              captured.native,
              captured.streams,
              captured.native.historical
            )
          end)

        expected = if mutant == :stream_decoder_program, do: [], else: captured.decoders.errors
        assert checked.errors == expected
      end

      restored =
        ConnectionDecoders.build(
          %{events: captured.events},
          captured.native,
          captured.streams,
          captured.native.historical
        )

      assert restored.errors == captured.decoders.errors
      assert native_decoder_program(kind).decoders.errors == []
    end
  end

  defp native_decoder_program(:message), do: native_query_factory(:rows)

  defp native_decoder_program(:rows) do
    # Execute on an already bound cursor enters rows_recv directly with the
    # preceding ReadyForQuery's empty buffer, before its first real socket read.
    run = ConnectionNative.observe_cursor()
    assert run.result == [[1], [2], [3]]

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events}, run.native_history)
    streams = ConnectionReads.build(native)
    decoders = ConnectionDecoders.build(%{events: events}, native, streams, run.native_history)
    %{events: events, native: native, streams: streams, decoders: decoders}
  end

  @tag connection_streams: :driver
  test "Connection streams: reload inputs retain parent, catalog and reference origins" do
    targets = %{{:reload_spawn, 5} => [1, 2, 3], {:reload_init, 5} => [1, 2, 3]}

    captured =
      ComparatorMutants.with_postgrex_inputs(targets, fn ->
        native_query_factory(:composite_reload)
      end)

    assert captured.native.errors == []
    assert captured.streams.errors == []
    assert captured.decoders.errors == []

    coordinates =
      for %{event: {_, :call, {Postgrex.Protocol, function, arguments}}} = source <-
            captured.events,
          position <- Map.get(targets, {function, length(arguments)}, []) do
        assert match?({:native_foreign_helper, _}, Enum.at(arguments, position))
        {source.index, [2, 2, position]}
      end

    for {function, arity} <- Map.keys(targets) do
      assert Enum.any?(captured.events, &(&1.mfa == {Postgrex.Protocol, function, arity}))
    end

    assert coordinates != []
    states = native_copy_states(captured)

    for error <- states.errors do
      IO.puts("CONNECTION_RELOAD_INPUT_STATE: " <> Diagnostics.render(error))
    end

    assert Enum.map(states.errors, & &1.rule) ==
             List.duplicate(:state_helper_copy, length(coordinates))

    assert Enum.map(states.errors, &{&1.index, &1.path}) == coordinates

    for mutant <- [:stream_buffer_copy, :stream_state_copy, :stream_helper_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_helper_copy, do: [], else: states.errors
      assert checked.errors == expected
    end

    assert native_copy_states(captured).errors == states.errors
    assert native_copy_states(native_query_factory(:composite_reload)).errors == []
    IO.puts("CONNECTION_RELOAD_INPUTS: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  defp assert_query_factory_path(captured, shape)
       when shape in [
              :enum_reload,
              :composite_reload,
              :domain_reload,
              :domain_array_reload,
              :composite_domain_reload,
              :composite_domain_array_reload,
              :nested_composite_domain_reload,
              :nested_composite_array_domain_reload,
              :array_composite_domain_reload,
              :array_nested_composite_array_domain_reload
            ] do
    assert captured.run.result == :ok

    for mfa <- [{Postgrex.Protocol, :reload_spawn, 5}, {Postgrex.Protocol, :reload_init, 5}] do
      assert Enum.any?(captured.events, &(&1.mfa == mfa and elem(&1.event, 1) == :call))
    end

    assert Enum.any?(captured.events, fn
             %{event: {_, :return_from, {Postgrex.Types, :fetch, 2}, {:error, nil, _}}} -> true
             _ -> false
           end)

    assert_reload_domains(captured, shape)
  end

  defp assert_query_factory_path(captured, :unsupported_type) do
    assert captured.run.result == :unsupported_type

    assert Enum.any?(captured.events, fn
             %{
               event:
                 {_, :return_from, {Postgrex.Protocol, :handle_prepare, 3},
                  {:disconnect, %Postgrex.QueryError{}, %Postgrex.Protocol{}}}
             } ->
               true

             _ ->
               false
           end)

    assert Enum.any?(captured.events, fn
             %{
               event:
                 {_, :return_from, {Postgrex.Types, :fetch, 2}, {:error, %Postgrex.TypeInfo{}, _}}
             } ->
               true

             _ ->
               false
           end)
  end

  defp assert_query_factory_path(captured, :prepare_error),
    do: assert(captured.run.result == :prepare_error)

  defp assert_query_factory_path(captured, _shape), do: assert(captured.run.result == :ok)

  defp assert_reload_domains(_captured, shape) when shape in [:enum_reload, :composite_reload],
    do: :ok

  defp assert_reload_domains(captured, shape) do
    infos =
      for instance <- captured.decoders.instances,
          {Postgrex.Protocol, :reload_init, 5} in instance.source.stack,
          {:ok, {:msg_data_row, values}, _buffer} <- [instance.expected],
          do: ConnectionTypes.catalog(values)

    assert Enum.any?(infos, &(&1.category == :domain and &1.base_type != 0))

    if shape not in [:domain_reload, :domain_array_reload],
      do: assert(Enum.any?(infos, &(&1.category == :composite and &1.comp_elems != [])))
  end

  @tag connection_streams: :driver
  test "Connection streams: explicit native ping options retain callback, buffer and timeout origins" do
    run = ConnectionNative.observe_ping_options()
    assert run.result == :ok
    assert Enum.any?(run.events, &(&1.mfa == {Postgrex.Protocol, :ping, 2}))
    assert_native_caller_census(run)
  end

  @tag connection_streams: :driver
  test "Connection streams: native prepare cache hits, reprepare and invalidation retain origins" do
    run = ConnectionNative.observe_prepare_cycle()
    assert {first, cached, reparsed, renewed} = run.result
    assert Enum.all?([first, cached, reparsed, renewed], &is_reference/1)
    assert first == cached
    assert length(Enum.uniq([first, reparsed, renewed])) == 3
    assert_native_caller_census(run)
  end

  defp assert_native_caller_census(run) do
    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events}, run.native_history)
    assert native.errors == []
    streams = ConnectionReads.build(native)
    assert streams.errors == []
    decoders = ConnectionDecoders.build(%{events: events}, native, streams, run.native_history)

    for error <- decoders.errors do
      IO.puts("CONNECTION_CALLER_DECODER: " <> Diagnostics.render(error))
    end

    assert decoders.errors == []

    states =
      ConnectionStates.build(
        %{events: events},
        native,
        decoders,
        run.native_history,
        {:initial, run.initial_state}
      )

    for error <- states.errors do
      IO.puts("CONNECTION_CALLER_STATE: " <> Diagnostics.render(error))
    end

    assert states.errors == []

    for {copies, covered} <- [
          {native_helper_buffers(events), states.buffers},
          {native_helper_terms(events), states.terms}
        ] do
      coordinates = MapSet.new(covered, &{&1.index, &1.path})
      unbound = Enum.reject(copies, &MapSet.member?(coordinates, {&1.index, &1.path}))

      for copy <- unbound do
        IO.puts("CONNECTION_CALLER_COORDINATE_UNBOUND: " <> Diagnostics.render(copy))
      end

      assert unbound == [], "every native caller helper coordinate needs its own origin"
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: native cursor callbacks bind each operation and suspended result" do
    run = ConnectionNative.observe_cursor()
    assert run.result == [[1], [2], [3]]

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    for function <- [
          :handle_prepare,
          :handle_declare,
          :handle_fetch,
          :handle_deallocate,
          :handle_close
        ] do
      assert Enum.any?(events, fn source ->
               match?({_, :call, {Postgrex.Protocol, ^function, _}}, source.event)
             end)
    end

    assert_native_caller_census(run)
  end

  for {function, arity, size, position} <- [
        {:describe, 7, 4, 3},
        {:recv_describe, 4, 7, 6},
        {:reload_describe_result, 4, 4, 3}
      ] do
    @tag connection_streams: :driver
    test "Connection streams: native #{function} return buffers retain decoder origins" do
      function = unquote(function)
      arity = unquote(arity)
      size = unquote(size)
      position = unquote(position)
      target = %{kind: :element, size: size, position: position}

      captured =
        ComparatorMutants.with_owner_outputs(
          Postgrex.Protocol,
          %{{function, arity} => target},
          fn -> native_return_factory(function) end
        )

      assert captured.native.errors == []
      assert captured.decoders.errors == []

      corrupted =
        for %{event: {_, :return_from, {Postgrex.Protocol, ^function, ^arity}, result}} = source <-
              captured.events,
            is_tuple(result) and tuple_size(result) == size,
            match?({:native_foreign_return, _}, elem(result, position)) do
          {source.index, [3, position]}
        end

      assert corrupted != []
      states = native_copy_states(captured)

      assert Enum.map(states.errors, & &1.rule) ==
               List.duplicate(:state_buffer_copy, length(corrupted))

      assert Enum.map(states.errors, &{&1.index, &1.path}) == corrupted

      for mutant <- [:stream_buffer_copy, :stream_helper_copy, :stream_status_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
        expected = if mutant == :stream_buffer_copy, do: [], else: states.errors
        assert checked.errors == expected
      end

      assert native_copy_states(captured).errors == states.errors
      assert native_copy_states(native_return_factory(function)).errors == []

      IO.puts(
        "CONNECTION_QUERY_BUFFER_RETURN: owning RED; sole catcher; exact restore; fresh GREEN"
      )
    end
  end

  for {function, arity, size, position} <- [
        {:recv_describe, 4, 7, 1},
        {:recv_describe, 4, 7, 2},
        {:recv_describe, 4, 7, 3},
        {:recv_describe, 4, 7, 4},
        {:fetch_type_info, 4, 2, 1},
        {:reload_describe_result, 4, 4, 0},
        {:reload_describe_result, 4, 4, 1},
        {:columns, 1, 3, 0},
        {:columns, 1, 3, 1},
        {:columns, 1, 3, 2}
      ] do
    @tag connection_streams: :driver
    test "Connection streams: native #{function} return field #{position} retains its own origin" do
      function = unquote(function)
      arity = unquote(arity)
      size = unquote(size)
      position = unquote(position)

      target = %{
        kind: :element,
        size: size,
        position: position,
        total?: unquote(function == :fetch_type_info)
      }

      captured =
        ComparatorMutants.with_owner_outputs(
          Postgrex.Protocol,
          %{{function, arity} => target},
          fn -> native_return_factory(function) end
        )

      assert captured.native.errors == []
      assert captured.decoders.errors == []

      corrupted =
        for %{event: {_, :return_from, {Postgrex.Protocol, ^function, ^arity}, result}} = source <-
              captured.events,
            is_tuple(result) and tuple_size(result) == size,
            match?({:native_foreign_return, _}, elem(result, position)),
            do: {source.index, [3, position]}

      assert corrupted != []
      states = native_copy_states(captured)

      assert Enum.map(states.errors, & &1.rule) ==
               List.duplicate(:state_helper_copy, length(corrupted))

      assert Enum.map(states.errors, &{&1.index, &1.path}) == corrupted

      for mutant <- [:stream_buffer_copy, :stream_helper_copy, :stream_status_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
        expected = if mutant == :stream_helper_copy, do: [], else: states.errors
        assert checked.errors == expected
      end

      assert native_copy_states(captured).errors == states.errors
      assert native_copy_states(native_return_factory(function)).errors == []
      IO.puts("CONNECTION_QUERY_METADATA_RETURN: owning RED; sole catcher; restore; fresh GREEN")
    end
  end

  defp native_return_factory(:reload_describe_result), do: native_query_factory(:domain_reload)
  defp native_return_factory(_function), do: native_query_factory()

  @tag connection_streams: :driver
  test "Connection streams: notify factories retain their native code and empty environment" do
    captured =
      ComparatorMutants.with_owner_outputs(
        Postgrex.Protocol,
        %{{:notify, 1} => %{kind: :factory}},
        fn ->
          cached_decoders(nil)
        end
      )

    corrupted =
      for %{event: {_, :return_from, {Postgrex.Protocol, :notify, 1}, callback}} = source <-
            captured.events do
        assert is_function(callback, 2)
        assert {:env, [original]} = Function.info(callback, :env)
        assert is_function(original, 2)
        source.index
      end

    assert corrupted != []
    states = native_copy_states(captured)

    assert Enum.map(states.errors, & &1.rule) ==
             List.duplicate(:state_status_factory_value, length(corrupted))

    assert Enum.map(states.errors, & &1.index) == corrupted

    for mutant <- [:stream_factory_value, :stream_status_copy, :stream_helper_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_factory_value, do: [], else: states.errors
      assert checked.errors == expected
    end

    assert native_copy_states(captured).errors == states.errors
    assert native_copy_states(cached_decoders(nil)).errors == []
    IO.puts("CONNECTION_NOTIFY_FACTORY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :driver
  test "Connection streams: unsolicited helper messages cannot supply their expected state" do
    for shape <- [:notice, :parameter, :notification] do
      captured =
        ComparatorMutants.with_postgrex_inputs(%{{:handle_msg, 3} => [2]}, fn ->
          cached_decoders(nil, shape)
        end)

      corrupted =
        for %{event: {_, :call, {Postgrex.Protocol, :handle_msg, [_, _, message]}}} = source <-
              captured.events do
          assert match?({:native_foreign_helper, _}, message)
          {source.index, [2, 2, 2]}
        end

      assert corrupted != []
      states = native_copy_states(captured)

      assert Enum.map(states.errors, & &1.rule) ==
               List.duplicate(:state_message_copy, length(corrupted))

      assert Enum.map(states.errors, &{&1.index, &1.path}) == corrupted

      for mutant <- [:stream_message_copy, :stream_helper_copy, :stream_error_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
        expected = if mutant == :stream_message_copy, do: [], else: states.errors
        assert checked.errors == expected
      end

      assert native_copy_states(captured).errors == states.errors
      assert native_copy_states(cached_decoders(nil, shape)).errors == []
    end

    IO.puts("CONNECTION_UNSOLICITED_INPUTS: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  for {shape, target, output} <- [
        {:rows, {:done, 5}, %{size: 2, position: 0, field: :num_rows}},
        {:redescribe, {:redescribe, 6}, %{size: 4, position: 1, field: :columns}},
        {:bind_error, {:error_ready, 4}, %{size: 3, position: 1, field: :message}}
      ] do
    @tag connection_streams: :driver
    test "Connection streams: #{elem(target, 0)}/#{elem(target, 1)} returns retain earlier inputs" do
      shape = unquote(shape)
      {function, arity} = target = unquote(Macro.escape(target))
      output = unquote(Macro.escape(output))

      captured =
        ComparatorMutants.with_owner_outputs(Postgrex.Protocol, %{target => output}, fn ->
          cached_decoders(nil, shape)
        end)

      corrupted =
        for %{event: {_, :return_from, {Postgrex.Protocol, ^function, ^arity}, result}} = source <-
              captured.events,
            is_tuple(result),
            tuple_size(result) == output.size,
            record = elem(result, output.position),
            is_map(record),
            match?({:native_foreign_return, _}, Map.get(record, output.field)),
            do: {source.index, [3, output.position]}

      assert corrupted != []
      states = native_copy_states(captured)

      assert Enum.map(states.errors, & &1.rule) ==
               List.duplicate(:state_helper_copy, length(corrupted))

      assert Enum.map(states.errors, &{&1.index, &1.path}) == corrupted

      for mutant <- [:stream_helper_copy, :stream_buffer_copy, :stream_error_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
        expected = if mutant == :stream_helper_copy, do: [], else: states.errors
        assert checked.errors == expected
      end

      assert native_copy_states(captured).errors == states.errors
      assert native_copy_states(cached_decoders(nil, shape)).errors == []

      IO.puts("CONNECTION_HELPER_RETURNS: owning RED; sole catcher; exact restore; fresh GREEN")
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: completed rows retain their earlier decoder origin" do
    captured =
      ComparatorMutants.with_postgrex_mutant(:done_rows_copy, fn -> cached_decoders(nil) end)

    assert captured.native.errors == []
    assert captured.decoders.errors == []

    [corrupted] =
      Enum.filter(captured.events, fn
        %{
          event:
            {_, :call, {Postgrex.Protocol, :done, [_, _, {:native_foreign_done_rows, _}, _, _]}}
        } ->
          true

        _ ->
          false
      end)

    states = native_copy_states(captured)
    assert Enum.map(states.errors, & &1.rule) == [:state_helper_copy]
    assert hd(states.errors).index == corrupted.index

    for mutant <- [:stream_buffer_copy, :stream_state_copy, :stream_helper_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_helper_copy, do: [], else: [:state_helper_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(native_copy_states(captured).errors, & &1.rule) == [:state_helper_copy]
    assert native_copy_states(cached_decoders(nil)).errors == []
    IO.puts("CONNECTION_DONE_ROWS_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :driver
  test "Connection streams: encoded send messages retain their earlier caller origin" do
    captured =
      ComparatorMutants.with_postgrex_mutant(:send_message_copy, fn -> cached_decoders(nil) end)

    assert captured.native.errors == []
    assert captured.decoders.errors == []

    [corrupted] =
      Enum.filter(captured.events, fn
        %{
          event:
            {_, :call, {Postgrex.Protocol, :msg_send, [_, [{:native_foreign_messages, _}], _]}}
        } ->
          true

        _ ->
          false
      end)

    states = native_copy_states(captured)
    assert Enum.map(states.errors, & &1.rule) == [:state_helper_copy]
    assert hd(states.errors).index == corrupted.index

    for mutant <- [:stream_buffer_copy, :stream_state_copy, :stream_helper_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> native_copy_states(captured) end)
      expected = if mutant == :stream_helper_copy, do: [], else: [:state_helper_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(native_copy_states(captured).errors, & &1.rule) == [:state_helper_copy]
    assert native_copy_states(cached_decoders(nil)).errors == []
    IO.puts("CONNECTION_SEND_MESSAGES_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :driver
  test "Connection streams: private send buffers retain their native owner copy" do
    captured =
      ComparatorMutants.with_postgrex_mutant(:send_buffer_copy, fn -> cached_decoders(nil) end)

    assert captured.native.errors == []
    assert captured.decoders.errors == []

    [corrupted] =
      Enum.filter(captured.events, fn
        %{event: {_, :call, {Postgrex.Protocol, :msg_send, [_protocol, _messages, <<0>>]}}} ->
          true

        _ ->
          false
      end)

    IO.puts(
      "NATIVE_OWNER_SEND_BUFFER_COPY: " <>
        Diagnostics.render(%{index: corrupted.index, mfa: corrupted.mfa, length: 1})
    )

    states =
      ConnectionStates.build(
        %{events: captured.events},
        captured.native,
        captured.decoders,
        captured.historical,
        {:initial, captured.initial}
      )

    assert Enum.map(states.errors, & &1.rule) == [:state_buffer_copy]
    assert hd(states.errors).index == corrupted.index

    for mutant <- [:stream_state_copy, :stream_length, :stream_timeout, :stream_buffer_copy] do
      checked =
        ComparatorMutants.with_mutant(mutant, fn ->
          ConnectionStates.build(
            %{events: captured.events},
            captured.native,
            captured.decoders,
            captured.historical,
            {:initial, captured.initial}
          )
        end)

      expected = if mutant == :stream_buffer_copy, do: [], else: [:state_buffer_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    restored =
      ConnectionStates.build(
        %{events: captured.events},
        captured.native,
        captured.decoders,
        captured.historical,
        {:initial, captured.initial}
      )

    assert Enum.map(restored.errors, & &1.rule) == [:state_buffer_copy]
    fresh = cached_decoders(nil)

    positive =
      ConnectionStates.build(
        %{events: fresh.events},
        fresh.native,
        fresh.decoders,
        fresh.historical,
        {:initial, fresh.initial}
      )

    assert positive.errors == []

    IO.puts(
      "CONNECTION_PRIVATE_BUFFER_COPY: owning RED; sole catcher; exact restore; fresh GREEN"
    )
  end

  @tag connection_streams: :driver
  test "Connection streams: callback inputs bind to their actual owner state" do
    captured = cached_decoders(:state_copy)

    rejected =
      ConnectionStates.build(
        %{events: captured.events},
        captured.native,
        captured.decoders,
        captured.historical,
        {:initial, captured.initial}
      )

    assert Enum.map(rejected.errors, & &1.rule) == [:state_input_copy]
    [failure] = rejected.errors
    source = Enum.fetch!(captured.events, failure.index)
    assert source.mfa == {Postgrex.Protocol, :handle_execute, 4}
    assert elem(source.event, 1) == :call

    for mutant <- [:stream_length, :stream_timeout, :stream_required, :stream_state_copy] do
      checked =
        ComparatorMutants.with_mutant(mutant, fn ->
          ConnectionStates.build(
            %{events: captured.events},
            captured.native,
            captured.decoders,
            captured.historical,
            {:initial, captured.initial}
          )
        end)

      expected = if mutant == :stream_state_copy, do: [], else: [:state_input_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(
             ConnectionStates.build(
               %{events: captured.events},
               captured.native,
               captured.decoders,
               captured.historical,
               {:initial, captured.initial}
             ).errors,
             & &1.rule
           ) == [:state_input_copy]

    restored = cached_decoders(nil)

    accepted =
      ConnectionStates.build(
        %{events: restored.events},
        restored.native,
        restored.decoders,
        restored.historical,
        {:initial, restored.initial}
      )

    assert accepted.errors == []
    IO.puts("CONNECTION_STATE_INPUT_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :pool
  test "Connection streams: holder writes bind to the callback return that owns their state" do
    {captured, rejected} = holder_states(:state_copy)
    assert Enum.map(rejected.errors, & &1.rule) == [:state_holder_update]
    [failure] = rejected.errors
    assert Enum.fetch!(captured.events, failure.index).mfa == {:ets, :update_element, 3}

    for mutant <- [:stream_state_copy, :stream_state_holder_update] do
      checked =
        ComparatorMutants.with_mutant(mutant, fn ->
          ConnectionStates.build(
            %{events: captured.events},
            captured.native,
            captured.decoders,
            captured.historical,
            {:initial, captured.initial}
          )
        end)

      expected = if mutant == :stream_state_holder_update, do: [], else: [:state_holder_update]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    {_captured, restored} = holder_states(:state_copy)
    assert Enum.map(restored.errors, & &1.rule) == [:state_holder_update]
    {_captured, positive} = holder_states(nil)
    assert positive.errors == []
    assert Enum.any?(positive.copies, &(&1.path == [2, 2, 2, 0, 1]))

    IO.puts("CONNECTION_STATE_HOLDER_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :pool
  test "Connection streams: history cuts retain committed holder rows, not temporary outputs" do
    parent = self()
    token = make_ref()

    {observer, monitor} =
      spawn_monitor(fn ->
        parent_monitor = Process.monitor(parent)
        holder_observer(parent, token, parent_monitor)
      end)

    try do
      {captured, states} = holder_states({:committed_history, observer, token})
      assert states.errors == []

      snapshots =
        for phase <- [
              :uncommitted_checkin,
              :committed_checkin,
              :uncommitted_checkout,
              :committed_checkout
            ],
            into: %{} do
          receive do
            {:native_holder_snapshot, ^token, ^phase, holder, row} -> {phase, {holder, row}}
          after
            0 -> flunk("the independent observer did not retain every live holder row")
          end
        end

      {_holder, before_checkin} = snapshots.uncommitted_checkin
      {_holder, after_checkin} = snapshots.committed_checkin
      {_holder, before_checkout} = snapshots.uncommitted_checkout
      {_holder, after_checkout} = snapshots.committed_checkout
      assert is_binary(elem(before_checkin, 3).buffer)
      assert elem(after_checkin, 3).buffer == :active_once
      assert elem(before_checkout, 3).buffer == :active_once
      assert is_binary(elem(after_checkout, 3).buffer)

      history? = Map.has_key?(states, :commits)
      assert history?, "the native committed-history ledger is absent"
      commits = Map.fetch!(states, :commits)

      barriers =
        Enum.filter(captured.events, fn
          %{event: {_, :receive, {:native_holder_cut, ^token, _phase, :observed}}} -> true
          _ -> false
        end)

      assert length(barriers) == map_size(snapshots)

      for {phase, {holder, row}} <- snapshots do
        [barrier] =
          Enum.filter(barriers, fn
            %{event: {_, :receive, {:native_holder_cut, ^token, ^phase, :observed}}} -> true
            _ -> false
          end)

        committed =
          commits
          |> Enum.filter(&(&1.holder == holder and &1.index < barrier.index))
          |> Enum.max_by(& &1.index, fn -> nil end)

        assert committed, "every live-read cut needs its preceding committed holder row"
        same_row? = committed.row === row
        assert same_row?, "the cut must equal all eight fields of the independently read ETS row"
      end
    after
      send(observer, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^observer, reason} ->
          stopped_normally? = reason === :normal
          assert stopped_normally?, "the independent holder observer must stop normally"
      after
        5_000 ->
          Process.exit(observer, :kill)
          flunk("the native holder observer did not stop")
      end
    end
  end

  @tag connection_streams: :driver
  @tag prepare: :named
  test "Connection streams: history cuts retain native and Ecto committed query caches",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)
    cache_table = historical.query_cache.table
    holders = Map.keys(historical.connections)

    tables =
      [
        historical.query_cache.table
        | Enum.map(historical.connections, fn {_holder, connection} ->
            connection.protocol.queries
          end)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    parent = self()
    token = make_ref()

    {observer, monitor} =
      spawn_monitor(fn ->
        parent_monitor = Process.monitor(parent)
        holder_observer(parent, token, parent_monitor)
      end)

    try do
      run =
        ExitBoundary.observe(
          fn -> Repo.put_dynamic_repo(context.repo) end,
          fn _ ->
            Repo.checkout(fn ->
              SQL.query!(context.repo, "SELECT 23::int4 AS native_cache_history", [],
                cache_statement: "native_committed_history"
              )

              table_barrier(observer, token, tables, holders, :native)

              Repo.all(from(c in "pg_class", prefix: "pg_catalog", select: count(c.oid)))

              # Compete for an existing real Ecto cache key. The unsuccessful
              # candidate must never replace the independently observed row.
              cached =
                Enum.find(:ets.tab2list(cache_table), fn
                  {_, :cached, _, {_, %Postgrex.Query{}}} -> true
                  _ -> false
                end)

              {key, :cached, selection, {_id, query}} = cached

              prepared =
                {System.unique_integer([:positive]), IO.iodata_to_binary(query.statement)}

              false = :ets.insert_new(cache_table, {key, :cache, selection, prepared})

              table_barrier(observer, token, tables, holders, :ecto)

              Repo.all(from(c in "pg_class", prefix: "pg_catalog", select: count(c.relname)))

              table_barrier(observer, token, tables, holders, :later)

              SQL.query!(context.repo, "SELECT $1::int4 AS pending_cache_history", [29],
                cache_statement: "pending_native_description"
              )

              SQL.query!(
                context.repo,
                "SELECT repeat('x', 1048576) AS partial_frame_history",
                [],
                cache_statement: "partial_native_frame"
              )

              :ok
            end)
          end,
          %{host: [], callbacks: []}
        )

      assert run.result == :ok
      events = Enum.with_index(run.events, &Map.put(&1, :index, &2))
      indexed = %{events: events, query_cache: historical.query_cache}
      native = NativeTransport.build(indexed, historical.connections)
      assert native.errors == []
      reads = ConnectionReads.build(native, MapSet.new(), historical.connection_protocols)
      assert reads.errors == []

      decoders =
        ConnectionDecoders.build(
          indexed,
          native,
          reads,
          historical.connections,
          historical.query_origins
        )

      assert decoders.errors == []

      states =
        ConnectionStates.build(
          indexed,
          native,
          decoders,
          historical.connections,
          {:initial, run.initial_state}
        )

      assert states.errors == []

      snapshots =
        for phase <- [:native, :ecto, :later], into: %{} do
          receive do
            {:native_tables_snapshot, ^token, ^phase, rows} -> {phase, rows}
          after
            0 -> flunk("the independent observer did not retain every live cache table")
          end
        end

      ecto = historical.query_cache.table
      assert snapshots.native[ecto] !== snapshots.ecto[ecto]
      assert snapshots.ecto[ecto] !== snapshots.later[ecto]

      native_changed? =
        Enum.any?(historical.connections, fn {_holder, connection} ->
          cache = connection.query_cache
          cache.table && Enum.sort(cache.rows) !== snapshots.native[cache.table]
        end)

      assert native_changed?, "the native query must commit its prepared cache row"
      history? = Map.has_key?(states, :table_commits)
      assert history?, "the native and Ecto committed-cache ledger is absent"
      commits = Map.fetch!(states, :table_commits)

      for {phase, tables} <- snapshots do
        [barrier] =
          Enum.filter(events, fn
            %{event: {_, :receive, {:native_tables_cut, ^token, ^phase, :observed}}} -> true
            _ -> false
          end)

        for {table, rows} <- tables do
          committed =
            commits
            |> Enum.filter(&(&1.table == table and &1.index < barrier.index))
            |> Enum.max_by(& &1.index, fn -> nil end)

          assert committed, "every live-read cut needs its preceding committed cache table"
          same_rows? = Enum.sort(committed.rows) === rows

          assert same_rows?,
                 "a cache cut must equal the independent live read and exclude later writes"
        end
      end

      cut? = function_exported?(Historical, :cut, 3)
      assert cut?, "the full committed connection-history cut is absent"
      cut = Function.capture(Historical, :cut, 3)

      proof = %{
        native: native,
        reads: reads,
        decoders: decoders,
        states: states,
        native_roots: historical.connections,
        program_events: events
      }

      writes =
        for {_index, pair} <- native.pairs,
            {_, :call, {:ets, function, [table | _arguments]}} <- [pair.source.event],
            table in tables,
            function in [:insert, :insert_new, :update_element, :delete],
            {_, :return_from, _, true} <- [pair.returned.event],
            do: pair

      assert writes != [], "the cut witness must contain successful native cache writes"

      for pair <- writes do
        assert {:error, %{rule: :cut_inflight_native_write, index: index}} =
                 cut.(historical, proof, pair.returned.index)

        assert index == pair.source.index
      end

      for {phase, tables} <- snapshots do
        [barrier] =
          Enum.filter(events, fn
            %{event: {_, :receive, {:native_tables_cut, ^token, ^phase, :observed}}} -> true
            _ -> false
          end)

        assert {:ok, checkpoint} = cut.(historical, proof, barrier.index)
        same_cache? = Enum.sort(checkpoint.query_cache.rows) === tables[ecto]
        assert same_cache?, "the full cut must use the committed Ecto cache at its own barrier"

        holder_rows =
          receive do
            {:native_holder_tables_snapshot, ^token, ^phase, rows} -> rows
          after
            0 -> flunk("the independent observer did not retain every full holder table")
          end

        for {holder, [row]} <- holder_rows do
          connection = Map.fetch!(checkpoint.connections, holder)

          expected =
            {:conn, connection.owner, Postgrex.Protocol, connection.protocol, connection.lock,
             connection.clock, connection.deadline, connection.status}

          same_holder? = row === expected

          assert same_holder?,
                 "the full cut must retain all eight independently read holder fields"
        end

        {backend, catalog_rows} =
          receive do
            {:native_catalog_snapshot, ^token, ^phase, backend, rows} -> {backend, rows}
          after
            0 -> flunk("the real connection did not retain its server-side prepared catalog")
          end

        [connection] =
          for {_holder, connection} <- checkpoint.connections,
              connection.protocol.connection_id == backend,
              do: connection

        {:gen_tcp, port} = connection.protocol.sock

        catalog =
          checkpoint.prepared_catalogs
          |> Map.fetch!(port)
          |> Enum.reject(fn {name, _context} -> name == "" end)
          |> Map.new(fn {name, context} -> {name, {context.sql, context.parameter_types}} end)

        server_catalog = Map.new(catalog_rows, fn [name, sql, types] -> {name, {sql, types}} end)
        same_catalog? = catalog === server_catalog
        assert same_catalog?, "the full cut must equal the actual server's prepared catalog"

        for {_holder, connection} <- checkpoint.connections,
            table = connection.query_cache.table,
            not is_nil(table) do
          same_native? = Enum.sort(connection.query_cache.rows) === tables[table]

          assert same_native?,
                 "the full cut must use each committed native cache at its own barrier"

          for {_name, _ref, %Postgrex.Query{} = query} <- tables[table] do
            described? = Enum.any?(connection.descriptors, &(&1.query === query))

            if not described? do
              preparations =
                for origin <- historical.query_preparations,
                    origin.query.ref === query.ref do
                  %{
                    mfa: origin.mfa,
                    same_socket?: origin.sock === connection.protocol.sock,
                    same_types?: origin.query.types === connection.protocol.types,
                    same_parameters?: origin.parameters === query.param_oids,
                    same_query?: origin.query === query
                  }
                end

              baseline? =
                Enum.any?(historical.connections, fn {_holder, original} ->
                  original.query_cache.table === table and
                    Enum.any?(original.query_cache.rows, fn
                      {_name, _ref, cached} -> cached === query
                      _ -> false
                    end)
                end)

              insertions =
                for {_index, pair} <- native.pairs,
                    {_, :call, {:ets, :insert, [^table, {_name, _ref, cached}]}} <-
                      [pair.source.event],
                    cached === query do
                  %{
                    index: pair.source.index,
                    stack: Enum.take(pair.source.stack, 6),
                    success?: elem(pair.returned.event, 3) === true
                  }
                end

              factories =
                for {index, output} <- decoders.query_outputs,
                    output.query.ref === query.ref do
                  input? =
                    case output.origin do
                      {factory, _} -> Map.has_key?(decoders.query_inputs, factory)
                      _ -> false
                    end

                  %{
                    index: index,
                    input?: input?,
                    fields:
                      for(
                        {field, value} <- Map.from_struct(query),
                        Map.fetch!(output.query, field) !== value,
                        do: field
                      )
                  }
                end

              origins =
                for origin <- checkpoint.query_origins,
                    origin.query.ref === query.ref do
                  %{
                    same_socket?: origin.sock === connection.protocol.sock,
                    same_types?: origin.query.types === connection.protocol.types,
                    fields:
                      for(
                        {field, value} <- Map.from_struct(query),
                        Map.fetch!(origin.query, field) !== value,
                        do: field
                      )
                  }
                end

              IO.puts(
                "CONNECTION_CUT_DESCRIPTOR_ORIGINS: " <>
                  Diagnostics.render(%{
                    phase: phase,
                    baseline?: baseline?,
                    same_pool?: connection.pool === historical.repo_metadata.pid,
                    owner_traced?: connection.history_owner_traced?,
                    preparations: preparations,
                    insertions: insertions,
                    factories: factories,
                    origins: origins
                  })
              )
            end

            assert described?,
                   "the full cut must retain the committed cache row's native descriptor"

            origin = Enum.find(connection.descriptors, &(&1.query === query))
            {:gen_tcp, port} = connection.protocol.sock
            bound_port? = Map.get(origin, :port) === port

            assert bound_port?, "the cut descriptor must retain its native physical port binding"
          end
        end
      end

      pending =
        for read <- native.reads,
            connection = Map.fetch!(reads.connections, read.port),
            prefix =
              connection.protocol.messages
              |> Enum.filter(fn frame ->
                Enum.all?(frame.provenance, &(&1.index < read.source.index))
              end)
              |> Enum.reduce(
                ConnectionProtocol.new(Map.get(historical.prepared_catalogs, read.port, %{})),
                fn frame, protocol -> ConnectionProtocol.push(protocol, frame) end
              ),
            Enum.any?(prefix.pending, fn operation ->
              operation.kind == :describe_statement and
                operation.context.sql == "SELECT $1::int4 AS pending_cache_history"
            end),
            do: {read.port, read.source.index, prefix}

      assert pending != [], "the native prefix must await its inferred parameter description"

      for {port, before, prefix} <- pending do
        assert {:ok, checkpoint} = cut.(historical, proof, before)
        retained? = Map.has_key?(checkpoint, :connection_protocols)

        assert retained?, "the full cut must retain pending frontend protocol state"

        same_pending? =
          Map.fetch!(checkpoint.connection_protocols, port).pending === prefix.pending

        assert same_pending?, "the cut cannot replace a pending description with a ready catalog"

        retained = Map.fetch!(checkpoint.connection_protocols, port)
        same_prefix? = retained === prefix

        assert same_prefix?, "the cut must retain every field of its causal protocol prefix"

        connection = Map.fetch!(reads.connections, port)

        resumed =
          connection.protocol.messages
          |> Enum.reject(fn frame -> Enum.all?(frame.provenance, &(&1.index < before)) end)
          |> Enum.reduce(retained, fn frame, protocol ->
            ConnectionProtocol.push(protocol, frame)
          end)
          |> ConnectionProtocol.finish()

        same_completion? = resumed === connection.protocol

        assert same_completion?,
               "the retained prefix and remaining real messages must recover the full protocol"
      end

      chunks =
        for(
          write <- native.writes,
          do: %{
            port: write.port,
            index: write.command.index,
            direction: :frontend,
            bytes: write.bytes,
            source_offset: write.header_size,
            copies: write.copies,
            phase: :shared
          }
        ) ++
          for(
            read <- native.reads,
            match?({:ok, _}, read.result),
            do: %{
              port: read.port,
              index: read.delivered.index,
              direction: :backend,
              bytes: read.bytes,
              copies: read.copies,
              phase: :backend
            }
          ) ++
          for delivery <- native.active,
              do: %{
                port: delivery.port,
                index: delivery.delivered.index,
                direction: :backend,
                bytes: delivery.bytes,
                copies: delivery.copies,
                phase: :backend
              }

      partial =
        for read <- native.reads,
            prefix =
              chunks
              |> Enum.filter(&(&1.port == read.port and &1.index < read.source.index))
              |> Enum.sort_by(& &1.index)
              |> Enum.reduce(Wire.frame_state(), fn chunk, state ->
                Wire.push_frame(state, chunk)
              end),
            get_in(prefix.directions, [:backend, :buffer]) not in [nil, <<>>],
            do: {read.port, read.source.index, prefix}

      assert partial != [], "the real large DataRow must cross a native receive boundary"

      for {port, before, prefix} <- partial do
        assert {:ok, checkpoint} = cut.(historical, proof, before)
        framing? = Map.has_key?(checkpoint, :connection_framing)
        assert framing?, "the cut must retain partial framing and every native byte span"
        retained = Map.fetch!(checkpoint.connection_framing, port)
        same_framing? = retained === prefix
        assert same_framing?, "the cut must retain the complete directional framing prefix"

        decoder =
          decoders.timeline
          |> Enum.filter(&(&1.port == port and &1.index < before))
          |> List.last()

        assert decoder, "a partial native frame needs its own causally current decoder cursor"

        same_coordinates? =
          decoder.cursor.offset + byte_size(decoder.cursor.buffer) ==
            prefix.directions.backend.received

        assert same_coordinates?, "framing and decoder cursors must use the same byte coordinates"
        decoder_cut? = Map.has_key?(checkpoint, :connection_decoders)
        assert decoder_cut?, "the cut must retain each physical decoder's actual cursor"
        same_cursor? = Map.fetch!(checkpoint.connection_decoders, port) === decoder.cursor
        assert same_cursor?, "the cut cannot restart its decoder at byte zero"

        resumed =
          chunks
          |> Enum.filter(&(&1.port == port and &1.index >= before))
          |> Enum.sort_by(& &1.index)
          |> Enum.reduce(retained, fn chunk, state -> Wire.push_frame(state, chunk) end)
          |> Wire.finish_frames()

        same_completion? = resumed === Map.fetch!(reads.connections, port).framing

        assert same_completion?,
               "retained partial bytes and the remaining real chunks must recover full framing"

        assert map_size(checkpoint.connection_decoder_program.executing) > 0,
               "the real partial cut must retain the Query that owns its row decoder"

        assert Enum.any?(checkpoint.connection_state_program.frames, fn {_pid, frames} ->
                 frames != []
               end),
               "the real partial cut must retain its still-executing owner frames"

        side = observation_side(context, run, %{}, row!(:issue, :execute), checkpoint)
        continued_side = %{side | run: %{run | events: Enum.drop(run.events, before)}}
        resumed = ConnectionHistory.build(continued_side)

        for error <- resumed.errors do
          Diagnostics.emit(
            "CONNECTION_PENDING_SUFFIX_FAILURE",
            Map.take(error, [:index, :at, :rule, :path, :context])
          )
        end

        assert resumed.errors == [],
               "a cut inside the real decoder program must retain its pending native owners"

        rejected =
          ComparatorMutants.with_mutant(:stream_pending_program, fn ->
            ConnectionHistory.build(continued_side)
          end)

        assert rejected.native.errors == []
        assert rejected.reads.errors == []
        assert Enum.any?(rejected.decoders.errors, &(&1.rule == :decoder_protocol))
        assert ConnectionHistory.build(continued_side).errors == []

        original_cursor =
          decoders.versions |> Enum.filter(&(&1.port == port)) |> List.last()

        resumed_cursor =
          resumed.decoders.versions |> Enum.filter(&(&1.port == port)) |> List.last()

        assert Map.take(resumed_cursor.cursor, [:offset, :buffer, :rows, :types]) ===
                 Map.take(original_cursor.cursor, [:offset, :buffer, :rows, :types])

        complete = Map.fetch!(reads.connections, port)
        continued = Map.fetch!(resumed.reads.connections, port)

        for direction <- [:frontend, :backend] do
          same_coordinates? =
            Map.take(continued.framing.directions[direction], [:offset, :received]) ===
              Map.take(complete.framing.directions[direction], [:offset, :received])

          assert same_coordinates?,
                 "a pending continuation must preserve both physical directions"
        end
      end
    after
      send(observer, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^observer, reason} -> assert reason == :normal
      after
        5_000 ->
          Process.exit(observer, :kill)
          flunk("the native cache observer did not stop")
      end
    end
  end

  @tag connection_streams: :pool
  test "Connection streams: cuts retain checkin clocks for every physical pool", context do
    options =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:idle_limit, 0)
      |> Keyword.put(:types, Postgrex.DefaultTypes)

    pool = start_supervised!({Postgrex, options}, id: :native_pool_clock)
    assert %{rows: [[17]]} = Postgrex.query!(pool, "SELECT 17::int4 AS other_pool_clock", [])
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)

    [holder] =
      for {holder, connection} <- historical.connections, connection.pool == pool, do: holder

    parent = self()
    token = make_ref()

    {observer, monitor} =
      spawn_monitor(fn ->
        parent_monitor = Process.monitor(parent)
        holder_observer(parent, token, parent_monitor)
      end)

    try do
      run =
        ExitBoundary.observe(
          fn -> :pool_clock_observation end,
          fn _ ->
            for value <- [29, 41] do
              assert %{rows: [[^value]]} =
                       Postgrex.query!(pool, "SELECT $1::int4 AS other_pool_clock", [value])

              DBConnection.get_connection_metrics(pool)
              send(observer, {:native_pool_clock_cut, token, self(), pool, value})

              receive do
                {:native_pool_clock_cut, ^token, ^value, :observed} -> :ok
              after
                5_000 -> raise "the independent pool observer did not acknowledge its live read"
              end
            end

            :ok
          end,
          %{host: [], callbacks: []}
        )

      assert run.result == :ok
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)
      assert proof.errors == []

      snapshots =
        for value <- [29, 41], into: %{} do
          receive do
            {:native_pool_clock_snapshot, ^token, ^value, clocks} -> {value, clocks}
          after
            0 -> flunk("the independent observer did not retain every pool-clock cut")
          end
        end

      assert Map.fetch!(snapshots[29], holder) != Map.fetch!(snapshots[41], holder)

      for {value, expected} <- snapshots do
        [barrier] =
          Enum.filter(proof.indexed.events, fn
            %{event: {_, :receive, {:native_pool_clock_cut, ^token, ^value, :observed}}} -> true
            _ -> false
          end)

        assert {:ok, checkpoint} = Historical.cut(historical, proof, barrier.index)
        actual = Map.take(checkpoint.pool_clocks, Map.keys(expected))
        same_clocks? = actual === expected
        assert same_clocks?, "the cut must retain every pool's own committed checkin clocks"

        if value == 29 do
          # Keep the recorded events intact. The cut is the initial state for
          # this actual suffix, including all other pools and native owners.
          suffix = Enum.drop(run.events, barrier.index)
          continued = %{side | run: %{run | events: suffix}, historical: checkpoint}
          resumed = ConnectionHistory.build(continued)

          for error <- resumed.errors do
            Diagnostics.emit(
              "CONNECTION_SUFFIX_FAILURE",
              Map.take(error, [:index, :at, :rule, :path, :context])
            )
          end

          assert resumed.errors == []
          assert map_size(resumed.reads.connections) > 0

          assert Enum.map(resumed.indexed.events, & &1.index) ==
                   Enum.to_list(barrier.index..(length(run.events) - 1))

          for {port, connection} <- resumed.reads.connections do
            complete = Map.fetch!(proof.reads.connections, port)

            for direction <- [:frontend, :backend] do
              full = Map.fetch!(complete.framing.directions, direction)
              current = Map.fetch!(connection.framing.directions, direction)

              same_coordinates? =
                Map.take(current, [:offset, :received]) ===
                  Map.take(full, [:offset, :received])

              assert same_coordinates?,
                     "a continued stream must retain its physical byte coordinates across leases"
            end

            original_cursor = Map.fetch!(proof.decoders.cursors, port)
            continued_cursor = Map.fetch!(resumed.decoders.cursors, port)

            same_cursor? =
              Map.take(continued_cursor, [:offset, :buffer, :rows, :types]) ===
                Map.take(original_cursor, [:offset, :buffer, :rows, :types])

            assert same_cursor?,
                   "a continued decoder must retain its original byte coordinate and native values"
          end
        end
      end
    after
      send(observer, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^observer, reason} -> assert reason == :normal
      after
        5_000 ->
          Process.exit(observer, :kill)
          flunk("the independent pool observer did not stop")
      end
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: cancellation binds its separate connection to the native backend" do
    for corruption <- [nil, :cancel_key] do
      run =
        if corruption do
          ComparatorMutants.with_postgrex_mutant(corruption, &ConnectionNative.observe_cancel/0)
        else
          ConnectionNative.observe_cancel()
        end

      assert run.result == :ok
      events = Enum.with_index(run.events, &Map.put(&1, :index, &2))
      native = NativeTransport.build(%{events: events}, run.native_history)
      assert native.errors == []
      reads = ConnectionReads.build(native)

      if corruption do
        assert Enum.map(reads.errors, & &1.rule) == [:cancel_identity]

        for mutant <- [:stream_length, :stream_timeout, :stream_required, :stream_cancel_identity] do
          unchecked =
            ComparatorMutants.with_mutant(mutant, fn -> ConnectionReads.build(native) end)

          expected = if mutant == :stream_cancel_identity, do: [], else: [:cancel_identity]
          assert Enum.map(unchecked.errors, & &1.rule) == expected
        end

        assert Enum.map(ConnectionReads.build(native).errors, & &1.rule) == [:cancel_identity]
      else
        assert reads.errors == []

        cancellations =
          for {_port, connection} <- reads.connections,
              message <- connection.protocol.messages,
              match?({:cancel_request, _, _}, message.decoded),
              do: message

        assert length(cancellations) == 1
      end
    end

    corrupted =
      ComparatorMutants.with_postgrex_mutant(
        :cancel_owner_copy,
        &ConnectionNative.observe_cancel/0
      )

    corrupted_events = Enum.with_index(corrupted.events, &Map.put(&1, :index, &2))

    corrupted_native =
      NativeTransport.build(%{events: corrupted_events}, corrupted.native_history)

    assert corrupted_native.errors == []
    corrupted_reads = ConnectionReads.build(corrupted_native)
    assert corrupted_reads.errors == []

    corrupted_decoders =
      ConnectionDecoders.build(
        %{events: corrupted_events},
        corrupted_native,
        corrupted_reads,
        corrupted.native_history
      )

    assert corrupted_decoders.errors == []

    check_owner = fn ->
      ConnectionStates.build(
        %{events: corrupted_events},
        corrupted_native,
        corrupted_decoders,
        corrupted.native_history,
        {:initial, corrupted.initial_state}
      )
    end

    assert [%{rule: :state_input_copy, at: %{mfa: {Postgrex.Protocol, :terminate, 1}}}] =
             check_owner.().errors

    for mutant <- [:stream_state_copy, :stream_buffer_copy, :stream_helper_copy] do
      checked = ComparatorMutants.with_mutant(mutant, check_owner)
      expected = if mutant == :stream_state_copy, do: [], else: [:state_input_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(check_owner.().errors, & &1.rule) == [:state_input_copy]

    restored = ConnectionNative.observe_cancel()
    events = Enum.with_index(restored.events, &Map.put(&1, :index, &2))
    native = NativeTransport.build(%{events: events}, restored.native_history)
    assert native.errors == []
    reads = ConnectionReads.build(native)
    assert reads.errors == []

    decoders = ConnectionDecoders.build(%{events: events}, native, reads, restored.native_history)
    assert decoders.errors == []

    states =
      ConnectionStates.build(
        %{events: events},
        native,
        decoders,
        restored.native_history,
        {:initial, restored.initial_state}
      )

    for error <- states.errors do
      Diagnostics.emit(
        "CONNECTION_CANCEL_OWNER_FAILURE",
        Map.take(error, [:index, :at, :rule, :path, :context])
      )
    end

    assert states.errors == [], "cancellation must preserve every original Protocol owner copy"
    assert decoders.protocol_copies != []
    covered = MapSet.new(states.copies, &{&1.index, &1.path})

    assert Enum.all?(decoders.protocol_copies, fn copy ->
             MapSet.member?(covered, {copy.index, copy.path})
           end)
  end

  @tag connection_streams: :transport
  test "Connection streams: startup reads belong to their native authentication exchange" do
    for corruption <- [nil, :extra_read] do
      run = ConnectionNative.observe_startup(corruption)
      assert run.result == :ok
      events = Enum.with_index(run.events, &Map.put(&1, :index, &2))
      native = NativeTransport.build(%{events: events})
      assert native.errors == []
      reads = ConnectionReads.build(native)

      if corruption do
        assert Enum.map(reads.errors, & &1.rule) == [:receive_required]

        for mutant <- [:stream_length, :stream_timeout, :stream_required] do
          checked = ComparatorMutants.with_mutant(mutant, fn -> ConnectionReads.build(native) end)
          expected = if mutant == :stream_required, do: [], else: [:receive_required]
          assert Enum.map(checked.errors, & &1.rule) == expected
        end

        assert Enum.map(ConnectionReads.build(native).errors, & &1.rule) == [:receive_required]
      else
        assert Enum.any?(native.pairs, fn
                 {_index, %{source: %{mfa: {:gen_tcp, :connect, 4}, stack: stack}}} ->
                   {Postgrex.Protocol, :connect, 1} in stack

                 _ ->
                   false
               end),
               "startup admission requires the actual traced connection constructor"

        assert reads.errors == []

        assert Enum.any?(reads.connections, fn
                 {_port, %{protocol: %{startup: %{phase: :ready, identity: {_backend, _key}}}}} ->
                   true

                 _ ->
                   false
               end)
      end
    end

    restored = ConnectionNative.observe_startup()
    events = Enum.with_index(restored.events, &Map.put(&1, :index, &2))
    native = NativeTransport.build(%{events: events})
    assert native.errors == []
    assert ConnectionReads.build(native).errors == []
  end

  @tag connection_streams: :pool
  test "Connection streams: startup constructs its decoder and Protocol from native origins",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)
    run = ConnectionNative.observe_startup()
    assert run.result == :ok

    services = run.snapshot.services
    [parameters] = for {pid, %{name: Postgrex.Parameters}} <- services, do: pid

    insertions =
      Enum.filter(run.snapshot.service_receipts, fn receipt ->
        receipt.pid == parameters and
          match?({:"$gen_call", _, {:insert, _}}, receipt.message)
      end)

    assert length(insertions) == 1

    for receipt <- insertions do
      assert receipt.registered?
      assert receipt.called && receipt.returned
      assert receipt.received_stamp < receipt.called_stamp
      assert receipt.called_stamp < receipt.returned_stamp
    end

    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)
    assert proof.native.errors == []
    assert proof.reads.errors == []

    for error <- proof.decoders.errors ++ proof.states.errors do
      Diagnostics.emit(
        "CONNECTION_STARTUP_ORIGIN_FAILURE",
        Map.take(error, [:index, :at, :rule, :path, :context])
      )
    end

    assert proof.decoders.errors == [],
           "a successful native connect must create its own initially empty decoder"

    unrooted =
      ComparatorMutants.with_mutant(:stream_startup_decoder, fn ->
        ConnectionHistory.build(side)
      end)

    assert unrooted.native.errors == []
    assert unrooted.reads.errors == []
    assert Enum.any?(unrooted.decoders.errors, &(&1.rule == :decoder_history))
    assert ConnectionHistory.build(side).decoders.errors == []

    assert map_size(proof.indexed.connection_type_roots) > 0

    without_types =
      ComparatorMutants.with_mutant(:stream_startup_type_root, fn ->
        ConnectionHistory.build(side)
      end)

    assert without_types.native.errors == []
    assert without_types.reads.errors == []
    assert Enum.any?(without_types.decoders.errors, &(&1.rule == :decoder_type_origin))
    assert ConnectionHistory.build(side).decoders.errors == []

    assert proof.states.errors == [],
           "every constructor and authentication Protocol copy needs its native source"
  end

  @tag connection_streams: :pool
  test "Connection streams: a new native type service constructs its own startup roots",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)
    run = ConnectionNative.observe_fresh_startup()
    assert run.result == :ok

    private =
      for receipt <- run.snapshot.service_receipts,
          program = Map.get(receipt, :native_program),
          not is_nil(program),
          do: {receipt, program}

    assert Enum.any?(private, fn {_receipt, program} -> program.kind == :startup_ack end),
           "the real type-service startup ack needs its own completed native program"

    assert Enum.any?(private, fn {receipt, program} ->
             program.kind == :shutdown_monitor_timeout and receipt.message == :timeout
           end),
           "the real monitor-child receive timeout needs its completed native program"

    assert Enum.all?(private, fn {receipt, _program} ->
             is_nil(receipt.called) and is_nil(receipt.returned)
           end),
           "a native receive must never fabricate a GenServer callback completion"

    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)
    assert proof.native.errors == []
    assert proof.reads.errors == []

    for error <- proof.types.errors ++ proof.decoders.errors ++ proof.states.errors do
      Diagnostics.emit(
        "CONNECTION_FRESH_TYPE_ORIGIN_FAILURE",
        Map.take(error, [:index, :at, :rule, :path, :context])
      )
    end

    assert proof.types.errors == []
    assert [birth] = proof.types.births
    assert birth.registration < birth.index
    assert birth.index < birth.initialized
    assert is_integer(birth.retired)
    assert birth.initialized < birth.retired
    assert MapSet.member?(run.snapshot.down, birth.owner)
    assert :ets.info(birth.table) == :undefined
    assert Elixir.Registry.lookup(Postgrex.TypeManager, birth.key) == []

    assert proof.decoders.errors == []
    assert proof.states.errors == []

    assert {:ok, before_birth} = Historical.cut(historical, proof, birth.index)

    for program <- [
          before_birth.connection_decoder_program,
          before_birth.connection_state_program
        ] do
      refute Map.has_key?(program.type_roots, birth.owner),
             "a prefix cannot acquire the future native Types.new return"
    end

    assert {:ok, before_init} = Historical.cut(historical, proof, birth.initialized)

    for program <- [before_init.connection_decoder_program, before_init.connection_state_program] do
      root = Map.fetch!(program.type_roots, birth.owner)
      assert root.index == birth.index
      assert root.types === birth.types
      assert is_nil(root.initialized)

      refute Map.has_key?(root, :state),
             "a prefix cannot acquire the future TypeServer.init return"

      assert is_nil(root.retired)
    end

    fetch =
      Enum.find(proof.indexed.events, fn
        %{event: {_, :call, {Postgrex.TypeServer, :fetch, [server]}}} -> server == birth.owner
        _ -> false
      end)

    assert fetch
    assert {:ok, after_birth} = Historical.cut(historical, proof, fetch.index)

    for program <- [
          after_birth.connection_decoder_program,
          after_birth.connection_state_program
        ] do
      root = Map.fetch!(program.type_roots, birth.owner)
      assert root.index == birth.index
      assert root.types === birth.types
      assert root.initialized == birth.initialized
      assert is_nil(root.retired), "a prefix cannot acquire the future service retirement"
    end

    assert {:ok, after_retirement} = Historical.cut(historical, proof, birth.retired + 1)

    for program <- [
          after_retirement.connection_decoder_program,
          after_retirement.connection_state_program
        ] do
      assert Map.fetch!(program.type_roots, birth.owner).retired == birth.retired
    end

    for checkpoint <- [before_birth, before_init, after_birth, after_retirement] do
      continued_side = %{
        side
        | historical: checkpoint,
          run: %{run | events: Enum.drop(run.events, checkpoint.event_offset)}
      }

      continued = ConnectionHistory.build(continued_side)
      assert continued.errors == []
      same_cursors? = continued.decoders.cursors === proof.decoders.cursors
      assert same_cursors?, "the unchanged startup suffix must finish every original decoder"
      same_commits? = continued.states.commits === proof.states.commits
      assert same_commits?, "every lifetime cut must recover the original native holder history"
      assert continued.types.births === proof.types.births
    end

    without_origin =
      ComparatorMutants.with_mutant(:stream_startup_type_root, fn ->
        ConnectionHistory.build(side)
      end)

    assert without_origin.native.errors == []
    assert without_origin.reads.errors == []
    assert Enum.any?(without_origin.decoders.errors, &(&1.rule == :decoder_type_origin))
    assert ConnectionHistory.build(side).errors == []

    restored = ConnectionNative.observe_fresh_startup()
    side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
    assert ConnectionHistory.build(side).errors == []
  end

  @tag connection_streams: :tls
  test "Connection streams: native SSL negotiation retains its exact cleartext prefix" do
    {native, reads} = ssl_upgrade_prefix(ConnectionNative.observe_tls_startup())
    assert native.errors == []
    assert reads.errors == []
    [connection] = Map.values(reads.connections)

    assert Enum.map(connection.protocol.messages, & &1.decoded) ==
             [{:ssl_request, 80_877_103}, {:ssl_response, ?S}]

    obligations = [
      {:ssl_negotiation_length, :receive_length, :stream_length},
      {:ssl_negotiation_timeout, :receive_timeout, :stream_timeout}
    ]

    for {corruption, rule, _mutant} <- obligations do
      run =
        ComparatorMutants.with_postgrex_mutant(
          corruption,
          &ConnectionNative.observe_tls_startup/0
        )

      {native, reads} = ssl_upgrade_prefix(run)
      assert native.errors == []
      assert Enum.map(reads.errors, & &1.rule) == [rule]

      for {_corruption, other_rule, mutant} <- obligations do
        checked = ComparatorMutants.with_mutant(mutant, fn -> ConnectionReads.build(native) end)
        expected = if other_rule == rule, do: [], else: [rule]
        assert Enum.map(checked.errors, & &1.rule) == expected
      end

      assert Enum.map(ConnectionReads.build(native).errors, & &1.rule) == [rule]
      {restored_native, restored} = ssl_upgrade_prefix(ConnectionNative.observe_tls_startup())
      assert restored_native.errors == []
      assert restored.errors == []
    end
  end

  defp ssl_upgrade_prefix(run) do
    assert run.result == :ok
    indexed = Enum.with_index(run.events, &Map.put(&1, :index, &2))

    assert [upgrade] =
             for(
               {_, pair} <- NativeTransport.pairs(indexed),
               pair.source.mfa == {:ssl, :connect, 3},
               do: pair
             )

    # This is a real capture prefix at the actual TLS boundary. Every raw
    # event is unchanged; the full cold constructor/worker proof follows it.
    prefix = Enum.take_while(indexed, &(&1.index < upgrade.source.index))
    native = NativeTransport.build(%{events: prefix})
    {native, ConnectionReads.build(native)}
  end

  @tag connection_streams: :tls
  test "Connection streams: cold TLS derives its workers from the native startup chain",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)
    run = ConnectionNative.observe_tls_startup()
    assert run.result == :ok
    assert run.initial_state == :ok

    private_replies =
      for receipt <- run.snapshot.service_receipts,
          %{kind: :gen_call_reply} <- [Map.get(receipt, :native_program)],
          do: receipt

    assert private_replies != [],
           "cold native services must retain their own synchronous reply programs"

    for receipt <- private_replies do
      assert is_nil(receipt.called) and is_nil(receipt.returned)
      assert receipt.native_program.source_stamp < receipt.received_stamp
      assert receipt.received_stamp < receipt.native_program.returned_stamp
    end

    factories =
      for %{event: {supervisor, :call, {:tls_dyn_connection_sup, :start_link, _}}} <- run.events,
          do: supervisor

    assert [supervisor] = factories
    assert run.snapshot.services[supervisor].name == :tls_connection_sup

    senders =
      for %{event: {pid, :call, {:tls_sender, :init, [_]}}} <- run.events, do: pid

    receivers =
      for %{event: {pid, :call, {:ssl_gen_statem, :init, [_]}}} <- run.events, do: pid

    assert [sender] = senders
    assert [receiver] = receivers
    refute sender == receiver

    workers =
      for %{event: {parent, :spawn, child, _}} <- run.events,
          parent in run.snapshot.pids,
          do: child

    assert length(Enum.uniq(workers)) >= 2
    assert sender in workers and receiver in workers
    assert Enum.all?(workers, &MapSet.member?(run.snapshot.down, &1))

    for worker <- workers, binding <- run.tls_bindings do
      refute worker in [binding.owner, binding.sender],
             "a born TLS worker cannot acquire a post-birth historical root"
    end

    indexed = Enum.with_index(run.events, &Map.put(&1, :index, &2))
    pairs = NativeTransport.pairs(indexed)

    assert [tree] =
             for(
               {_, pair} <- pairs,
               pair.source.pid == supervisor,
               pair.source.mfa == {:tls_dyn_connection_sup, :start_link, 2},
               do: pair
             )

    assert {^supervisor, :return_from, _, {:ok, dynamic_supervisor}} = tree.returned.event

    assert [created] =
             for(
               {_, pair} <- pairs,
               pair.source.pid == receiver,
               pair.source.mfa in [
                 {:tls_gen_connection_1_3, :initial_state, 9},
                 {:tls_dtls_gen_connection, :initial_state, 9}
               ],
               do: pair
             )

    assert {^receiver, :call,
            {constructor, :initial_state,
             [:client, ^sender, table, host, remote_port, port, options, caller, callbacks]}} =
             created.source.event

    {client, expected_constructor} =
      if Map.fetch!(elem(options, 0), :versions) == [{3, 4}],
        do: {:tls_client_connection_1_3, :tls_gen_connection_1_3},
        else: {:tls_client_connection, :tls_dtls_gen_connection}

    assert constructor == expected_constructor

    assert [client_init] =
             for(
               %{event: {^receiver, :call, {^client, :init, [arguments]}}} = source <- indexed,
               arguments === [
                 :client,
                 sender,
                 table,
                 host,
                 remote_port,
                 port,
                 options,
                 caller,
                 callbacks
               ],
               do: source
             )

    assert client_init.index < created.source.index
    assert is_reference(table) and is_port(port)
    assert {^receiver, :return_from, _, initial} = created.returned.event

    assert [table_origin] =
             for(
               {_, pair} <- pairs,
               pair.source.event == {receiver, :call, {:ets, :new, [:tls_socket, []]}},
               pair.returned.event == {receiver, :return_from, {:ets, :new, 2}, table},
               do: pair
             )

    assert table_origin.returned.index < created.source.index

    assert [socket_origin] =
             for(
               {_, pair} <- pairs,
               pair.source.pid == receiver,
               {^receiver, :call,
                {:tls_socket, :socket,
                 [[^receiver, ^sender], :gen_tcp, ^port, :tls_gen_connection, ^table, _trackers]}} <-
                 [pair.source.event],
               do: pair
             )

    assert created.source.index < socket_origin.source.index
    assert socket_origin.returned.index < created.returned.index
    assert {^receiver, :return_from, _, socket} = socket_origin.returned.event

    assert [configured] =
             for(
               {_, pair} <- pairs,
               pair.source.pid == receiver,
               pair.source.mfa == {:ssl_gen_statem, :init_ssl_config, 3},
               do: pair
             )

    assert {^receiver, :call, {:ssl_gen_statem, :init_ssl_config, [ssl_options, :client, input]}} =
             configured.source.event

    assert elem(options, 0) === ssl_options
    same_initial? = input === initial
    assert same_initial?, "SSL configuration must consume its own native constructor return"
    assert created.returned.index < configured.source.index
    assert {^receiver, :return_from, _, _configured_state} = configured.returned.event

    entries =
      for %{event: {pid, :call, {:gen_statem, :enter, arguments}}} = source <- indexed,
          pid in [sender, receiver],
          do: {pid, source, arguments}

    assert [
             {^receiver, entry,
              [
                ^dynamic_supervisor,
                [],
                ^client,
                ^receiver,
                :infinity,
                :initial_hello,
                entered,
                []
              ]}
           ] =
             Enum.filter(entries, &(elem(&1, 0) == receiver))

    expected_entry =
      cold_tls_entry_state(
        pairs,
        receiver,
        client,
        configured,
        {host, remote_port, ssl_options, entry.index}
      )

    same_configured? = entered === expected_entry
    assert same_configured?, "the cold receiver must enter with its configured native state"
    assert configured.returned.index < entry.index

    assert [sender_init] =
             for(
               {_, pair} <- pairs,
               pair.source.pid == sender,
               pair.source.mfa == {:tls_sender, :init, 1},
               do: pair
             )

    assert {^sender, :return_from, _, {:ok, :init, sender_state}} = sender_init.returned.event

    assert [
             {^sender, sender_entry,
              [
                ^dynamic_supervisor,
                [],
                :tls_sender,
                ^sender,
                :infinity,
                :init,
                sender_entered,
                []
              ]}
           ] =
             Enum.filter(entries, &(elem(&1, 0) == sender))

    same_sender? = sender_entered === sender_state
    assert same_sender?, "the cold sender must enter with its own native init return"
    assert sender_init.returned.index < sender_entry.index

    assert [factory] =
             for(
               {_, pair} <- pairs,
               pair.source.pid == caller,
               {^caller, :call,
                {:tls_gen_connection, :start_fsm,
                 [^host, ^remote_port, ^port, _options, ^caller, ^callbacks, _timeout]}} <-
                 [pair.source.event],
               do: pair
             )

    assert factory.source.index < created.source.index
    assert entry.index < factory.returned.index

    assert [handoff] =
             for(
               {_, pair} <- pairs,
               pair.source.event ==
                 {caller, :call, {:gen_tcp, :controlling_process, [port, receiver]}},
               pair.returned.event ==
                 {caller, :return_from, {:gen_tcp, :controlling_process, 2}, :ok},
               do: pair
             )

    assert socket_origin.returned.index < handoff.source.index

    assert [connected] =
             for(
               {_, pair} <- pairs,
               {^caller, :call, {:ssl, :connect, [^port, _options, _timeout]}} <-
                 [pair.source.event],
               do: pair
             )

    assert connected.source.index < factory.source.index
    assert handoff.returned.index < connected.returned.index
    assert {^caller, :return_from, _, {:ok, connected_socket}} = connected.returned.event
    same_socket? = connected_socket === socket
    assert same_socket?, "the public SSL socket must retain its actual native constructor origin"

    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)

    assert [request, response | _startup] = proof.reads.connections[port].protocol.messages
    assert request.direction == :frontend and request.start == 0
    assert request.decoded == {:ssl_request, 80_877_103}
    assert response.direction == :backend and response.start == 0
    assert response.decoded == {:ssl_response, ?S}

    for error <- proof.errors do
      Diagnostics.emit(
        "CONNECTION_COLD_TLS_ORIGIN_FAILURE",
        Map.take(error, [:index, :at, :rule, :path, :context])
      )
    end

    assert proof.errors == [],
           "every TLS worker and plaintext socket needs its actual native birth origin"

    ComparatorMutants.with_mutant(:stream_service_gen_call_reply, fn ->
      assert_raise ExUnit.AssertionError, &ConnectionNative.observe_tls_startup/0
    end)

    restored = ConnectionNative.observe_tls_startup()
    restored_side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
    assert ConnectionHistory.build(restored_side).errors == []
  end

  @tag connection_streams: :tls
  test "Connection streams: TLS 1.2 retains its complete cold native program", context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)
    run = ConnectionNative.observe_tls_startup(versions: [:"tlsv1.2"])
    assert run.result == :ok

    negotiated? =
      Enum.any?(run.events, fn
        %{event: {_, :call, {:tls_gen_connection, :next_event, [_name, _record, data]}}}
        when is_tuple(data) and tuple_size(data) == 13 ->
          elem(elem(data, 3), 5) == {3, 3}

        _ ->
          false
      end)

    assert negotiated?, "the native peer must actually negotiate TLS 1.2"
    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)
    assert proof.errors == [], "TLS 1.2 requires its complete native startup and retirement proof"
  end

  @tag connection_streams: :tls
  test "Connection streams: every cold TLS callback has its actual dispatch and return" do
    run = ConnectionNative.observe_tls_startup()
    assert run.result == :ok
    indexed = Enum.with_index(run.events, &Map.put(&1, :index, &2))
    pairs = NativeTransport.pairs(indexed)

    workers =
      for %{event: {pid, :call, {module, function, [_]}}} <- indexed,
          {module, function} in [{:tls_sender, :init}, {:ssl_gen_statem, :init_statem}],
          do: pid

    assert length(Enum.uniq(workers)) == 2

    dispatches =
      for %{event: {pid, :call, {:gen_statem, :loop_state_callback, arguments}}} = source <-
            indexed,
          pid in workers and length(arguments) == 11,
          do: source

    assert dispatches != []

    for dispatch <- dispatches do
      {pid, :call, {_, _, arguments}} = dispatch.event
      params = Enum.at(arguments, 0)
      {name, data} = Enum.at(arguments, 4)
      {type, content} = Enum.at(arguments, 10)
      assert elem(params, 1) == :state_functions
      [module | _] = elem(params, 4)

      completed =
        Enum.find(indexed, fn
          %{
            index: index,
            event: {^pid, :call, {:gen_statem, :loop_state_callback_result, values}}
          }
          when index > dispatch.index ->
            length(values) == 11

          _ ->
            false
        end)

      assert completed, "every native TLS dispatch must reach its own callback-result program"

      callbacks =
        for {_index, pair} <- pairs,
            pair.source.event == {pid, :call, {module, name, [type, content, data]}},
            dispatch.index < pair.source.index,
            pair.returned.index < completed.index,
            do: pair

      if length(callbacks) != 1 do
        Diagnostics.emit("CONNECTION_TLS_CALLBACK_CAPTURE_FAILURE", %{
          index: dispatch.index,
          mfa: {module, name, 3},
          length: length(callbacks)
        })
      end

      assert length(callbacks) == 1,
             "each native TLS state dispatch needs its own captured callback and return"

      [callback] = callbacks
      {^pid, :return_from, _, result} = callback.returned.event
      {^pid, :call, {_, _, values}} = completed.event
      same_result? = result === Enum.at(values, 10)
      assert same_result?, "the engine must consume its own native callback's exact return"
    end
  end

  @tag connection_streams: :tls
  test "Connection streams: a born TLS sender retains its initialization copies", context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)

    build = fn run ->
      assert run.result == :ok
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      ConnectionHistory.build(side)
    end

    positive = ConnectionNative.observe_tls_startup()
    proof = build.(positive)
    assert proof.errors == []

    assert Enum.any?(positive.events, fn
             %{event: {_, :call, {:tls_sender, :init, [_, _, _]}}} -> true
             _ -> false
           end)

    corrupt = fn ->
      ComparatorMutants.with_tls_sender_mutant(
        :initialization_input,
        &ConnectionNative.observe_tls_startup/0
      )
    end

    errors = build.(corrupt.()).errors
    assert errors != []
    assert Enum.all?(errors, &(&1.rule == :tls_worker_state_copy))

    ComparatorMutants.with_mutant(:stream_tls_worker_state_copy, fn ->
      assert build.(corrupt.()).errors == []
    end)

    restored = build.(corrupt.()).errors
    assert restored != []
    assert Enum.all?(restored, &(&1.rule == :tls_worker_state_copy))
    assert build.(ConnectionNative.observe_tls_startup()).errors == []
  end

  defp cold_tls_entry_state(
         _pairs,
         _receiver,
         :tls_client_connection_1_3,
         configured,
         _context
       ) do
    {_, :return_from, _, state} = configured.returned.event
    state
  end

  defp cold_tls_entry_state(
         pairs,
         receiver,
         :tls_client_connection,
         configured,
         {host, port, options, before}
       ) do
    {_, :return_from, _, state} = configured.returned.event
    environment = elem(state, 2)
    alternatives = elem(elem(state, 3), 7)

    assert [certificates] =
             for(
               {_, pair} <- pairs,
               pair.source.event ==
                 {receiver, :call, {:ssl_certificate, :available_cert_key_pairs, [alternatives]}},
               configured.returned.index < pair.source.index,
               pair.returned.index < before,
               do: pair
             )

    {^receiver, :return_from, _, certificate_pairs} = certificates.returned.event

    assert [selection] =
             for(
               {_, pair} <- pairs,
               pair.source.event ==
                 {receiver, :call,
                  {:ssl_session, :client_select_session,
                   [
                     {host, port, options},
                     elem(environment, 13),
                     elem(environment, 14),
                     elem(state, 8),
                     certificate_pairs
                   ]}},
               certificates.returned.index < pair.source.index,
               pair.returned.index < before,
               do: pair
             )

    {^receiver, :return_from, _, session} = selection.returned.event
    put_elem(state, 8, session)
  end

  @tag connection_streams: :pool
  test "Connection streams: a native supervisor shutdown timer keeps its private receive proof",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)
    run = ConnectionNative.observe_fresh_startup(:timed_shutdown)
    assert run.result == :ok

    receipts =
      for receipt <- run.snapshot.service_receipts,
          %{kind: :shutdown_timer} = program <- [Map.get(receipt, :native_program)],
          do: {receipt, program}

    assert length(receipts) == 1,
           "the real suspended type service must force one native shutdown timer receive"

    assert Enum.all?(receipts, fn {receipt, _program} ->
             is_nil(receipt.called) and is_nil(receipt.returned)
           end)

    [{receipt, program}] = receipts
    supervisor = receipt.pid

    assert {^supervisor, :call, {:erlang, :start_timer, [5000, ^supervisor, :kill]}} =
             program.timer_source

    assert {^supervisor, :return_from, {:erlang, :start_timer, 3}, timer_ref} =
             program.timer_returned

    assert receipt.message == {:timeout, timer_ref, :kill}
    assert receipt.used_by == timer_ref
    assert program.timer_source_stamp < receipt.received_stamp
    assert receipt.received_stamp < program.returned_stamp
    assert run.snapshot.timers[timer_ref].terminal.native_program === program

    timers =
      for {_ref, %{state: :fired, terminal: %{native_program: %{kind: :shutdown_timer}}}} <-
            run.snapshot.timers,
          do: :native_shutdown

    assert timers == [:native_shutdown],
           "timer drainage must retain the actual private native completion"

    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)
    assert proof.errors == []
    assert [birth] = proof.types.births
    assert is_integer(birth.retired)
    assert MapSet.member?(run.snapshot.down, birth.owner)
    assert :ets.info(birth.table) == :undefined
    assert Elixir.Registry.lookup(Postgrex.TypeManager, birth.key) == []

    ComparatorMutants.with_mutant(:stream_shutdown_timer_completion, fn ->
      assert_raise ExUnit.AssertionError, fn ->
        ConnectionNative.observe_fresh_startup(:timed_shutdown)
      end
    end)

    restored = ConnectionNative.observe_fresh_startup(:timed_shutdown)
    restored_side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
    assert ConnectionHistory.build(restored_side).errors == []
  end

  for position <- [0, 1, :return] do
    @tag connection_streams: :pool
    test "Connection streams: native type-service location #{position} retains its constructor origin",
         context do
      Repo.put_dynamic_repo(context.repo)
      historical = Historical.capture(context.prefix)
      position = unquote(position)

      run =
        if position == :return do
          ComparatorMutants.with_native_type_outputs(
            Postgrex.TypeSupervisor,
            %{{:locate, 2} => %{kind: :value}},
            &ConnectionNative.observe_startup/0
          )
        else
          ComparatorMutants.with_postgrex_inputs(
            %{{:locate, 2} => [position]},
            &ConnectionNative.observe_startup/0,
            Postgrex.TypeSupervisor
          )
        end

      assert run.result == :ok
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)
      assert proof.native.errors == []
      assert proof.reads.errors == []
      assert proof.decoders.errors == []

      coordinates =
        for source <- proof.indexed.events,
            {_, kind, _, _} <- [source.event],
            kind == :return_from and position == :return,
            source.mfa == {Postgrex.TypeSupervisor, :locate, 2},
            do: {source.index, [3]}

      coordinates =
        if position == :return do
          coordinates
        else
          for %{event: {_, :call, {Postgrex.TypeSupervisor, :locate, _}}} = source <-
                proof.indexed.events,
              do: {source.index, [2, 2, position]}
        end

      assert coordinates != []

      assert Enum.map(proof.states.errors, & &1.rule) ==
               List.duplicate(:state_helper_copy, length(coordinates))

      assert Enum.map(proof.states.errors, &{&1.index, &1.path}) == coordinates

      for mutant <- [:stream_helper_copy, :stream_state_copy, :stream_owner_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> ConnectionHistory.build(side) end)
        expected = if mutant == :stream_helper_copy, do: [], else: proof.errors
        assert checked.errors == expected
      end

      assert ConnectionHistory.build(side).errors == proof.errors
      restored = ConnectionNative.observe_startup()
      side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []
    end
  end

  @tag connection_streams: :pool
  test "Connection streams: a startup Protocol copy retains its constructor peer", context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)

    run =
      ComparatorMutants.with_postgrex_mutant(
        :startup_peer_copy,
        &ConnectionNative.observe_startup/0
      )

    assert run.result == :ok
    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)
    assert proof.native.errors == []
    assert proof.reads.errors == []
    assert proof.decoders.errors == []

    assert [
             %{
               rule: :state_input_copy,
               different_fields: [:peer],
               at: %{mfa: {Postgrex.Protocol, :msg_send, 3}}
             }
           ] = proof.states.errors

    for mutant <- [:stream_state_copy, :stream_helper_copy, :stream_owner_copy] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> ConnectionHistory.build(side) end)
      expected = if mutant == :stream_state_copy, do: [], else: proof.errors
      assert checked.errors == expected
    end

    assert ConnectionHistory.build(side).errors == proof.errors
    restored = ConnectionNative.observe_startup()
    side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
    assert ConnectionHistory.build(side).errors == []
  end

  @tag connection_streams: :pool
  test "Connection streams: a pool born during observation owns its complete native state",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)
    run = ConnectionNative.observe_pool_startup()
    assert run.result == :ok
    assert run.initial_state == :ok

    replies =
      for receipt <- run.snapshot.service_receipts,
          run.snapshot.services[receipt.pid].name == DBConnection.Watcher,
          %{kind: :gen_call_reply} <- [Map.get(receipt, :native_program)],
          do: receipt

    assert length(replies) == 2

    labels =
      for receipt <- replies do
        {_, :call, {:gen, :call, [_, label, _, _]}} = receipt.native_program.source
        label
      end

    assert Enum.sort(labels) == [:"$gen_call", :system]

    for receipt <- replies do
      assert is_nil(receipt.called) and is_nil(receipt.returned)
      assert receipt.native_program.source_stamp < receipt.received_stamp
      assert receipt.received_stamp < receipt.native_program.returned_stamp
    end

    ComparatorMutants.with_mutant(:stream_service_gen_call_reply, fn ->
      assert_raise ExUnit.AssertionError, &ConnectionNative.observe_pool_startup/0
    end)

    run = ConnectionNative.observe_pool_startup()
    assert run.result == :ok

    owners =
      for %{event: {pid, :call, {DBConnection.Connection, :init, [_]}}} <- run.events,
          uniq: true,
          do: pid

    assert [owner] = owners
    refute Map.has_key?(historical.connection_owners, owner)
    assert MapSet.member?(run.snapshot.down, owner)

    assert Enum.any?(run.events, fn
             %{event: {^owner, :call, {Postgrex.Protocol, :connect, [_]}}} -> true
             _ -> false
           end)

    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)

    for error <- proof.errors do
      Diagnostics.emit(
        "CONNECTION_POOL_BIRTH_FAILURE",
        Map.take(error, [:index, :at, :rule, :path, :context])
      )
    end

    assert proof.errors == [],
           "every born pool owner needs its native factory and initial state before any copy"

    assert Enum.any?(proof.states.owner_commits, fn commit ->
             commit.owner == owner and commit.index >= 0 and commit.machine != nil
           end)

    assert Enum.any?(proof.states.owner_commits, fn commit ->
             commit.owner == owner and commit.machine == nil
           end)
  end

  @tag connection_streams: :pool
  test "Connection streams: a private service reply retains its native sender" do
    positive = ConnectionNative.observe_pool_startup()
    assert positive.result == :ok

    corrupt = fn ->
      ComparatorMutants.with_service_reply_sender(&ConnectionNative.observe_pool_startup/0)
    end

    assert_raise ExUnit.AssertionError, corrupt

    bypassed =
      ComparatorMutants.with_mutant(:stream_service_reply_origin, fn ->
        corrupt.()
      end)

    assert bypassed.result == :ok
    assert_raise ExUnit.AssertionError, corrupt
    restored = ConnectionNative.observe_pool_startup()
    assert restored.result == :ok
  end

  for mode <- [
        :configure_function,
        :configure_mfa,
        :after_connect_function,
        :after_connect_mfa
      ] do
    @tag connection_streams: :pool
    test "Connection streams: a born pool retains native #{mode} configuration", context do
      Repo.put_dynamic_repo(context.repo)
      historical = Historical.capture(context.prefix)
      mode = unquote(mode)
      run = ConnectionNative.observe_pool_startup(mode)
      assert run.result == :ok
      assert run.initial_state == :ok

      callback =
        if mode in [:configure_function, :configure_mfa],
          do: :configure_pool_owner,
          else: :after_connect_pool_owner

      invoked? =
        Enum.any?(run.events, fn
          %{event: {_, :call, {ConnectionNative, ^callback, [_]}}} -> true
          _ -> false
        end)

      assert invoked?, "the native pool must execute its declared configuration callback"

      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)

      for error <- proof.errors do
        Diagnostics.emit(
          "CONNECTION_POOL_CONFIGURATION_FAILURE",
          Map.take(error, [:index, :at, :rule, :path, :context])
        )
      end

      assert proof.errors == [],
             "configuration and after-connect Tasks need their own native state origins"

      born = Enum.filter(proof.states.owner_commits, &(&1.index >= 0 and &1.machine != nil))
      assert born != []

      for owner <- Enum.uniq(Enum.map(born, & &1.owner)) do
        refute Map.has_key?(historical.connection_owners, owner)
        assert MapSet.member?(run.snapshot.down, owner)
        assert Enum.any?(proof.states.owner_commits, &(&1.owner == owner and &1.machine == nil))
      end
    end
  end

  for type <- [:default, :stop, :rand, :exp, :rand_exp] do
    @tag connection_streams: :pool
    test "Connection streams: native connection failure retains #{type} backoff state", context do
      Repo.put_dynamic_repo(context.repo)
      historical = Historical.capture(context.prefix)
      type = unquote(type)
      run = ConnectionNative.observe_pool_startup({:connect_failure, type})
      assert run.result == :ok

      rejected? =
        Enum.any?(run.events, fn
          %{
            event:
              {_, :return_from, {Postgrex.Protocol, :connect, 1},
               {:error, %Postgrex.Error{postgres: %{pg_code: "3D000"}}}}
          } ->
            true

          _ ->
            false
        end)

      assert rejected?, "the real PostgreSQL server must reject the absent database"

      retry? =
        Enum.any?(run.events, fn
          %{event: {_, :return_from, {DBConnection.Backoff, :backoff, 1}, _}} -> true
          _ -> false
        end)

      if type == :stop, do: refute(retry?), else: assert(retry?)
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)

      for error <- proof.errors do
        Diagnostics.emit(
          "CONNECTION_POOL_BACKOFF_FAILURE",
          Map.take(error, [:index, :at, :rule, :path, :context])
        )
      end

      assert proof.errors == [],
             "failed connections must retain their complete native owner state"

      owners =
        for %{event: {pid, :call, {DBConnection.Connection, :init, [_]}}} <- run.events,
            uniq: true,
            do: pid

      assert owners != []

      for owner <- owners do
        refute Map.has_key?(historical.connection_owners, owner)
        assert MapSet.member?(run.snapshot.down, owner)
        assert Enum.any?(proof.states.owner_commits, &(&1.owner == owner and &1.machine == nil))
      end
    end
  end

  for type <- [:default, :stop, :rand, :exp, :rand_exp], callback <- [:function, :mfa] do
    @tag connection_streams: :pool
    test "Connection streams: a failed after-connect #{callback} Task retains #{type} backoff state",
         context do
      Repo.put_dynamic_repo(context.repo)
      historical = Historical.capture(context.prefix)
      type = unquote(type)
      callback = unquote(callback)
      run = ConnectionNative.observe_pool_startup({:after_connect_failure, type, callback})
      assert run.result == :ok

      failed_tasks =
        for %{
              event:
                {task, :exception_from, {Postgrex, :query!, 4},
                 {:error, %Postgrex.Error{postgres: %{pg_code: "22012"}}}},
              stack: stack
            } <- run.events,
            {ConnectionNative, :after_connect_pool_failure, 1} in stack,
            uniq: true,
            do: task

      assert failed_tasks != [], "the real Task must observe the server's division-by-zero error"

      assert Enum.any?(run.events, fn
               %{
                 event:
                   {_, :call,
                    {DBConnection.Connection, :handle_event,
                     [
                       :info,
                       {:DOWN, ref, :process, task, :killed},
                       :no_state,
                       %{client: {ref, :after_connect}}
                     ]}}
               } ->
                 task in failed_tasks

               _ ->
                 false
             end),
             "the owner must consume the failed Task's DOWN before returning it to the pool"

      retry? =
        Enum.any?(run.events, fn
          %{event: {_, :return_from, {DBConnection.Backoff, :backoff, 1}, _}} -> true
          _ -> false
        end)

      if type == :stop, do: refute(retry?), else: assert(retry?)
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)

      for error <- proof.errors do
        Diagnostics.emit(
          "CONNECTION_POOL_BACKOFF_FAILURE",
          Map.take(error, [:index, :rule, :path]) |> Map.put(:mfa, error.at.mfa)
        )
      end

      assert proof.errors == [],
             "failed after-connect Tasks must retain their native owner program"
    end
  end

  for mode <- [
        {:connect_failure, :rand},
        {:after_connect_failure, :rand, :function},
        {:after_connect_failure, :rand, :mfa}
      ] do
    @tag connection_streams: :pool
    test "Connection streams: #{inspect(mode)} retains its original native Backoff input",
         context do
      Repo.put_dynamic_repo(context.repo)
      historical = Historical.capture(context.prefix)
      mode = unquote(Macro.escape(mode))
      observe = fn -> ConnectionNative.observe_pool_startup(mode) end
      positive = observe.()
      side = observation_side(context, positive, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []

      run = ComparatorMutants.with_backoff_input(observe)
      assert run.result == :ok
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)

      coordinates =
        for %{event: {_, :call, {DBConnection.Backoff, :backoff, [{:native_foreign_helper, _}]}}} =
              source <-
              proof.indexed.events,
            do: {source.index, [2, 2, 0]}

      assert coordinates != []

      assert proof.native.errors == [] and proof.reads.errors == [] and
               proof.decoders.errors == []

      assert Enum.map(proof.states.errors, &{&1.rule, &1.index, Map.get(&1, :path)}) ==
               Enum.map(coordinates, fn {index, path} ->
                 {:state_owner_backoff_input, index, path}
               end)

      for mutant <- [
            :stream_owner_backoff_input,
            :stream_owner_backoff_result,
            :stream_owner_copy
          ] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> ConnectionHistory.build(side) end)
        expected = if mutant == :stream_owner_backoff_input, do: [], else: proof.errors
        assert checked.errors == expected
      end

      assert ConnectionHistory.build(side).errors == proof.errors
      restored = observe.()
      side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []
    end

    @tag connection_streams: :pool
    test "Connection streams: #{inspect(mode)} retains its own native Backoff return", context do
      Repo.put_dynamic_repo(context.repo)
      historical = Historical.capture(context.prefix)
      mode = unquote(Macro.escape(mode))
      observe = fn -> ConnectionNative.observe_pool_startup(mode) end
      positive = observe.()
      side = observation_side(context, positive, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []

      run = ComparatorMutants.with_backoff_output(observe)
      assert run.result == :ok
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)

      coordinates =
        for %{
              event:
                {_, :return_from, {DBConnection.Backoff, :backoff, 1},
                 {{:native_foreign_return, _}, _}}
            } = source <-
              proof.indexed.events,
            do: {source.index, [3]}

      assert coordinates != []

      assert proof.native.errors == [] and proof.reads.errors == [] and
               proof.decoders.errors == []

      assert Enum.map(proof.states.errors, &{&1.rule, &1.index, Map.get(&1, :path)}) ==
               Enum.map(coordinates, fn {index, path} ->
                 {:state_owner_backoff_result, index, path}
               end)

      for mutant <- [
            :stream_owner_backoff_input,
            :stream_owner_backoff_result,
            :stream_owner_copy
          ] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> ConnectionHistory.build(side) end)
        expected = if mutant == :stream_owner_backoff_result, do: [], else: proof.errors
        assert checked.errors == expected
      end

      assert ConnectionHistory.build(side).errors == proof.errors
      restored = observe.()
      side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []
    end
  end

  for callback <- [:function, :mfa], boundary <- [:input, :output] do
    @tag connection_streams: :pool
    test "Connection streams: after-connect #{callback} Task factory #{boundary} has one copy guard",
         context do
      Repo.put_dynamic_repo(context.repo)
      historical = Historical.capture(context.prefix)
      callback = unquote(callback)
      boundary = unquote(boundary)

      observe = fn ->
        ConnectionNative.observe_pool_startup({:after_connect_failure, :rand, callback})
      end

      positive = observe.()
      side = observation_side(context, positive, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []

      run =
        case boundary do
          :input -> ComparatorMutants.with_task_factory_input(observe)
          :output -> ComparatorMutants.with_task_factory_output(observe)
        end

      assert run.result == :ok
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)

      coordinates =
        for source <- proof.indexed.events,
            task_factory_copy?(source.event, boundary),
            do: source.index

      assert coordinates != []
      rule = if boundary == :input, do: :state_owner_task_factory, else: :state_owner_task_return
      own = if boundary == :input, do: :stream_owner_task_factory, else: :stream_owner_task_return

      assert Enum.map(proof.errors, &{&1.rule, &1.index}) == Enum.map(coordinates, &{rule, &1})

      for mutant <- [
            :stream_owner_task_factory,
            :stream_owner_task_return,
            :stream_owner_backoff_input,
            :stream_owner_backoff_result,
            :stream_owner_copy
          ] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> ConnectionHistory.build(side) end)
        assert checked.errors == if(mutant == own, do: [], else: proof.errors)
      end

      assert ConnectionHistory.build(side).errors == proof.errors
      restored = observe.()
      side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []
    end
  end

  for callback <- [:function, :mfa] do
    @tag connection_streams: :pool
    test "Connection streams: after-connect #{callback} flushes its actually expired native timer",
         context do
      Repo.put_dynamic_repo(context.repo)
      historical = Historical.capture(context.prefix)
      run = ConnectionNative.observe_pool_timer_flush(unquote(callback))
      assert run.result == :ok
      indexed = Enum.with_index(run.events, &Map.put(&1, :index, &2))
      pairs = NativeTransport.pairs(indexed)

      cancellations =
        for {_index, %{source: source, returned: returned}} <- pairs,
            {owner, :call, {:erlang, :cancel_timer, [timer]}} <- [source.event],
            returned.event == {owner, :return_from, {:erlang, :cancel_timer, 1}, false},
            {_index, started} <- pairs,
            started.returned.event ==
              {owner, :return_from, {:erlang, :start_timer, 3}, timer},
            {^owner, :call,
             {:erlang, :start_timer, [timeout, ^owner, {DBConnection.Connection, task, timeout}]}} <-
              [started.source.event],
            started.returned.index < source.index,
            do: %{
              owner: owner,
              timer: timer,
              task: task,
              timeout: timeout,
              started: started,
              source: source,
              returned: returned
            }

      assert cancellations != [], "the real owner must execute the false cancellation branch"

      for cancellation <- cancellations do
        %{owner: owner, timer: timer, task: task, timeout: timeout} = cancellation

        assert [holder] =
                 for(
                   %{event: {^owner, :receive, {:"ETS-TRANSFER", _, ^task, {:checkin, _, _}}}} =
                     event <- indexed,
                   do: event
                 )

        assert [expiry] =
                 for(
                   %{
                     event:
                       {^owner, :receive,
                        {:timeout, ^timer, {DBConnection.Connection, ^task, ^timeout}}}
                   } = event <- indexed,
                   do: event
                 )

        assert cancellation.started.returned.index < holder.index
        assert holder.index < expiry.index and expiry.index < cancellation.source.index

        assert [flush] =
                 for(
                   {_index, pair} <- pairs,
                   pair.source.event ==
                     {owner, :call, {DBConnection.Connection, :flush_timer, [timer]}},
                   pair.returned.event ==
                     {owner, :return_from, {DBConnection.Connection, :flush_timer, 1}, :ok},
                   do: pair
                 )

        assert cancellation.returned.index < flush.source.index
      end

      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)

      assert proof.native.errors == [] and proof.reads.errors == [] and
               proof.decoders.errors == []

      assert proof.errors == [],
             "false cancellation requires its actual expiry and successful native selective flush"
    end
  end

  defp task_factory_copy?(
         {_, :call, {DBConnection.Task, :run_child, [_, _, {:native_foreign_helper, _}, _]}},
         :input
       ),
       do: true

  defp task_factory_copy?(
         {_, :return_from, {DBConnection.Task, :run_child, 4}, {_, {:native_foreign_return, _}}},
         :output
       ),
       do: true

  defp task_factory_copy?(_event, _boundary), do: false

  for lifecycle <- [:idle_ping, :reconnect] do
    @tag connection_streams: :pool
    test "Connection streams: native #{lifecycle} retains the renewed holder's cut origin",
         context do
      lifecycle = unquote(lifecycle)

      {run, historical, original, renewed, row, token} =
        native_renewal_observation(context, lifecycle)

      assert renewed != original
      refute Map.has_key?(historical.connections, renewed)
      previous_socket = historical.connections[original].protocol.sock
      current_socket = elem(row, 3).sock

      case lifecycle do
        :idle_ping -> assert current_socket === previous_socket
        :reconnect -> refute current_socket === previous_socket
      end

      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)
      assert proof.native.errors == []
      assert proof.reads.errors == []
      assert proof.decoders.errors == []

      for error <- proof.states.errors do
        Diagnostics.emit(
          "CONNECTION_RENEWAL_OWNER_FAILURE",
          Map.take(error, [:index, :at, :rule, :path, :context])
        )
      end

      assert proof.states.errors == [],
             "a native holder renewal must retain its owner origin before cutting"

      allocation_side = Map.put(side, :connection_history, proof)
      [initial_lease, lease] = Allocation.leases(allocation_side, Origins.build(allocation_side))
      assert initial_lease.holder == original
      assert initial_lease.owner == historical.connections[original].owner
      assert initial_lease.port == historical.connections[original].port
      terminal = if lifecycle == :idle_ping, do: :checkin, else: :disconnect
      caller = initial_lease.source.pid
      pool = initial_lease.pool
      queue = initial_lease.queue

      assert [termination] =
               for(
                 %{event: {^caller, :call, {:ets, :give_away, arguments}}} = source <-
                   proof.indexed.events,
                 [^original, ^pool, {^terminal, ^queue, _value}] <- [arguments],
                 source.index > initial_lease.acquired,
                 do: source
               )

      assert termination.index < lease.acquired

      assert initial_lease.giveaway == termination.index,
             "every lease must retain its actual native checkin or disconnect terminal"

      assert initial_lease.terminal == terminal
      assert initial_lease.acquired < initial_lease.terminal_source
      assert initial_lease.terminal_source < initial_lease.giveaway
      assert initial_lease.giveaway < initial_lease.terminal_return
      assert initial_lease.terminal_return < lease.acquired

      if lifecycle == :idle_ping do
        assert is_integer(initial_lease.checkin) and is_integer(initial_lease.giveaway)
      else
        assert is_nil(initial_lease.checkin),
               "a disconnect handoff cannot acquire a later cleanup checkin"
      end

      assert lease.holder == renewed
      assert lease.owner == historical.connections[original].owner
      assert lease.port == proof.states.holder_origins[renewed].port
      assert lease.backend == elem(row, 3).connection_id
      assert is_integer(lease.checkin) and is_integer(lease.giveaway)

      assert is_nil(initial_lease.conn_ref)
      assert is_reference(lease.conn_ref)
      allocation_index = Origins.build(allocation_side)

      allocation =
        Allocation.pair(
          %{forward: %{}, reverse: %{}, errors: []},
          allocation_side,
          allocation_side,
          allocation_index,
          allocation_index
        )

      assert allocation.errors == [],
             "direct Holder leases close at their native handoff without a DBConnection wrapper"

      [barrier] =
        Enum.filter(proof.indexed.events, fn
          %{event: {_, :receive, {:native_holder_cut, ^token, :renewed, :observed}}} -> true
          _ -> false
        end)

      assert {:ok, checkpoint} = Historical.cut(historical, proof, barrier.index)
      connection = Map.fetch!(checkpoint.connections, renewed)

      expected =
        {:conn, connection.owner, Postgrex.Protocol, connection.protocol, connection.lock,
         connection.clock, connection.deadline, connection.status}

      same_row? = row === expected
      assert same_row?, "the new holder cut must equal all eight independently read row fields"
      refute Map.has_key?(checkpoint.connections, original)

      retired =
        Enum.find(proof.states.commits, &(&1.holder == original and is_nil(&1.row)))

      created =
        Enum.find(proof.states.commits, &(&1.holder == renewed and not is_nil(&1.row)))

      assert retired && created

      gap =
        Enum.find(proof.indexed.events, fn source ->
          retired.index < source.index and source.index < created.index
        end)

      assert gap, "the native renewal must expose its real interval without a holder row"
      assert {:ok, pending} = Historical.cut(historical, proof, gap.index)
      refute Map.has_key?(pending.connections, original)
      refute Map.has_key?(pending.connections, renewed)
      owner = historical.connections[original].owner
      assert Map.has_key?(pending.connection_owners, owner)

      continued_side = %{
        side
        | historical: pending,
          run: %{run | events: Enum.drop(run.events, gap.index)}
      }

      continued = ConnectionHistory.build(continued_side)

      for error <- continued.errors do
        Diagnostics.emit(
          "CONNECTION_PENDING_OWNER_FAILURE",
          Map.take(error, [:index, :at, :rule, :path, :context])
        )
      end

      assert continued.errors == [],
             "the unchanged native suffix must finish its owner without a borrowed holder root"

      rejected =
        ComparatorMutants.with_mutant(:stream_pending_owner_program, fn ->
          ConnectionHistory.build(continued_side)
        end)

      assert rejected.native.errors == []
      assert rejected.reads.errors == []
      assert rejected.decoders.errors == []
      assert rejected.states.errors != [], "the pending owner program must be load-bearing"
      assert ConnectionHistory.build(continued_side).errors == []

      same_commits? = continued.states.commits === proof.states.commits
      same_owners? = continued.states.owner_machines === proof.states.owner_machines
      assert same_commits?, "the owner continuation must recover every original holder commit"
      assert same_owners?, "the owner continuation must recover every original final owner"
    end
  end

  for lifecycle <- [:idle_ping, :reconnect] do
    @tag connection_streams: :pool
    test "Connection streams: a native #{lifecycle} owner handoff has its own sole copy guard",
         context do
      lifecycle = unquote(lifecycle)
      kind = if lifecycle == :idle_ping, do: :ping, else: :disconnect
      observe = fn -> native_renewal_observation(context, lifecycle) end
      {positive, historical, _, _, _, _} = observe.()
      side = observation_side(context, positive, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []

      {corrupted, historical, _, _, _, _} =
        ComparatorMutants.with_connection_owner_copy(observe, kind)

      side = observation_side(context, corrupted, %{}, row!(:issue, :execute), historical)
      proof = ConnectionHistory.build(side)
      assert proof.native.errors == []
      assert proof.reads.errors == []
      assert proof.decoders.errors == []

      arity = if kind == :ping, do: 2, else: 3

      assert [%{rule: :state_owner_copy, at: %{mfa: {DBConnection.Connection, ^kind, ^arity}}}] =
               proof.states.errors

      for mutant <- [:stream_owner_copy, :stream_state_copy, :stream_helper_copy] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> ConnectionHistory.build(side) end)
        expected = if mutant == :stream_owner_copy, do: [], else: proof.errors
        assert checked.errors == expected
      end

      assert ConnectionHistory.build(side).errors == proof.errors
      {restored, historical, _, _, _, _} = observe.()
      side = observation_side(context, restored, %{}, row!(:issue, :execute), historical)
      assert ConnectionHistory.build(side).errors == []
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: origin indexing retains the complete authoritative cache baseline",
       context do
    Repo.put_dynamic_repo(context.repo)
    Repo.all(from(c in "pg_class", prefix: "pg_catalog", select: count(c.oid)))
    historical = Historical.capture(context.prefix)
    assert historical.query_cache.rows != []

    run =
      ExitBoundary.observe(
        fn -> Repo.put_dynamic_repo(context.repo) end,
        fn _ -> SQL.query!(context.repo, "SELECT 31::int4 AS complete_cache_baseline", []) end,
        %{host: [], callbacks: []}
      )

    assert %Postgrex.Result{rows: [[31]]} = run.result
    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    indexed = Origins.build(side)
    complete? = Enum.sort(indexed.query_cache.rows) === Enum.sort(historical.query_cache.rows)
    assert complete?, "origin indexing must retain every authoritative initial cache row"
  end

  @tag connection_streams: :driver
  test "Connection streams: a native query cache keeps its origins across an unchanged prefix cut",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)

    run =
      ExitBoundary.observe(
        fn -> Repo.put_dynamic_repo(context.repo) end,
        fn _ ->
          query =
            from(c in "pg_class",
              prefix: "pg_catalog",
              where: c.relkind == "r",
              select: count(c.oid)
            )

          Repo.all(query)
          send(self(), :native_query_origin_cut)
          receive do: (:native_query_origin_cut -> :ok)
          Repo.all(query)
          :ok
        end,
        %{host: [], callbacks: []}
      )

    assert run.result == :ok
    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    proof = ConnectionHistory.build(side)
    assert proof.errors == []
    whole = Map.put(side, :connection_history, proof)
    original = QueryOrigins.build(Origins.build(whole), whole)
    assert original.errors == []

    [barrier] =
      for %{event: {_, :receive, :native_query_origin_cut}} = source <- proof.indexed.events,
          do: source

    promotions =
      for {_index, pair} <- proof.native.pairs,
          pair.returned.index < barrier.index,
          {_, :call, {:ets, :insert_new, [table, {_, :cache, _, {_id, _query}}]}} <-
            [pair.source.event],
          table == historical.query_cache.table,
          {_, :return_from, _, true} <- [pair.returned.event],
          do: pair.source.index

    assert promotions != [], "the real prefix must commit a new Ecto cache origin"
    assert {:ok, checkpoint} = Historical.cut(historical, proof, barrier.index)

    continued_side = %{
      side
      | historical: checkpoint,
        run: %{run | events: Enum.drop(run.events, barrier.index)}
    }

    continued = ConnectionHistory.build(continued_side)
    assert continued.errors == []
    continued_side = Map.put(continued_side, :connection_history, continued)
    indexed = Origins.build(continued_side)
    queries = QueryOrigins.build(indexed, continued_side)

    assert queries.errors == [],
           "a qualified prefix cache origin cannot require a second suffix generator"

    same_origins? = queries.ids === original.ids and queries.names === original.names
    assert same_origins?, "the unchanged suffix must retain every original query cache identity"
    assert Enum.all?(queries.cache_events, &(&1 >= barrier.index))
  end

  @tag connection_streams: :driver
  @tag prepare: :named
  test "Connection streams: a failed Ecto cache candidate cannot become a query origin",
       context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)
    cache_table = historical.query_cache.table

    run =
      ExitBoundary.observe(
        fn -> Repo.put_dynamic_repo(context.repo) end,
        fn _ ->
          Repo.all(from(c in "pg_class", prefix: "pg_catalog", select: count(c.oid)))

          cached =
            Enum.find(:ets.tab2list(cache_table), fn
              {_, :cached, _, {_, %Postgrex.Query{}}} -> true
              _ -> false
            end)

          {key, :cached, selection, {_id, query}} = cached
          candidate_id = System.unique_integer([:positive])
          prepared = {candidate_id, IO.iodata_to_binary(query.statement)}
          false = :ets.insert_new(cache_table, {key, :cache, selection, prepared})
          candidate_id
        end,
        %{host: [], callbacks: []}
      )

    assert is_integer(run.result)
    side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
    history = ConnectionHistory.build(side)
    assert history.errors == []
    side = Map.put(side, :connection_history, history)
    indexed = Origins.build(side)
    queries = QueryOrigins.build(indexed, side)
    assert queries.errors == []
    refute run.result in Map.values(queries.ids)
  end

  @tag connection_streams: :driver
  test "Connection streams: causal roles depend only on captured identity facts", context do
    Repo.put_dynamic_repo(context.repo)
    historical = Historical.capture(context.prefix)

    loop = fn again ->
      receive do
        {:ping, caller, reference} ->
          send(caller, {reference, :ok})
          again.(again)

        :stop ->
          :ok
      end
    end

    peer = spawn(fn -> loop.(loop) end)
    monitor = Process.monitor(peer)

    try do
      run =
        ExitBoundary.observe(
          fn -> Repo.put_dynamic_repo(context.repo) end,
          fn _ ->
            reference = make_ref()
            send(peer, {:ping, self(), reference})

            receive do
              {^reference, :ok} -> :ok
            end
          end,
          %{host: [], callbacks: []}
        )

      assert run.result == :ok
      side = observation_side(context, run, %{}, row!(:issue, :execute), historical)
      before = Origins.build(side)
      assert Map.has_key?(before.roles, peer)
      true = Process.register(peer, :ash_onetime_causal_role_peer)
      after_registration = Origins.build(side)

      assert after_registration.roles == before.roles,
             "a later live registration cannot change the identity of an unchanged capture"
    after
      send(peer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^peer, :normal}
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: raw ledgers finish before projected consumers", context do
    pair = observe(context, row!(:issue, :execute), Values.set()[:va])

    proofs = [
      {NativeTransport, :build, 3},
      {ConnectionReads, :build, 3},
      {ConnectionDecoders, :build, 5},
      {ConnectionStates, :build, 5}
    ]

    # Every raw projection boundary in the current comparator, including the
    # registered rules. A new consumer must join this same ordering obligation.
    consumers = [
      {Origins, :build, 1},
      {Declarations, :pair, 2},
      {Scheduling, :build, 2},
      {PermittedTrace, :match, 2},
      {References, :operation_slots, 2},
      {References, :locator_copies, 1},
      {FailureTrace, :check, 2},
      {Readback, :check, 3},
      {Refusals, :check, 2},
      {Origins, :pair, 3},
      {Origins, :pair, 4},
      {Origins, :permitted_sources, 2},
      {HostCall, :addresses, 1},
      {Registry, :compute, 2},
      {Allocation, :check, 2},
      {Allocation, :pair, 5},
      {QueryOrigins, :build, 2},
      {ClockExpressions, :build, 2},
      {TransportReferences, :build, 2},
      {Wire, :build, 2},
      {DatabaseOrigins, :build, 2},
      {DatabaseOrigins, :sql_contexts, 1}
    ]

    consumers =
      if function_exported?(ConnectionHistory, :render, 2),
        do: [{ConnectionHistory, :render, 2} | consumers],
        else: consumers

    events = comparator_call_order(fn -> Comparator.compare(pair) end, proofs ++ consumers)

    for mfa <- proofs do
      calls = Enum.count(events, &match?({:call, ^mfa, _}, &1))
      completed = Enum.filter(events, &match?({:return, ^mfa, _}, &1))
      successful? = Enum.all?(completed, &match?({:return, ^mfa, true}, &1))

      assert calls >= 2 and length(completed) == calls and successful?,
             "the ordering witness requires successful raw proofs on both sides"
    end

    first = Enum.find_index(events, fn {kind, mfa, _} -> kind == :call and mfa in consumers end)
    assert is_integer(first)
    preceding = Enum.take(events, first)

    for mfa <- proofs do
      completed = Enum.filter(preceding, &match?({:return, ^mfa, true}, &1))

      assert length(completed) == 3,
             "both raw ledgers and the complete OPEN reference must finish before projection"
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: the complete OPEN reference passes raw proof before origin collection",
       context do
    pair = observe(context, row!(:issue, :execute), Values.set()[:va])
    assert Map.has_key?(pair.run, :readback_reference)

    proofs = [
      {NativeTransport, :build, 3},
      {ConnectionReads, :build, 3},
      {ConnectionDecoders, :build, 5},
      {ConnectionStates, :build, 5}
    ]

    origin = {Origins, :build, 1}
    events = comparator_call_order(fn -> Comparator.compare(pair) end, proofs ++ [origin])
    first_origin = Enum.find_index(events, &match?({:call, ^origin, _}, &1))
    assert is_integer(first_origin)
    before_origin = Enum.take(events, first_origin)

    for proof <- proofs do
      assert Enum.count(before_origin, &match?({:return, ^proof, true}, &1)) == 3,
             "run, twin and complete read-only reference must pass raw proof before origins"
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: OPEN reuses whole raw proof after origin collection", context do
    pair = observe(context, row!(:issue, :execute), Values.set()[:va])

    proofs = [
      {NativeTransport, :build, 3},
      {ConnectionReads, :build, 3},
      {ConnectionDecoders, :build, 5},
      {ConnectionStates, :build, 5}
    ]

    origin = {Origins, :build, 1}
    events = comparator_call_order(fn -> Comparator.compare(pair) end, proofs ++ [origin])
    first_origin = Enum.find_index(events, &match?({:call, ^origin, _}, &1))
    assert is_integer(first_origin)
    before_origin = Enum.take(events, first_origin)

    for proof <- proofs do
      assert Enum.count(before_origin, &match?({:return, ^proof, true}, &1)) == 3
    end

    later_raw? =
      events
      |> Enum.drop(first_origin)
      |> Enum.any?(fn {kind, mfa, _} -> kind == :call and mfa in proofs end)

    refute later_raw?, "OPEN must reuse its whole raw proof instead of validating a cut capture"
  end

  @tag connection_streams: :driver
  test "Connection streams: OPEN claims its full frontend request and associated replies",
       context do
    pair = observe(context, row!(:issue, :execute), Values.set()[:va])
    proof = ConnectionHistory.build(pair.run)
    reference = pair.run.readback_reference
    reference_proof = ConnectionHistory.build(reference)
    assert proof.errors == [] and reference_proof.errors == []
    rendered = Registry.compute(:connection_stream, [proof, proof.indexed])
    assert rendered.errors == []

    side =
      pair.run
      |> Map.put(:connection_history, proof)
      |> Map.put(:readback_reference, Map.put(reference, :connection_history, reference_proof))
      |> Map.put(:run, %{pair.run.run | events: rendered.events})

    indexed = Origins.build(side)
    permitted = PermittedTrace.match(side, indexed)
    assert permitted.errors == []
    readback = Readback.check(side, indexed, permitted.bound)

    assert [request] =
             for(
               source <- indexed.events,
               MapSet.member?(readback.claimed, Capture.address(source)),
               %{wire_frame: %{direction: :frontend, decoded: {:bind, _, _, _, _, _}}} <-
                 [source],
               do: source
             )

    {:bind, _, _, _, parameters, _} = request.wire_frame.decoded
    claim = permitted.bound.c_admit

    assert Enum.map(parameters, &elem(&1, 4)) == [
             claim.logical_partition,
             claim.operation_hash,
             claim.scope_hash,
             claim.key_hash,
             {:uuid, claim.id},
             claim.effect_attempt
           ]

    assert String.contains?(request.wire_sql, "AND effect_attempt = $6::bigint")
    {:connection_message, port, :frontend, ordinal} = request.message_address

    assert Enum.any?(indexed.events, fn source ->
             match?(
               %{
                 message_address: {:connection_message, ^port, :backend, _},
                 wire_frame: %{request: ^ordinal, decoded: {:data_row, _}}
               },
               source
             ) and MapSet.member?(readback.claimed, Capture.address(source))
           end)
  end

  @tag connection_streams: :driver
  test "Connection streams: every prior raw history finishes before origin collection", context do
    pair = observe(context, row!(:issue, :replay), Values.set()[:va])
    assert pair.run.prior != nil and pair.twin.prior != nil

    proofs = [
      {NativeTransport, :build, 3},
      {ConnectionReads, :build, 3},
      {ConnectionDecoders, :build, 5},
      {ConnectionStates, :build, 5}
    ]

    origin = {Origins, :build, 1}
    events = comparator_call_order(fn -> Comparator.compare(pair) end, proofs ++ [origin])
    first_origin = Enum.find_index(events, &match?({:call, ^origin, _}, &1))
    assert is_integer(first_origin)
    before_origin = Enum.take(events, first_origin)

    for proof <- proofs do
      assert Enum.count(before_origin, &match?({:return, ^proof, true}, &1)) == 5,
             "every prior/current side and the prior OPEN reference must pass raw proof first"
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: prior invocations retain the whole physical identity map", context do
    pair = observe(context, row!(:issue, :replay), Values.set()[:va])
    assert pair.run.prior != nil and pair.twin.prior != nil

    prior_pair = %{run: pair.run.prior, twin: pair.twin.prior, row: pair.run.prior.row}
    prior = Comparator.compare(prior_pair)
    current = Comparator.compare(pair)
    assert prior.raw_valid? and current.raw_valid?
    assert map_size(prior.pairing.forward) > 0

    assert Map.take(current.pairing.forward, Map.keys(prior.pairing.forward)) ==
             prior.pairing.forward,
           "every prior physical identity must retain its image in the same whole map"

    assert Map.take(current.pairing.reverse, Map.keys(prior.pairing.reverse)) ==
             prior.pairing.reverse

    assert Map.take(current.pairing.uuid_forward, Map.keys(prior.pairing.uuid_forward)) ==
             prior.pairing.uuid_forward

    assert Map.take(current.pairing.uuid_reverse, Map.keys(prior.pairing.uuid_reverse)) ==
             prior.pairing.uuid_reverse
  end

  @tag connection_streams: :driver
  test "Connection streams: MAIN consumes the validated logical observation", context do
    pair = observe(context, row!(:issue, :execute), Values.set()[:va])
    proof = ConnectionHistory.build(pair.run)
    assert proof.errors == []
    rendered = Registry.compute(:connection_stream, [proof, proof.indexed])
    assert rendered.errors == []

    assert Enum.any?(rendered.events, fn
             %{
               event:
                 {_, :call,
                  {:prim_inet, :send, [_, {:connection_byte_span, _, :frontend, _, _, _}, _, _]}}
             } ->
               true

             _ ->
               false
           end),
           "the MAIN witness must exercise a rendered native send copy"

    scheduled = Scheduling.build(%{proof.indexed | events: rendered.events}, proof.native)
    assert scheduled.errors == []

    proofs = [
      {NativeTransport, :build, 3},
      {ConnectionReads, :build, 3},
      {ConnectionDecoders, :build, 5},
      {ConnectionStates, :build, 5}
    ]

    legacy = [{TransportReferences, :build, 2}, {Wire, :build, 2}]
    renderer = {ConnectionHistory, :render, 2}
    functions = proofs ++ legacy ++ [{Origins, :build, 1}]

    functions =
      if function_exported?(ConnectionHistory, :render, 2),
        do: [renderer | functions],
        else: functions

    events = comparator_call_order(fn -> Comparator.compare(pair) end, functions)

    for mfa <- proofs do
      calls = Enum.count(events, &match?({:call, ^mfa, _}, &1))
      completed = Enum.filter(events, &match?({:return, ^mfa, _}, &1))
      successful? = Enum.all?(completed, &match?({:return, ^mfa, true}, &1))

      assert calls >= 2 and length(completed) == calls and successful?,
             "the MAIN witness requires successful raw proofs on both sides"
    end

    consumed = Enum.count(events, &match?({:return, ^renderer, true}, &1))
    assert consumed >= 2, "MAIN must consume both validated logical connection observations"

    first_origins = Enum.find_index(events, &match?({:call, {Origins, :build, 1}, _}, &1))
    assert is_integer(first_origins)
    before_origins = Enum.take(events, first_origins)

    assert Enum.count(before_origins, &match?({:return, ^renderer, true}, &1)) == 2,
           "both whole logical renderings must finish before origin collection"

    legacy? = Enum.any?(events, fn {kind, mfa, _} -> kind == :call and mfa in legacy end)
    refute legacy?, "MAIN cannot compare native packet boundaries as logical messages"
  end

  defp comparator_call_order(callback, functions) do
    parent = self()
    token = make_ref()

    {observer, monitor} =
      spawn_monitor(fn ->
        parent_monitor = Process.monitor(parent)
        comparator_order_observer(parent, parent_monitor, [])
      end)

    session = :trace.session_create(:ash_onetime_comparator_order, observer, [])

    try do
      for {module, _function, _arity} = mfa <- functions do
        Code.ensure_loaded!(module)
        1 = :trace.function(session, mfa, [{:_, [], [{:exception_trace}]}], [:local])
      end

      1 = :trace.process(session, self(), true, [:call, :arity, :strict_monotonic_timestamp])
      _result = callback.()
      1 = :trace.process(session, self(), false, [:call])
      fence = :trace.delivered(session, :all)

      receive do
        {:trace_delivered, :all, ^fence} -> :ok
      after
        5_000 -> flunk("the comparator order trace did not reach its native fence")
      end

      send(observer, {:snapshot, self(), token})

      receive do
        {^token, events} -> events
      after
        5_000 -> flunk("the comparator order observer did not return its native events")
      end
    after
      :trace.session_destroy(session)
      send(observer, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^observer, reason} -> assert reason == :normal
      after
        5_000 ->
          Process.exit(observer, :kill)
          flunk("the comparator order observer did not stop")
      end
    end
  end

  # Retain only source-owned MFAs and success flags. Captured arguments and
  # results may contain the entire private observation and never leave here.
  defp comparator_order_observer(parent, parent_monitor, events) do
    receive do
      {:trace_ts, _pid, :call, {module, function, arity}, stamp} when is_integer(arity) ->
        event = {:call, {module, function, arity}, nil}
        comparator_order_observer(parent, parent_monitor, [{stamp, event} | events])

      {:trace_ts, _pid, :return_from, mfa, %{errors: errors}, stamp} ->
        event = {:return, mfa, errors == []}
        comparator_order_observer(parent, parent_monitor, [{stamp, event} | events])

      {:trace_ts, _pid, :return_from, mfa, _result, stamp} ->
        comparator_order_observer(parent, parent_monitor, [{stamp, {:return, mfa, nil}} | events])

      {:trace_ts, _pid, :exception_from, mfa, _reason, stamp} ->
        comparator_order_observer(parent, parent_monitor, [
          {stamp, {:exception, mfa, false}} | events
        ])

      {:snapshot, ^parent, token} ->
        ordered = events |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
        send(parent, {token, ordered})

      :stop ->
        :ok

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        :ok
    end
  end

  defp table_barrier(observer, token, tables, holders, phase) do
    %{connection_id: backend, rows: catalog} =
      SQL.query!(
        Repo.get_dynamic_repo(),
        "SELECT name, statement, parameter_types::oid[] FROM pg_prepared_statements ORDER BY name",
        []
      )

    send(observer, {:native_tables_cut, token, self(), tables, holders, backend, catalog, phase})

    receive do
      {:native_tables_cut, ^token, ^phase, :observed} -> :ok
    after
      5_000 -> raise "the native cache observer did not acknowledge its live read"
    end
  end

  defp native_renewal_observation(context, lifecycle) do
    parent = self()
    token = make_ref()

    {observer, monitor} =
      spawn_monitor(fn ->
        parent_monitor = Process.monitor(parent)
        holder_observer(parent, token, parent_monitor)
      end)

    try do
      run =
        ExitBoundary.observe(
          fn ->
            options =
              Repo.config()
              |> Keyword.put(:name, nil)
              |> Keyword.put(:pool, DBConnection.ConnectionPool)
              |> Keyword.put(:pool_size, 1)
              |> Keyword.put(:idle_interval, 5_000)
              |> Keyword.put(:types, Postgrex.DefaultTypes)

            {:ok, dynamic_repo} = Repo.start_link(options)
            Repo.put_dynamic_repo(dynamic_repo)
            %{pid: pool} = Ecto.Repo.Registry.lookup(dynamic_repo)

            try do
              %{rows: [[17]]} = Postgrex.query!(pool, "SELECT 17::int4 AS holder_renewal", [])

              historical = Historical.capture(context.prefix)

              [{holder, connection}] =
                Enum.filter(historical.connections, fn {_holder, connection} ->
                  connection.pool == pool
                end)

              send(parent, {:native_renewal_initial, token, historical, holder})

              %{
                dynamic_repo: dynamic_repo,
                pool: pool,
                owner: connection.owner
              }
            catch
              kind, reason ->
                Supervisor.stop(dynamic_repo)
                :erlang.raise(kind, reason, __STACKTRACE__)
            end
          end,
          fn %{dynamic_repo: dynamic_repo, pool: pool, owner: owner} ->
            try do
              {:ok, pool_ref, Postgrex.Protocol, _checkin, _protocol} =
                DBConnection.Holder.checkout(pool, [self()], [])

              send(observer, {:native_holder_factory_watch, token, self(), owner})

              receive do
                {:native_holder_factory_watch, ^token, :armed} -> :ok
              after
                5_000 -> raise "the independent holder factory observer did not arm"
              end

              case lifecycle do
                :idle_ping ->
                  :ok = DBConnection.Holder.checkin(pool_ref)

                :reconnect ->
                  :ok =
                    DBConnection.Holder.disconnect(pool_ref, %DBConnection.ConnectionError{
                      message: "native reconnect witness",
                      severity: :debug
                    })
              end

              renewed =
                receive do
                  {:native_holder_factory, ^token, holder} -> holder
                after
                  15_000 -> raise "the native pool did not complete its holder renewal"
                end

              %{rows: [[53]]} = Postgrex.query!(pool, "SELECT 53::int4 AS holder_renewal", [])
              DBConnection.get_connection_metrics(pool)
              send(observer, {:native_holder_cut, token, self(), renewed, :renewed})

              receive do
                {:native_holder_cut, ^token, :renewed, :observed} -> :ok
              after
                5_000 -> raise "the renewed holder's independent live read did not finish"
              end

              :ok
            after
              Supervisor.stop(dynamic_repo)
            end
          end,
          %{
            host: [],
            callbacks: [],
            preexisting: fn state -> [state.dynamic_repo, state.pool, state.owner] end
          }
        )

      assert run.result == :ok

      {historical, original} =
        receive do
          {:native_renewal_initial, ^token, historical, holder} -> {historical, holder}
        after
          0 -> flunk("the native renewal must retain its pre-observation holder history")
        end

      {renewed, row} =
        receive do
          {:native_holder_snapshot, ^token, :renewed, holder, row} -> {holder, row}
        after
          0 -> flunk("the native renewal must retain the independent committed holder row")
        end

      {run, historical, original, renewed, row, token}
    after
      send(observer, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^observer, reason} -> assert reason == :normal
      after
        5_000 ->
          Process.exit(observer, :kill)
          flunk("the independent holder factory observer did not stop")
      end
    end
  end

  defp holder_observer(parent, token, parent_monitor) do
    receive do
      {:native_holder_factory_watch, ^token, caller, owner} ->
        observe_holder_factory(caller, token, owner)
        holder_observer(parent, token, parent_monitor)

      {:native_holder_cut, ^token, caller, holder, phase} ->
        [row] = :ets.lookup(holder, :conn)
        send(parent, {:native_holder_snapshot, token, phase, holder, row})
        send(caller, {:native_holder_cut, token, phase, :observed})
        holder_observer(parent, token, parent_monitor)

      {:native_tables_cut, ^token, caller, tables, holders, backend, catalog, phase} ->
        rows = Map.new(tables, &{&1, Enum.sort(:ets.tab2list(&1))})
        holder_rows = Map.new(holders, &{&1, :ets.lookup(&1, :conn)})
        send(parent, {:native_tables_snapshot, token, phase, rows})
        send(parent, {:native_holder_tables_snapshot, token, phase, holder_rows})
        send(parent, {:native_catalog_snapshot, token, phase, backend, catalog})
        send(caller, {:native_tables_cut, token, phase, :observed})
        holder_observer(parent, token, parent_monitor)

      {:native_pool_clock_cut, ^token, caller, pool, phase} ->
        clocks =
          for table <- :ets.all(),
              :ets.info(table, :name) == DBConnection.ConnectionPool.Queue,
              :ets.info(table, :owner) == pool,
              {{clock, holder}} <- :ets.tab2list(table),
              into: %{},
              do: {holder, clock}

        send(parent, {:native_pool_clock_snapshot, token, phase, clocks})
        send(caller, {:native_pool_clock_cut, token, phase, :observed})
        holder_observer(parent, token, parent_monitor)

      :stop ->
        :ok

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        :ok
    end
  end

  defp observe_holder_factory(caller, token, owner) do
    session = :trace.session_create(:ash_onetime_holder_factory, self(), [])

    try do
      1 =
        :trace.function(
          session,
          {DBConnection.Holder, :update, 5},
          [{:_, [], [{:exception_trace}]}],
          [:local]
        )

      1 = :trace.process(session, owner, true, [:call, :arity])
      send(caller, {:native_holder_factory_watch, token, :armed})

      receive do
        {:trace, ^owner, :return_from, {DBConnection.Holder, :update, 5}, {:ok, holder}} ->
          send(caller, {:native_holder_factory, token, holder})
      after
        15_000 -> raise "the independent observer did not receive the actual Holder.update return"
      end
    after
      :trace.session_destroy(session)
    end
  end

  defp holder_states(corruption) do
    run = ConnectionNative.observe_holder(corruption)
    assert run.result == :ok

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events}, run.native_history)
    assert native.errors == []
    streams = ConnectionReads.build(native)
    assert streams.errors == []
    decoders = ConnectionDecoders.build(%{events: events}, native, streams, run.native_history)
    assert decoders.errors == []

    states =
      ConnectionStates.build(
        %{events: events},
        native,
        decoders,
        run.native_history
      )

    {%{
       events: events,
       native: native,
       decoders: decoders,
       historical: run.native_history,
       initial: run.initial_state
     }, states}
  end

  @tag connection_streams: :driver
  test "Connection streams: cached query copies are independently bound" do
    captured = cached_decoders(:query_copy)
    assert Enum.map(captured.decoders.errors, & &1.rule) == [:decoder_query_copy]

    for mutant <- [:stream_length, :stream_timeout, :stream_required, :stream_query_copy] do
      checked =
        ComparatorMutants.with_mutant(mutant, fn ->
          ConnectionDecoders.build(
            %{events: captured.events},
            captured.native,
            captured.streams,
            captured.historical
          )
        end)

      expected = if mutant == :stream_query_copy, do: [], else: [:decoder_query_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(cached_decoders(:query_copy).decoders.errors, & &1.rule) ==
             [:decoder_query_copy]

    assert cached_decoders(nil).decoders.errors == []
    IO.puts("CONNECTION_STREAM_NATIVE_ISOLATION: stream_query_copy RED; exact restore GREEN")
  end

  defp cached_decoders(corruption, shape \\ :rows) do
    %{run: run, history: history} = ConnectionNative.observe_cached(corruption, shape)

    if shape in [:bind_error, :execute_error] do
      assert {:error, %Postgrex.Error{postgres: %{code: :division_by_zero}}} = run.result
    else
      assert native_result(run) == {:ok, cached_rows(shape)}
    end

    [origin] = history.history.descriptors
    query = origin.query
    framing = Wire.frames(history.chunks)
    assert framing.errors == []

    context = %{
      sql: IO.iodata_to_binary(query.statement),
      statement: {:historical_statement, query.name},
      parameter_types: [],
      columns: [],
      binds: []
    }

    catalog =
      Enum.reduce(framing.messages, context, fn frame, context ->
        if frame.direction == :backend and frame.tag in [?t, ?T, ?n] do
          {_decoded, context} = Wire.decode_message(frame.tag, frame.payload, context)
          context
        else
          context
        end
      end)

    assert_cached_catalog(shape, query, catalog)

    indexed =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    refute Enum.any?(indexed, &(&1.mfa == {Postgrex.Protocol, :handle_prepare, 3}))
    historical = %{history.holder => history.history}
    native = NativeTransport.build(%{events: indexed}, historical)
    assert native.errors == []

    protocol = ConnectionProtocol.new(%{query.name => catalog})
    streams = ConnectionReads.build(native, MapSet.new(), %{origin.port => protocol})

    assert streams.errors == []
    decoders = ConnectionDecoders.build(%{events: indexed}, native, streams, historical, [origin])

    %{
      decoders: decoders,
      run: run,
      origin: origin,
      events: indexed,
      native: native,
      streams: streams,
      historical: historical,
      initial: run.initial_state
    }
  end

  defp assert_cached_catalog(shape, _query, catalog)
       when shape in [:rows, :cross_connection, :strict, :bind_error, :execute_error] do
    assert catalog.parameter_types == [23]
    assert [{"connection_stream_probe", {:table_oid, 0}, 0, 23, 4, -1, 0}] = catalog.columns
    assert catalog.description == :rows
  end

  defp assert_cached_catalog(:large_rows, _query, catalog) do
    assert catalog.parameter_types == [23]

    assert [
             {"connection_stream_probe", {:table_oid, 0}, 0, 23, 4, -1, 0},
             {"filler", {:table_oid, 0}, 0, 25, -1, -1, 0}
           ] = catalog.columns

    assert catalog.description == :rows
  end

  defp assert_cached_catalog(:redescribe, _query, catalog) do
    assert catalog.parameter_types == []
    assert [{"connection_stream_probe", {:table_oid, oid}, 1, 23, 4, -1, 0}] = catalog.columns
    assert is_integer(oid) and oid > 0
    assert catalog.description == :rows
  end

  defp assert_cached_catalog(shape, query, catalog)
       when shape in [:none, :notice, :parameter, :notification] do
    assert catalog.parameter_types == []
    assert catalog.columns == []
    assert catalog.description == :none
    assert query.columns == nil and query.result_oids == nil
  end

  defp cached_rows(shape) when shape in [:none, :notice, :parameter, :notification], do: nil
  defp cached_rows(:large_rows), do: [[17, :binary.copy("x", 131_072)]]
  defp cached_rows(:redescribe), do: [[17, "native"]]
  defp cached_rows(_shape), do: [[17]]

  @tag connection_streams: :transport
  test "Connection streams: native active delivery changes back to passive mode" do
    run = ConnectionNative.observe(:active)
    assert run.result == :ok
    streams = native_stream_chunks(%{run: run})
    assert map_size(streams) == 1

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events})
    assert native.errors == []
    assert length(native.writes) == 1
    assert Enum.map(native.options, & &1.mode) == [:once, false]
    assert length(native.active) == 1

    for delivery <- native.active do
      assert delivery.activation.mode == :once
      assert delivery.activation.requested.index < delivery.source.index
      assert delivery.source.index < delivery.returned.index
      assert delivery.copies != []
      assert_native_copies(delivery.copies, events, delivery.bytes)
    end

    for option <- native.options do
      assert option.indexes != []
      assert option.source.index in option.indexes
      assert option.returned.index in option.indexes
      assert option.requested.index < option.replied.index
      assert_native_copies(option.copies, events, option.bytes)
    end

    delivered =
      for %{event: {port, :send, {:tcp, port, bytes}, recipient}} <- events,
          is_port(port),
          do: {recipient, port, bytes}

    assert [{recipient, port, bytes}] = delivered
    assert byte_size(bytes) > 0
    assert Enum.count(events, &(&1.event == {recipient, :receive, {:tcp, port, bytes}})) == 1

    programs =
      for %{event: {pid, :call, {:prim_inet, :setopts, [^port, [active: mode]]}}} = source <-
            events do
        assert mode in [:once, false]
        %{returned: returned} = Map.fetch!(native.pairs, source.index)
        own = Enum.filter(events, &(&1.index >= source.index and &1.index <= returned.index))
        command = 0x03F1A300 + 7
        code = if mode == :once, do: 2, else: 0
        expected = <<22, code::32>>

        controls =
          for %{event: {^pid, :call, {:erts_internal, :port_control, [^port, ^command, data]}}} <-
                own,
              do: IO.iodata_to_binary(data)

        assert controls == [expected]
        calls = for event <- own, event.pid == pid, do: {elem(event.event, 1), event.mfa}
        %{mode: mode, calls: calls}
      end

    assert Enum.map(programs, & &1.mode) == [:once, false]

    IO.puts(
      "CONNECTION_STREAM_ACTIVE_PROGRAMS: " <> Diagnostics.render(programs, limit: :infinity)
    )

    demand = ConnectionReads.build(native)
    assert demand.errors == []

    for {_port, chunks} <- streams do
      framing = Wire.frames(chunks)
      assert framing.errors == []
      protocol = ConnectionProtocol.build(framing.messages)
      assert protocol.errors == []

      assert Enum.any?(protocol.messages, fn
               %{decoded: {:data_row, [{:data_column, _, _, 0, _, _, _, 23, 0, "17"}]}} -> true
               _ -> false
             end)
    end
  end

  defp assert_native_copies(copies, events, expected) do
    for copy <- copies do
      source = Enum.fetch!(events, copy.index)
      bytes = native_copy_bytes(source.event, copy.path)
      assert is_binary(bytes), "native copy must address its captured data slot"
      assert copy.offset + copy.length <= byte_size(bytes)
      equal? = binary_part(bytes, copy.offset, copy.length) === expected
      assert equal?, "native copy bytes must equal their own transport origin"
    end
  end

  @tag connection_streams: :transport
  test "Connection streams: every active control has its own native option origin" do
    for corruption <- [
          :unbound_active_control,
          :unbound_mode_active_control,
          :unbound_initial_active_control
        ] do
      run = ConnectionNative.observe(:active, corruption)
      assert run.result == :ok

      events =
        run.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      indexed = %{events: events}
      native = NativeTransport.build(indexed)
      assert Enum.map(native.options, & &1.mode) == [:once, false]
      assert Enum.map(native.errors, & &1.actual) == [:native_option_source]
      assert Enum.map(native.errors, & &1.rule) == [:native_option]

      for mutant <- [:stream_length, :stream_timeout, :stream_required, :stream_active_source] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> NativeTransport.build(indexed) end)
        expected = if mutant == :stream_active_source, do: [], else: [:native_option_source]
        assert Enum.map(checked.errors, & &1.actual) == expected
      end

      assert Enum.map(NativeTransport.build(indexed).errors, & &1.actual) == [
               :native_option_source
             ]

      {restored, _streams} = native_connection(:active, nil)
      assert restored.errors == []
      IO.puts("CONNECTION_STREAM_NATIVE_ISOLATION: stream_active_source RED; exact restore GREEN")
    end
  end

  @tag connection_streams: :transport
  test "Connection streams: deferred controls use their actual native driver replies" do
    {native, streams} = native_connection(:contended, nil)
    assert native.errors == []
    assert streams.errors == []

    deferred =
      for read <- native.reads,
          index <- read.indexes,
          {:ok, %{returned: %{event: {_, :return_from, mfa, ref}}}} <-
            [Map.fetch(native.pairs, index)],
          mfa == {:erts_internal, :port_control, 3},
          is_reference(ref),
          do: index

    assert deferred != [], "the real contended socket must execute deferred controls"
    IO.puts("CONNECTION_STREAM_DEFERRED_CONTROLS: " <> Diagnostics.render(length(deferred)))
  end

  @tag connection_streams: :transport
  test "Connection streams: Postgrex replays its own unread native buffer" do
    replays =
      for _ <- 1..20 do
        captured = buffered_decoders(nil)
        assert captured.decoders.errors == []

        for replay <- captured.decoders.replays do
          assert length(replay.copies) == 5
          assert_native_copies(replay.copies, captured.events, replay.input)
          assert Enum.sum(Enum.map(replay.provenance, & &1.length)) == byte_size(replay.input)

          for span <- replay.provenance do
            expected = binary_part(replay.input, span.offset - replay.start, span.length)
            assert_native_copies(span.copies, captured.events, expected)
          end
        end

        buffer_replays(captured.events, captured.native)
      end

    replays = List.flatten(replays)

    IO.puts(
      "CONNECTION_STREAM_BUFFER_PROGRAMS: " <> Diagnostics.render(replays, limit: :infinity)
    )

    assert replays != [], "the native runs must actually execute Postgrex buffered replay"
  end

  defp buffer_failure_program(run) do
    for {event, index} <- Enum.with_index(run.events),
        {Postgrex.Protocol, _, _} = mfa <- [event.mfa] do
      phase =
        case event.event do
          {_, :call, {_, _, [%{buffer: buffer} | _]}} when is_binary(buffer) ->
            {:call, {:buffer_bytes, byte_size(buffer)}}

          {_, :call, {_, _, [%{buffer: buffer} | _]}}
          when buffer in [nil, :active_once] ->
            {:call, buffer}

          {_, :exception_from, _, {kind, reason}} ->
            {:exception, kind, native_reason_tag(reason)}

          _ ->
            elem(event.event, 1)
        end

      {index, mfa, phase}
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: an extra native replay copy has no decoder origin" do
    corruptions =
      for _ <- 1..20,
          captured = buffered_decoders(:replay_source),
          captured.foreign? do
        assert Enum.map(captured.decoders.errors, & &1.rule) == [:decoder_replay_source]
        captured
      end

    assert corruptions != [], "the native runs must actually produce the foreign replay copy"
    captured = hd(corruptions)

    for mutant <- [:stream_length, :stream_timeout, :stream_query_copy, :stream_replay_source] do
      checked =
        ComparatorMutants.with_mutant(mutant, fn ->
          ConnectionDecoders.build(
            %{events: captured.events},
            captured.native,
            captured.streams,
            captured.historical
          )
        end)

      expected = if mutant == :stream_replay_source, do: [], else: [:decoder_replay_source]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    restored =
      ConnectionDecoders.build(
        %{events: captured.events},
        captured.native,
        captured.streams,
        captured.historical
      )

    assert Enum.map(restored.errors, & &1.rule) == [:decoder_replay_source]

    fresh =
      Enum.find_value(1..20, fn _ ->
        positive = buffered_decoders(nil)
        assert positive.decoders.errors == []
        if positive.decoders.replays != [], do: positive
      end)

    assert fresh != nil, "the restored validator must accept a fresh actual native replay"
    IO.puts("CONNECTION_STREAM_NATIVE_ISOLATION: stream_replay_source RED; exact restore GREEN")
  end

  defp buffered_decoders(corruption) do
    run = ConnectionNative.observe(:buffered, corruption)

    if native_result(run) != :ok do
      IO.puts(
        "CONNECTION_STREAM_BUFFER_FAILURE: " <>
          Diagnostics.render(%{result: native_result(run), program: buffer_failure_program(run)})
      )
    end

    assert native_result(run) == :ok

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events})
    native = Map.put(native, :historical, run.native_history)
    assert native.errors == []
    assert_native_streams_complete(run)
    streams = ConnectionReads.build(native)
    assert streams.errors == []
    decoders = ConnectionDecoders.build(%{events: events}, native, streams, run.native_history)

    %{
      native: native,
      streams: streams,
      events: events,
      decoders: decoders,
      historical: run.native_history,
      foreign?: Enum.any?(run.events, &foreign_replay_copy?/1)
    }
  end

  defp foreign_replay_copy?(%{event: {pid, :send, {:tcp, _, _}, pid}, stack: stack}),
    do: {Postgrex.Protocol, :activate, 2} not in stack

  defp foreign_replay_copy?(_event), do: false

  defp assert_native_streams_complete(run) do
    for {_port, chunks} <- native_stream_chunks(%{run: run}) do
      framing = Wire.frames(chunks)
      assert framing.errors == []
      protocol = ConnectionProtocol.build(framing.messages)
      assert protocol.errors == []
      assert protocol.pending == []
    end
  end

  defp buffer_replays(events, native) do
    # Retain the actual native replay programs alongside the independent ledgers.
    demand_rules = Enum.map(ConnectionReads.build(native).errors, & &1.rule)
    assert demand_rules == []

    for %{event: {pid, :call, {Postgrex.Protocol, :activate, [_, buffer]}}} = source <- events,
        is_binary(buffer) and byte_size(buffer) > 0 do
      message = {:tcp, hd(native.writes).port, buffer}
      assert Enum.count(events, &(&1.event == {pid, :send, message, pid})) == 1
      assert Enum.count(events, &(&1.event == {pid, :receive, message})) == 1
      stop = native.pairs[source.index].returned.index

      calls =
        for event <- events,
            event.pid == pid and event.index >= source.index and event.index <= stop,
            do: {elem(event.event, 1), event.mfa}

      %{bytes: byte_size(buffer), index: source.index, calls: calls, demand_rules: demand_rules}
    end
  end

  defp native_copy_bytes(event, path) do
    path
    |> Enum.reduce(event, fn
      index, tuple when is_tuple(tuple) -> elem(tuple, index)
      index, list when is_list(list) -> Enum.fetch!(list, index)
    end)
    |> IO.iodata_to_binary()
  rescue
    _error in [ArgumentError, Enum.OutOfBoundsError, FunctionClauseError] -> nil
  end

  @tag connection_streams: :transport
  test "Connection streams: native pipelining preserves each query and response" do
    cases = [
      {:single, nil, ["17"]},
      {:pipeline, nil, ["17", "29"]},
      {:pipeline, :byte, ["18", "29"]},
      {:pipeline, :swap, ["29", "17"]},
      {:pipeline, :drop, ["17"]},
      {:pipeline, :add, ["17", "29", "41"]}
    ]

    for {mode, corruption, expected} <- cases do
      {native, result} = native_connection(mode, corruption)
      assert native.errors == []
      assert result.errors == []

      rows =
        for {_port, connection} <- result.connections,
            %{decoded: {:data_row, columns}} <- connection.protocol.messages,
            {:data_column, _, _, 0, "connection_stream_probe", _, _, 23, 0, value} <- columns,
            do: value

      assert rows == expected
    end
  end

  @tag connection_streams: :transport
  test "Connection streams: real receive corruptions reach their own validation" do
    obligations = [
      {:length, :receive_length, :stream_length},
      {:timeout, :receive_timeout, :stream_timeout},
      {:extra_read, :receive_required, :stream_required}
    ]

    for {corruption, rule, mutant} <- obligations do
      {native, result} = native_connection(:single, corruption)
      assert native.errors == []
      assert Enum.map(result.errors, & &1.rule) == [rule]

      for {_, other_rule, disabled} <- obligations do
        checked =
          ComparatorMutants.with_mutant(disabled, fn ->
            ConnectionReads.build(native)
          end)

        expected = if other_rule == rule, do: [], else: [rule]
        assert Enum.map(checked.errors, & &1.rule) == expected
      end

      assert Enum.map(ConnectionReads.build(native).errors, & &1.rule) == [rule]
      {restored_native, restored} = native_connection(:single, nil)
      assert restored_native.errors == []
      assert restored.errors == []
      IO.puts("CONNECTION_STREAM_NATIVE_ISOLATION: #{mutant} RED #{rule}; exact restore GREEN")
    end
  end

  defp native_connection(mode, corruption) do
    run = ConnectionNative.observe(mode, corruption)
    assert run.result == :ok

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events})
    {native, ConnectionReads.build(native)}
  end

  @tag connection_streams: :transport
  test "Connection streams: backend ownership follows each pipelined frontend request" do
    {native, streams} = native_connection(:pipeline, nil)
    assert native.errors == []
    assert streams.errors == []
    [connection] = Map.values(streams.connections)
    frontend = Enum.filter(connection.protocol.messages, &(&1.direction == :frontend))
    backend = Enum.filter(connection.protocol.messages, &(&1.direction == :backend))
    assert Enum.map(frontend, & &1.request) == [0, 1]
    assert Enum.frequencies_by(backend, & &1.request) == %{0 => 4, 1 => 4}

    rows =
      for %{request: request, decoded: {:data_row, columns}} <- backend,
          {:data_column, _, _, _, _, _, _, 23, _, value} <- columns,
          do: {request, value}

    assert rows == [{0, "17"}, {1, "29"}]

    rejected =
      ComparatorMutants.with_mutant(:stream_request_owner, fn ->
        ConnectionReads.build(native)
      end)

    assert rejected.errors == []
    [wrong_connection] = Map.values(rejected.connections)
    wrong_backend = Enum.filter(wrong_connection.protocol.messages, &(&1.direction == :backend))
    assert Enum.frequencies_by(wrong_backend, & &1.request) == %{0 => 8}

    assert Enum.map(wrong_backend, &Map.delete(&1, :request)) ===
             Enum.map(backend, &Map.delete(&1, :request))

    assert ConnectionReads.build(native) === streams
    {fresh_native, fresh_streams} = native_connection(:pipeline, nil)
    assert fresh_native.errors == []
    assert fresh_streams.errors == []
    [fresh_connection] = Map.values(fresh_streams.connections)
    fresh_backend = Enum.filter(fresh_connection.protocol.messages, &(&1.direction == :backend))
    assert Enum.frequencies_by(fresh_backend, & &1.request) == %{0 => 4, 1 => 4}
  end

  @tag connection_streams: :driver
  test "Connection streams: logical rendering consumes only proved native programs" do
    {proof, indexed} = native_render_fixture(nil)
    assert proof.errors == []
    %{native: native, reads: reads} = proof

    messages = ConnectionReads.messages(reads, indexed)
    assert Enum.count(messages, &(&1.wire_frame.direction == :frontend)) == 2
    assert Enum.count(messages, &(&1.wire_frame.direction == :backend)) == 8

    rows =
      for %{wire_frame: %{decoded: {:data_row, columns}}} <- messages,
          {:data_column, _, _, _, _, _, _, 23, _, value} <- columns,
          do: value

    assert rows == ["17", "29"]

    native_indexes =
      (native.writes ++ native.reads ++ native.options ++ native.active ++ native.passive)
      |> Enum.flat_map(& &1.indexes)
      |> MapSet.new()

    assert MapSet.size(native_indexes) > 0
    untouched = Enum.reject(indexed.events, &MapSet.member?(native_indexes, &1.index))
    assert untouched != []
    render? = function_exported?(ConnectionHistory, :render, 2)
    assert render?, "the main logical connection renderer is absent"
    render = Function.capture(ConnectionHistory, :render, 2)
    rendered = render.(proof, indexed)
    assert rendered.errors == []
    assert MapSet.subset?(rendered.consumed, native_indexes)
    logical = Enum.filter(rendered.events, &Map.has_key?(&1, :message_address))
    assert logical === messages
    remaining = Enum.reject(rendered.events, &Map.has_key?(&1, :message_address))

    # A successful write is an observed operation. Its validated program is
    # not segmentation-forced multiplicity, so proving it grants no erasure.
    for write <- native.writes, index <- write.indexes do
      refute MapSet.member?(rendered.consumed, index)
      source = Enum.find(indexed.events, &(&1.index == index))
      [retained] = Enum.filter(remaining, &(&1.index == index))
      assert Map.take(retained, [:pid, :mfa, :stack]) == Map.take(source, [:pid, :mfa, :stack])
      assert elem(retained.event, 1) == elem(source.event, 1)
    end

    assert Enum.reject(remaining, &MapSet.member?(native_indexes, &1.index)) === untouched
    assert length(remaining) == length(indexed.events) - MapSet.size(rendered.consumed)
  end

  @tag connection_streams: :driver
  test "Connection streams: a write without logical bytes remains an observed operation" do
    {proof, indexed} = native_render_fixture(:empty_write)
    assert proof.errors == []
    [empty] = Enum.filter(proof.native.writes, &(&1.bytes == <<>>))

    assert function_exported?(ConnectionHistory, :render, 2)
    render = Function.capture(ConnectionHistory, :render, 2)
    rendered = render.(proof, indexed)
    assert rendered.errors == []
    refute Enum.any?(empty.indexes, &MapSet.member?(rendered.consumed, &1))

    for index <- empty.indexes do
      source = Enum.find(indexed.events, &(&1.index == index))
      assert source in rendered.events
    end
  end

  @tag connection_streams: :driver
  test "Connection streams: a write-erasing renderer is detected and exactly restored" do
    {proof, indexed} = native_render_fixture(:empty_write)
    assert proof.errors == []
    rendered = Registry.compute(:connection_stream, [proof, indexed])
    assert rendered_writes_retained?(proof, rendered)

    ComparatorMutants.with_mutant(:stream_render_erasure, fn ->
      erased = Registry.compute(:connection_stream, [proof, indexed])
      refute rendered_writes_retained?(proof, erased)

      assert Enum.filter(erased.events, &Map.has_key?(&1, :message_address)) ===
               Enum.filter(rendered.events, &Map.has_key?(&1, :message_address))
    end)

    assert Registry.compute(:connection_stream, [proof, indexed]) === rendered
    {fresh, fresh_indexed} = native_render_fixture(:empty_write)
    assert fresh.errors == []

    assert rendered_writes_retained?(
             fresh,
             Registry.compute(:connection_stream, [fresh, fresh_indexed])
           )
  end

  @tag connection_streams: :driver
  test "Connection streams: rendering refuses a foreign capture or an unproved native read" do
    {proof, indexed} = native_render_fixture(nil)
    {other, other_indexed} = native_render_fixture(nil)
    assert proof.errors == [] and other.errors == []
    foreign = Registry.compute(:connection_stream, [proof, other_indexed])
    assert Enum.map(foreign.errors, & &1.rule) == [:connection_render_source]
    assert foreign.events === other_indexed.events
    assert foreign.consumed == MapSet.new()

    {unproved, unproved_indexed} = native_render_fixture(:extra_read, :single)
    assert unproved.errors != []
    refused = Registry.compute(:connection_stream, [unproved, unproved_indexed])
    assert refused.errors != []
    assert refused.events === unproved_indexed.events
    assert refused.consumed == MapSet.new()
    assert Registry.compute(:connection_stream, [proof, indexed]).errors == []
  end

  @tag connection_streams: :driver
  test "Connection streams: scheduling retains each rendered write's native command origin" do
    {proof, indexed} = native_render_fixture(:empty_write)
    assert proof.errors == []
    assert length(proof.native.writes) > 1
    assert Enum.any?(proof.native.writes, &(&1.bytes == <<>>))
    rendered = Registry.compute(:connection_stream, [proof, indexed])
    assert rendered.errors == []
    view = %{indexed | events: rendered.events}
    scheduled = Scheduling.build(view, proof.native)
    assert scheduled.errors == []
    assert scheduled_write_origins?(proof.native.writes, scheduled.events)

    ComparatorMutants.with_mutant(:stream_scheduling_write_origin, fn ->
      corrupted = Scheduling.build(view, proof.native)
      assert corrupted.errors == []
      refute scheduled_write_origins?(proof.native.writes, corrupted.events)

      assert Enum.sort_by(corrupted.events, &Capture.address/1) ===
               Enum.sort_by(scheduled.events, &Capture.address/1)
    end)

    assert Scheduling.build(view, proof.native) === scheduled
    {fresh, fresh_indexed} = native_render_fixture(:empty_write)
    assert fresh.errors == []
    fresh_rendered = Registry.compute(:connection_stream, [fresh, fresh_indexed])
    assert fresh_rendered.errors == []

    fresh_scheduled =
      Scheduling.build(%{fresh_indexed | events: fresh_rendered.events}, fresh.native)

    assert fresh_scheduled.errors == []
    assert scheduled_write_origins?(fresh.native.writes, fresh_scheduled.events)
  end

  defp scheduled_write_origins?(writes, events) do
    positions =
      events
      |> Enum.with_index()
      |> Map.new(fn {event, position} -> {Capture.address(event), position} end)

    Enum.all?(writes, fn write ->
      caller = write.source.pid
      port = write.port
      ref = write.reference

      [sent] =
        Enum.filter(events, fn
          %{event: {^port, :send, {:inet_reply, ^port, :ok, ^ref}, ^caller}} -> true
          _ -> false
        end)

      Map.fetch!(positions, sent.index) == Map.fetch!(positions, write.command.index) + 1
    end)
  end

  defp rendered_writes_retained?(proof, rendered) do
    retained =
      MapSet.new(Enum.reject(rendered.events, &Map.has_key?(&1, :message_address)), & &1.index)

    Enum.all?(proof.native.writes, fn write ->
      Enum.all?(write.indexes, fn index ->
        MapSet.member?(retained, index) and not MapSet.member?(rendered.consumed, index)
      end)
    end)
  end

  defp native_render_fixture(corruption, mode \\ :pipeline) do
    run = ConnectionNative.observe(mode, corruption)
    assert run.result == :ok
    indexed = %{events: Enum.with_index(run.events, &Map.put(&1, :index, &2))}
    native = NativeTransport.build(indexed, run.native_history)
    reads = ConnectionReads.build(native)
    decoders = ConnectionDecoders.build(indexed, native, reads, run.native_history)

    states =
      ConnectionStates.build(
        indexed,
        native,
        decoders,
        run.native_history,
        {:initial, run.initial_state}
      )

    proof = %{
      indexed: indexed,
      native: native,
      reads: reads,
      decoders: decoders,
      states: states,
      errors: native.errors ++ reads.errors ++ decoders.errors ++ states.errors
    }

    {proof, indexed}
  end

  @tag :comparator_control
  test "C-tick: the twin TTL read falls in the next second", context do
    context = Map.merge(context, %{run_first?: true, between_sides: &next_second/1})

    witness =
      Enum.reduce_while(1..10, nil, fn attempt, _ ->
        pair = observe(context, row!(:issue, :execute), Values.set()[:va])
        run = ttl_reads(pair.run)
        twin = ttl_reads(pair.twin)
        assert run != [] and twin != []
        delta = DateTime.to_unix(hd(twin)) - DateTime.to_unix(List.last(run))

        IO.puts(
          "C_TICK_READS" <>
            ": " <>
            Diagnostics.render(%{attempt: attempt, run: run, twin: twin, seconds: delta},
              pretty: true
            )
        )

        assert_green(pair)

        if delta == 1, do: {:halt, {run, twin}}, else: {:cont, nil}
      end)

    assert {run, twin} = witness
    assert DateTime.to_unix(hd(twin)) - DateTime.to_unix(List.last(run)) == 1
  end

  for size <- [2, 3] do
    @tag :comparator_control
    @tag pool_size: size
    test "C-anchor and U8: different pool anchors, pool size #{size}", context do
      context =
        Map.put(context, :between_sides, fn _side -> warm_pool!(context.repo, unquote(size)) end)

      pair = observe(context, row!(:external_issue, :execute), Values.set()[:va])
      run = anchors(pair.run)
      twin = anchors(pair.twin)
      assert map_size(run) > 0 and map_size(twin) > 0
      assert Enum.any?(run, fn {key, value} -> Map.has_key?(twin, key) and twin[key] != value end)
      assert_green(pair)
      assert_pool_monitor_origins(pair)
    end

    @tag :comparator_control
    @tag pool_size: size
    test "C-interleave and U8: independent roles interleave, pool size #{size}", context do
      row = row!(:external_issue, :execute)
      context = with_references(context, [row])

      result =
        Enum.reduce_while(1..10, false, fn _, _ ->
          pair = Scenarios.observe(row, Values.set()[:va], context)
          assert_green(pair)
          assert_pool_monitor_origins(pair)
          run = role_order(pair.run)
          twin = role_order(pair.twin)
          assert length(Enum.uniq(run)) > 1
          if run != twin, do: {:halt, true}, else: {:cont, false}
        end)

      assert result, "C-interleave did not witness a different cross-role interleaving"
    end
  end

  @tag :u1
  test "U1: the re-raise keeps the term, erases, and leaves armed_call", context do
    pair = observe(context, row!(:issue, :consumer_failure, :after_throw), Values.set()[:va])
    root = pair.run.run.snapshot.root

    tail =
      pair.run.run.events
      |> Enum.map(& &1.event)
      |> Enum.drop_while(fn
        {^root, :exception_from, {AshOnetime.Delivery, :armed, 4}, _} -> false
        _ -> true
      end)

    assert match?([{^root, :exception_from, {AshOnetime.Delivery, :armed, 4}, _} | _], tail)
    assert Enum.any?(tail, &match?({^root, :call, {:erlang, :erase, [_]}}, &1))

    assert Enum.any?(
             tail,
             &match?({^root, :exception_from, {AshOnetime.Delivery, :armed_call, 4}, _}, &1)
           )

    raises = Enum.filter(tail, &match?({^root, :call, {:erlang, :raise, [_, _, _]}}, &1))

    IO.puts(
      "U1_RERAISE" <>
        ": " <>
        Diagnostics.render(Enum.map(tail, fn e -> {elem(e, 1), event_mfa(e)} end), pretty: true)
    )

    assert raises == []
    assert_green(pair)
  end

  @tag :u2
  @tag :u4
  test "U2 and U4: hold release reaches GREATEST and its next wire row", context do
    row =
      row!(:external_issue, :execute) |> Map.put(:fault, :held) |> Map.put(:release_hold?, true)

    pair = observe(context, row, Values.set()[:va])
    events = pair.run.run.events

    checkpoint = {Scenarios, :allocation_checkpoint, 0}

    checkpoint_events =
      pair.twin
      |> Origins.build()
      |> Map.fetch!(:events)
      |> Enum.filter(&(&1.mfa == checkpoint or checkpoint in &1.stack))

    IO.puts(
      "U2_ALLOCATION_NATIVE_CHECKPOINT" <>
        ": " <>
        Diagnostics.render(
          Enum.map(checkpoint_events, fn event ->
            Map.take(event, [:index, :role, :mfa, :stack])
            |> Map.put(:event, Diagnostics.safe(event.event))
          end),
          pretty: true,
          limit: :infinity
        )
    )

    assert Enum.any?(checkpoint_events, &match?({_, :call, _}, &1.event)),
           "the declared caller allocation checkpoint must execute natively"

    assert Enum.any?(
             events,
             &match?(
               %{
                 event:
                   {_, :call, {AshOnetime.Store.Postgres, :release_query, [_, "boundary-hold"]}}
               },
               &1
             )
           )

    assert Enum.any?(events, fn
             %{event: {_, :call, {Postgrex, :query, [_connection, sql, _, _]}}} ->
               String.contains?(IO.iodata_to_binary(sql), "GREATEST(")

             _ ->
               false
           end)

    wire = pair.run |> Origins.build() |> TransportReferences.build() |> Wire.build()
    rows = wire |> Enum.flat_map(&wire_terms(&1.event, :data_row))

    assert Enum.any?(rows, fn {:data_row, columns} ->
             Enum.any?(columns, fn
               {:data_column, sql, _, _, "retain_until", _, _, 1184, 1, {:timestamptz, _}} ->
                 String.starts_with?(sql, "SELECT id, logical_partition")

               _ ->
                 false
             end)
           end)

    history = ConnectionHistory.build(pair.run)
    assert history.errors == []
    side = Map.put(pair.run, :connection_history, history)
    indexed = Origins.build(side)
    scheduled = Scheduling.build(indexed, history.native)
    indexed = %{indexed | events: scheduled.events}
    permitted = PermittedTrace.match(side, indexed)
    readback = Readback.check(side, indexed, permitted.bound)

    root = {AshOnetime.Store, :committed_completion, 2}
    start = Enum.find(indexed.events, &(&1.mfa == root and elem(&1.event, 1) == :call))
    stop = Enum.find(indexed.events, &(&1.mfa == root and elem(&1.event, 1) == :return_from))

    outside = Enum.reject(readback.claimed, &(&1 >= start.index and &1 <= stop.index))

    origins =
      for event <- Wire.build(indexed, readback.claimed),
          is_port(event.pid),
          {:data_column, sql, {origin, _}, 0, _, _, _, _, _, _} <-
            wire_terms(event.event, :data_column) do
        raw = Enum.at(pair.run.run.events, event.index).event
        {_, :send, message, _} = raw

        payload =
          case message do
            {:inet_async, _, _, {:ok, bytes}} -> bytes
            {:tcp, _, bytes} -> bytes
          end

        %{
          index: event.index,
          origin: origin,
          sql_sha256: :crypto.hash(:sha256, sql),
          packet_sha256: :crypto.hash(:sha256, payload),
          columns: length(wire_terms(event.event, :data_column))
        }
      end

    assert Enum.any?(origins, &match?(%{origin: {:wire_statement, :committed_read, _}}, &1))
    assert Enum.any?(origins, &match?(%{origin: {:wire_statement, :shared, _}}, &1))

    IO.puts(
      "U2_NATIVE_WIRE_ORIGINS" <>
        ": " <> Diagnostics.render(origins, pretty: true, limit: :infinity)
    )

    for side <- [pair.run, pair.twin] do
      wire = side |> Origins.build() |> TransportReferences.build() |> Wire.build()

      counts =
        for event <- wire,
            is_port(event.pid) do
          claimed? = side.resource == Withheld and MapSet.member?(readback.claimed, event.index)
          sql = if event.wire_sql, do: :crypto.hash(:sha256, event.wire_sql)
          {event.role, claimed?, sql}
        end
        |> Enum.frequencies()

      IO.puts(
        "U2_NATIVE_TRANSPORT_OWNERSHIP" <>
          ": " <>
          Diagnostics.render(%{side: side.resource, instances: counts},
            pretty: true,
            limit: :infinity
          )
      )

      u2_command_ownership(
        side,
        if(side.resource == Withheld, do: readback.claimed, else: MapSet.new())
      )
    end

    assert outside == [],
           "OPEN claimed transport outside its native interval: #{Diagnostics.render(outside)}"

    assert_green(pair)
  end

  @tag :allocation_checkpoint
  test "allocation eligibility is fixed by the declared path and fault" do
    for row <- Scenarios.rows() do
      expected = row.branch in [:execute, :recovery_absent]
      assert Registry.allocation_checkpoint?(row) == expected
    end

    assert Enum.count(Scenarios.rows(), &Registry.allocation_checkpoint?/1) == 15
  end

  @tag :allocation_checkpoint
  test "the allocation checkpoint closes every native instruction and rejects caller faults",
       context do
    row = row!(:external_issue, :execute)
    values = Values.set()[:va]
    pair = observe(context, row, values)
    history = ConnectionHistory.build(pair.twin)
    assert history.errors == []
    side = Map.put(pair.twin, :connection_history, history)
    proof = Allocation.check(side, Origins.build(side))
    errors = Diagnostics.safe(proof.errors)
    assert errors == []
    assert MapSet.size(proof.claimed) == 66
    assert proof.lease.protocol.postgres == :idle
    assert proof.lease.caller == pair.twin.run.snapshot.root

    path = "test/support/exit_boundary/scenarios.ex"
    original = File.read!(path)

    invocation =
      "    if input.resource == Returned and input.allocation_checkpoint?, do: allocation_checkpoint()\n"

    assert length(:binary.matches(original, invocation)) == 1
    skipped = String.replace(original, invocation, "", global: false)

    doubled =
      String.replace(
        original,
        invocation,
        "    if input.resource == Returned and input.allocation_checkpoint? do\n      allocation_checkpoint()\n      allocation_checkpoint()\n    end\n",
        global: false
      )

    misplaced =
      skipped
      |> String.replace(
        "    result =\n      Pair.run_call(",
        invocation <> "\n    result =\n      Pair.run_call(",
        global: false
      )

    wrong_pool =
      String.replace(
        original,
        "def allocation_checkpoint, do: Repo.checkout(fn -> :allocation_checkpoint end)",
        "def allocation_checkpoint, do: DBConnection.run(Faults.peer(), fn _ -> :allocation_checkpoint end)",
        global: false
      )

    for {name, source, rule} <- [
          {:skipped, skipped, :checkpoint_count},
          {:doubled, doubled, :checkpoint_count},
          {:misplaced, misplaced, :checkpoint_placement},
          {:wrong_pool, wrong_pool, :checkpoint_protocol}
        ] do
      Compiled.with_source(source, path, fn ->
        captured = observe(context, row, values)
        history = ConnectionHistory.build(captured.twin)
        assert history.errors == []
        side = Map.put(captured.twin, :connection_history, history)
        indexed = Origins.build(side)
        rejected = Allocation.check(side, indexed)
        assert Enum.map(rejected.errors, & &1.rule) == [rule]
        assert rejected.claimed == MapSet.new()

        if name == :wrong_pool do
          main = captured.twin.historical.repo_metadata.pid

          assert Enum.any?(indexed.events, fn
                   %{
                     event:
                       {_, :return_from, {DBConnection.Holder, :checkout, 3},
                        {:ok, {:pool_ref, pool, _, _, _, _}, _, _, _}},
                     stack: stack
                   } ->
                     {Scenarios, :allocation_checkpoint, 0} in stack and pool != main

                   _ ->
                     false
                 end)
        end

        IO.puts(
          "ALLOCATION_NATIVE_NEGATIVE" <>
            ": " <> Diagnostics.render(%{fault: name, rejected_by: rule}, pretty: true)
        )
      end)

      assert File.read!(path) === original
    end

    restored = observe(context, row, values)
    history = ConnectionHistory.build(restored.twin)
    assert history.errors == []
    side = Map.put(restored.twin, :connection_history, history)

    errors =
      Allocation.check(side, Origins.build(side)).errors
      |> Diagnostics.safe()

    assert errors == []
    assert_green(restored)
  end

  @tag connection_streams: :driver
  test "OPEN reference eligibility is fixed before a real action can omit OPEN", context do
    path = "lib/ash_onetime/delivery.ex"
    original = File.read!(path)
    site = "        with :complete <- Store.committed_completion(target, claim),\n"
    assert length(:binary.matches(original, site)) == 1

    mutated =
      String.replace(
        original,
        site,
        "        with :complete <- if(rem(byte_size(envelope) - 65, 2) == 1, do: :complete, else: Store.committed_completion(target, claim)),\n",
        global: false
      )

    rows =
      Enum.filter(Scenarios.rows(), fn row ->
        Registry.allocation_checkpoint?(row) or row.branch == :replay or
          row.fault == :codec_decode
      end)

    Compiled.with_source(mutated, path, fn ->
      for row <- rows do
        pair = observe(context, row, Values.set()[:vd])
        assert Search.hits(pair.run) == []
        assert_open_reference_plan(pair)
      end
    end)

    assert File.read!(path) === original
  end

  defp assert_open_reference_plan(pair) do
    invocations =
      if pair.run.prior,
        do: [{pair.run.prior, pair.twin.prior}, {pair.run, pair.twin}],
        else: [{pair.run, pair.twin}]

    for {run, twin} <- invocations do
      assert run.allocation_checkpoint? == Registry.allocation_checkpoint?(run.row)
      assert twin.allocation_checkpoint? == run.allocation_checkpoint?

      refute Enum.any?(
               run.run.events,
               &match?(%{event: {_, :call, {AshOnetime.Store, :committed_completion, _}}}, &1)
             )

      if run.allocation_checkpoint? do
        assert Map.has_key?(run, :readback_reference),
               "a prescribed OPEN reference cannot disappear with the observed OPEN"

        assert run.readback_reference.run.result == :complete
        assert run.readback_reference.historical.repo == run.historical.repo
      else
        refute Map.has_key?(run, :readback_reference)
      end

      refute Map.has_key?(twin, :readback_reference)
    end
  end

  @tag :allocation_checkpoint
  test "value-conditioned OPEN existence cannot choose its own allocation obligation", context do
    path = "lib/ash_onetime/delivery.ex"
    original = File.read!(path)
    site = "        with :complete <- Store.committed_completion(target, claim),\n"
    assert length(:binary.matches(original, site)) == 1

    mutated =
      String.replace(
        original,
        site,
        "        with :complete <- if(rem(byte_size(envelope) - 65, 2) == 1, do: :complete, else: Store.committed_completion(target, claim)),\n",
        global: false
      )

    values = Values.set()
    row = row!(:issue, :execute)

    Compiled.with_source(mutated, path, fn ->
      neutral = observe(context, row, values[:va])
      assert_green(neutral)
      active = observe(context, row, values[:vd])
      assert Search.hits(active.run) == []

      refute Enum.any?(
               active.run.run.events,
               &match?(%{event: {_, :call, {AshOnetime.Store, :committed_completion, _}}}, &1)
             )

      first = Comparator.compare(active).errors |> List.first()

      owned? =
        match?(
          %{rule: :permitted_call_order, twin: {AshOnetime.Store, :committed_completion, 2}},
          first
        )

      assert owned?, Diagnostics.render(Diagnostics.safe(first))
      assert Registry.allocation_checkpoint?(active.row)

      assert Enum.count(
               active.twin.run.events,
               &match?(%{event: {_, :call, {Scenarios, :allocation_checkpoint, []}}}, &1)
             ) == 1

      IO.puts("ALLOCATION_NATIVE_OPEN_EXISTENCE_REJECTED")
    end)

    assert File.read!(path) === original
    assert_green(observe(context, row, values[:vd]))
  end

  @tag :allocation_checkpoint
  test "value-conditioned OPEN routing is rejected with its real alternate backend", context do
    alternate =
      StoreCase.start_unboxed_repo!(
        prepare: :unnamed,
        idle_interval: 3_600_000,
        pool_size: 2
      )

    SQL.query!(alternate, "SELECT 1", [])
    alternate_pool = Ecto.Repo.Registry.lookup(alternate).pid
    key = {__MODULE__, :allocation_backend_control}
    assert :persistent_term.get(key, :undefined) == :undefined
    :persistent_term.put(key, alternate)
    path = "lib/ash_onetime/delivery.ex"
    original = File.read!(path)
    site = "        with :complete <- Store.committed_completion(target, claim),\n"

    mutated =
      String.replace(
        original,
        site,
        "        target = if rem(byte_size(envelope) - 65, 2) == 1, do: %{target | dynamic_repo: :persistent_term.get({AshOnetime.Delivery.ComparatorControlsTest, :allocation_backend_control})}, else: target\n" <>
          site,
        global: false
      )

    assert length(:binary.matches(original, site)) == 1
    values = Values.set()
    row = row!(:issue, :execute)

    try do
      Compiled.with_source(mutated, path, fn ->
        assert_green(observe(context, row, values[:va]))
        active = observe(context, row, values[:vd])
        assert Search.hits(active.run) == []

        assert Enum.any?(active.run.run.events, fn
                 %{
                   event:
                     {_, :return_from, {DBConnection.Holder, :checkout, 3},
                      {:ok, {:pool_ref, ^alternate_pool, _, _, _, _}, _, _, _}},
                   stack: stack
                 } ->
                   {AshOnetime.Store, :committed_completion, 2} in stack

                 _ ->
                   false
               end)

        first = Comparator.compare(active).errors |> List.first()

        owned? =
          match?(%{at: %{mfa: {:persistent_term, :get, 1}}, rule: :permitted_call_order}, first)

        assert owned?, Diagnostics.render(Diagnostics.safe(first))
        IO.puts("ALLOCATION_NATIVE_BACKEND_ROUTING_REJECTED")
      end)
    after
      :persistent_term.erase(key)
    end

    assert File.read!(path) === original
    assert :persistent_term.get(key, :undefined) == :undefined
    assert_green(observe(context, row, values[:vd]))
  end

  @tag :u_cross_lease_observation
  test "U observation: physical identity remains bound across independent native leases",
       context do
    %{positive: positive, negative: negative} = cross_lease_captures(context)
    assert Allocation.captured_pairs(positive).errors == []
    rejected = Allocation.captured_pairs(negative)

    IO.puts(
      "U_CROSS_LEASE_NATIVE_CONFLICT" <> ": " <> Diagnostics.render(rejected.errors, pretty: true)
    )

    assert rejected.errors != [], "U_CROSS_LEASE_IDENTITY_WITNESS"

    assert Enum.all?(
             rejected.errors,
             &match?({:o2, :not_bijective, {:allocation, _, _, _, _, _}}, &1)
           )
  end

  @tag :u_cross_lease_selectivity
  test "the cross-lease map alone rejects the same native occurrence pairs", context do
    %{positive: positive, negative: negative} = cross_lease_captures(context)
    expected = Allocation.captured_pairs(negative).errors
    assert expected != []

    for rule <- ComparatorMutants.rules() ++ [:cross_lease_map] do
      {accepted, rejected} =
        ComparatorMutants.with_mutant(rule, fn ->
          {Allocation.captured_pairs(positive), Allocation.captured_pairs(negative)}
        end)

      assert accepted.errors == []

      if rule == :cross_lease_map do
        assert rejected.errors == []
      else
        assert rejected.errors === expected
      end

      IO.puts(
        "U_CROSS_LEASE_SAME_CAPTURE_SELECTIVITY" <>
          ": " <>
          Diagnostics.render(%{mutant: rule, remaining: length(rejected.errors)}, pretty: true)
      )
    end

    assert Allocation.captured_pairs(negative).errors === expected
    assert Allocation.captured_pairs(positive).errors == []
  end

  @tag :u_allocation_happens_before
  test "U observation: overlapping borrowers require causal checkin order", context do
    first = borrower_capture(context, :child_first)
    second = borrower_capture(context, :child_first)
    opposite = borrower_capture(context, :parent_first)

    compare = fn run, twin ->
      left = ConnectionHistory.build(run)
      right = ConnectionHistory.build(twin)
      assert left.errors == [] and right.errors == []

      Allocation.pair(
        %{forward: %{}, reverse: %{}, errors: []},
        run,
        twin,
        Origins.build(run),
        Origins.build(twin)
      )
    end

    accepted = compare.(first, second)
    assert accepted.errors == [] and accepted.pairing.errors == []
    rejected = compare.(first, opposite)
    assert rejected.pairing.errors == []
    {left, right} = rejected.leases

    for leases <- [left, right] do
      assert length(leases) == 2
      assert Enum.all?(leases, &(is_integer(&1.checkin) and is_integer(&1.giveaway)))
    end

    IO.puts(
      "U_ALLOCATION_NATIVE_OPPOSITE_CHECKIN_ORDER" <>
        ": " <>
        Diagnostics.render(Enum.map(rejected.errors, &Map.take(&1, [:rule, :run, :twin])),
          pretty: true
        )
    )

    witnessed? =
      Enum.any?(rejected.errors, &(&1.rule == :allocation_happens_before)) and
        Enum.any?(rejected.errors, &(&1.rule == :allocation_borrower_join))

    assert witnessed?, "U_ALLOCATION_HAPPENS_BEFORE_WITNESS"
  end

  @tag :u5
  test "U5: entry, transaction refusal, and direct claim are closed traces", context do
    rows = [
      row!(:issue, :execute),
      row!(:mint, :execute),
      row!(:issue, :transaction, :commit),
      row!(:issue, :transaction, :rollback),
      row!(:mint, :direct)
    ]

    for row <- rows do
      pair = observe(context, row, Values.set()[:va])
      indexed = Origins.build(pair.run)
      matched = PermittedTrace.match(pair.run, indexed)
      assert matched.errors == []
      assert Enum.map(matched.segments, &elem(&1, 0)) == Registry.trace(row)
      assert_green(pair)
    end
  end

  @tag :u6
  test "U6 and U4: Bind and DataRow columns have protocol type OIDs", context do
    pair = observe(context, row!(:external_issue, :execute), Values.set()[:va])

    for side <- [pair.run, pair.twin] do
      wire = side |> Origins.build() |> TransportReferences.build() |> Wire.build()
      binds = Enum.flat_map(wire, &wire_terms(&1.event, :bind_column))
      rows = Enum.flat_map(wire, &wire_terms(&1.event, :data_column))
      assert binds != [] and rows != []

      for event <- wire, wire_terms(event.event, :bind) != [] do
        assert is_binary(event.wire_sql), "each native Bind needs its protocol statement"
      end

      assert Enum.all?(binds, fn {:bind_column, _, oid, format, _} ->
               is_integer(oid) and format in [0, 1]
             end)

      assert Enum.all?(rows, fn {:data_column, sql, {{:wire_statement, phase, ordinal}, _}, _, _,
                                 {:table_oid, oid}, _, type, format, _} ->
               is_binary(sql) and phase in [:shared, :committed_read] and is_integer(ordinal) and
                 is_integer(oid) and is_integer(type) and
                 format in [0, 1]
             end)

      clocks =
        for {:data_column, _, _, _, field, _, _, type, _, _} <- rows,
            field in ["admitted_at", "retain_until", "inserted_at", "response_retain_until"],
            do: type

      assert clocks != [] and Enum.all?(clocks, &(&1 == 1184))

      database = DatabaseOrigins.build(wire, side)

      date_sources =
        for {:data_column, sql, _, _, name, _, _, 1082, _, _} <- rows,
            sql in database.statements.date.statements,
            do: {sql, name}

      assert date_sources != [], "the declared date SELECT must have a native wire origin"

      for {sql, name} <- date_sources,
          do: assert(database.statements.date.columns[sql] == [name])

      assert database.errors == []
      tokens = for {_, {:database_expression, token}} <- database.slots, do: token

      required = [
        :payload_date_argument,
        :completion_date_argument,
        :database_date_return,
        :database_date_bind_copy,
        :completion_date_frame,
        :completion_date_environment
      ]

      for token <- required,
          do: assert(token in tokens, "missing native clock-copy witness: #{token}")

      relations =
        for {table, changes} <- side.delta,
            row <- changes.added ++ changes.removed,
            table == database.statements.payload.table or table in database.payload_children do
          assert {:ok, relation, _row} =
                   DatabaseOrigins.payload_snapshot(
                     table,
                     row,
                     database
                   )

          relation
        end

      assert database.statements.payload.table in relations
      assert {:database_relation, :payload_child} in relations

      IO.puts(
        "U4_NATIVE_CLOCK_COPY_COVERAGE" <>
          ": " <>
          Diagnostics.render(
            %{
              side: side.resource,
              copies: Enum.frequencies(tokens),
              relations: Enum.uniq(relations)
            },
            pretty: true
          )
      )
    end

    assert_green(pair)

    replay = observe(context, row!(:external_issue, :replay), Values.set()[:va])

    for side <- [replay.run, replay.twin] do
      prior_wire = side.prior |> Origins.build() |> TransportReferences.build() |> Wire.build()
      prior = DatabaseOrigins.build(prior_wire, side.prior)
      wire = side |> Origins.build() |> TransportReferences.build() |> Wire.build()

      database =
        DatabaseOrigins.build(
          wire,
          Map.put(side, :prior_database, prior)
        )

      assert database.errors == []
      tokens = for {_, {:database_expression, token}} <- database.slots, do: token

      for token <- [:joined_payload_date_column, :joined_payload_date_result],
          do: assert(token in tokens, "missing native replay clock-copy witness: #{token}")

      IO.puts(
        "U4_NATIVE_REPLAY_CLOCK_COPY_COVERAGE" <>
          ": " <>
          Diagnostics.render(%{side: side.resource, copies: Enum.frequencies(tokens)},
            pretty: true
          )
      )
    end

    assert_green(replay)
  end

  @tag :u4
  test "U4: outcome clocks originate in the granted attempt and survive the joined recovery snapshot",
       context do
    pair = observe(context, row!(:external_issue, :recovered), Values.set()[:va])

    for side <- [pair.run, pair.twin] do
      prior_wire = side.prior |> Origins.build() |> TransportReferences.build() |> Wire.build()
      prior = DatabaseOrigins.build(prior_wire, side.prior)
      assert prior.errors == []
      assert map_size(prior.outcome_writes) == 1
      assert map_size(prior.outcomes) == 1
      tokens = for {_, {:database_expression, token}} <- prior.slots, do: token
      assert :outcome_clock in tokens
      assert :outcome_clock_copy in tokens
      indexed = Origins.build(side.prior)
      clocks = ClockExpressions.build(indexed, side.prior)
      assert clocks.errors == []
      clock_tokens = for {_, {_, token}} <- clocks.slots, do: token
      assert :outcome_start_copy in clock_tokens
      assert :outcome_start_closure in clock_tokens

      for row <- side.prior.delta["ash_onetime_effect_outcomes"].added do
        assert DatabaseOrigins.outcome_snapshot(row, prior) ==
                 row["recorded_at"]

        assert row["attempt"] == 1
      end

      wire = side |> Origins.build() |> TransportReferences.build() |> Wire.build()

      database =
        DatabaseOrigins.build(
          wire,
          Map.put(side, :prior_database, prior)
        )

      assert database.errors == []
      assert database.outcomes == prior.outcomes

      assert Enum.any?(database.latest, fn {_, claim} ->
               claim["effect_attempt"] == 2 and claim["state"] == "complete"
             end)
    end

    assert_green(pair)
  end

  @tag :u6
  test "U6: prepared query logging parameters belong to their actual statement", context do
    pair = observe(context, row!(:rotate, :execute), Values.set()[:va])

    for side <- [pair.run, pair.twin] do
      history = ConnectionHistory.build(side)
      assert history.errors == []
      side = Map.put(side, :connection_history, history)
      indexed = Origins.build(side)
      events = indexed.events
      contexts = DatabaseOrigins.sql_contexts(events)
      names = QueryOrigins.build(indexed, side)

      prepared_names =
        for %{event: {_, :call, {Postgrex, :prepare_execute, [_, name, statement, _, _]}}} <-
              events do
          assert {:ok, expected} =
                   QueryOrigins.expected_name(names, statement)

          assert name === expected
          name
        end

      assert prepared_names != [], "the native scalar prepared-name slot must execute"

      assert Enum.any?(
               events,
               &(&1.mfa in [{Postgrex, :prepare_execute, 5}, {Postgrex, :execute, 4}])
             )

      witnesses =
        for %{event: {_, :call, {DBConnection, :meter, [opts]}}, index: index} <- events,
            logger = Keyword.get(opts, :log),
            is_function(logger) do
          # The same native callback is later handed its own LogEntry. Its SQL
          # independently identifies the earlier closure's parameter types.
          entry =
            Enum.find_value(events, fn
              %{
                event:
                  {_, :call, {DBConnection, :log, [^logger, %DBConnection.LogEntry{} = entry]}},
                index: later
              }
              when later > index ->
                entry

              _ ->
                nil
            end)

          assert entry != nil, "each native query logger needs its actual LogEntry"

          if entry.call in [:prepare_execute, :execute] do
            statement = to_string(entry.query)
            assert contexts[index] === statement
            {:query, index}
          else
            {:transaction, index}
          end
        end

      assert Enum.any?(witnesses, &match?({:query, _}, &1)),
             "the native prepared-query logger path must execute"
    end

    assert_green(pair)
  end

  @tag :u7
  test "U7: an empty long value passes delivery, crypto, and rule 3", context do
    pair = observe(context, row!(:issue, :execute), Values.set()[:vf])
    assert {:ok, _, %AshOnetime.Delivery{values: %{long: <<>>}}} = pair.run.run.result
    assert Search.hits(pair.run) == []
    assert_green(pair)
  end

  @tag :u10
  test "U10: removing pure operations preserves every rule 3 exit", context do
    row = row!(:external_issue, :execute)
    values = Values.set()[:va]
    pair = observe(Map.put(context, :compare_pure?, true), row, values)

    for name <- [:run, :twin] do
      captured = pair[name].run
      assert exit_observation(captured.pattern_probe) == exit_observation(captured.events)
      assert length(captured.pattern_probe) > length(captured.events)

      IO.puts(
        "U10_SAME_INVOCATION_EXIT_EQUALITY" <>
          ": " <>
          Diagnostics.render(
            %{side: name, full: length(captured.pattern_probe), reduced: length(captured.events)},
            pretty: true
          )
      )
    end

    assert_green(pair)
  end

  @tag :u13
  @tag :u14
  test "U13 and U14: compiled fields, hooks, context copies, and anchored frames have witnesses",
       context do
    declarations = Declarations.pair(Withheld, Returned)
    assert declarations.errors == [], "U13: undeclared or dead compiled declaration slots"

    rows =
      Enum.filter(
        Scenarios.rows(),
        &(&1.branch == :consumer_failure and &1.fault == :after_raise)
      ) ++
        [row!(:issue, :transaction, :rollback), row!(:mint, :transaction, :rollback)]

    context = with_references(context)

    pairs =
      for row <- rows do
        pair = Scenarios.observe(row, Values.set()[:va], context)
        assert_green(pair)

        IO.puts(
          "U14_ANCHORS" <>
            ": " <>
            Diagnostics.render(
              %{
                action: row.action,
                branch: row.branch,
                run:
                  Enum.map(
                    Enum.uniq(Completeness.stacks(pair.run.run.events)),
                    &Enum.map(&1, fn {m, f, a, location} ->
                      {m, f, if(is_list(a), do: length(a), else: a), location}
                    end)
                  ),
                twin:
                  Enum.map(
                    Enum.uniq(Completeness.stacks(pair.twin.run.events)),
                    &Enum.map(&1, fn {m, f, a, location} ->
                      {m, f, if(is_list(a), do: length(a), else: a), location}
                    end)
                  )
              },
              pretty: true,
              limit: :infinity
            )
        )

        pair
      end

    production_raises =
      PathFrameWitnesses.capture(context, Values.set()[:va])

    assert Completeness.check(pairs ++ production_raises) == %{
             declarations: [],
             hooks: MapSet.new(),
             copies: MapSet.new(),
             frames: MapSet.new()
           },
           "U13: a hook, context copy, or path frame has no differing captured witness"

    assert ContextCopies.slots() == [
             {AshOnetime.GenericAction, :run, 3},
             {AshOnetime.GenericAction, :run_original, 3}
           ]

    assert Enum.all?(pairs, fn pair ->
             Enum.all?(pair.run.hooks, fn {slot, hook} ->
               hook.identity != pair.twin.hooks[slot].identity
             end)
           end)
  end

  @tag :u_consumer_observation
  test "U observation: Consumer arguments remain unprojected", context do
    twin = consumer_capture(0)
    equal = consumer_capture(0)
    changed = consumer_capture(1)
    row = row!(:issue, :execute)
    twin_side = observation_side(context, twin, %{}, row)
    equal_side = observation_side(context, equal, %{}, row)
    run_side = observation_side(context, changed, %{}, row)

    assert compare_observation(equal_side, twin_side, row).errors == []
    comparison = compare_observation(run_side, twin_side, row)

    first = List.first(comparison.errors)

    IO.puts(
      "U_CONSUMER_NATIVE_FIRST_DIVERGENCE" <> ": " <> Diagnostics.render(first, pretty: true)
    )

    assert match?(
             %{
               at: %{mfa: {AshOnetime.Test.ExitBoundary.Consumer, :after_action, 2}},
               path: [:event, 2, 2, 0, :context, :private, :ash_onetime_delivery, :n],
               rule: :o5,
               run: 1,
               twin: 0
             },
             first
           ),
           "U_CONSUMER_ARGUMENT_WITNESS"
  end

  @tag :u_store_observation
  test "U observation: real snapshots retain every row and column", context do
    Scenarios.reset!(context.prefix)
    id = Ecto.UUID.generate()
    table = "ash_onetime_boundary_records"
    row = row!(:issue, :execute)

    try do
      before = Persisted.snapshot(context.prefix, context.repo)

      SQL.query!(
        context.repo,
        ~s[INSERT INTO "#{context.prefix}".ash_onetime_boundary_records (id, amount) VALUES ($1::uuid, 1)],
        [Ecto.UUID.dump!(id)]
      )

      first = Persisted.snapshot(context.prefix, context.repo)
      equal = Persisted.snapshot(context.prefix, context.repo)

      SQL.query!(
        context.repo,
        ~s[UPDATE "#{context.prefix}".ash_onetime_boundary_records SET amount = amount + 1 WHERE id = $1::uuid],
        [Ecto.UUID.dump!(id)]
      )

      changed = Persisted.snapshot(context.prefix, context.repo)
      run = consumer_capture(0)
      twin = consumer_capture(0)
      delta = &Persisted.delta(before, &1)
      twin_side = observation_side(context, twin, delta.(first), row)
      equal_side = observation_side(context, run, delta.(equal), row)
      run_side = observation_side(context, run, delta.(changed), row)

      assert compare_observation(equal_side, twin_side, row).errors == []
      comparison = compare_observation(run_side, twin_side, row)
      difference = List.first(comparison.errors)

      IO.puts(
        "U_STORE_NATIVE_FIRST_DIVERGENCE" <> ": " <> Diagnostics.render(difference, pretty: true)
      )

      assert match?(
               %{
                 at: :store,
                 rule: :o5,
                 path: [:store, ^table, :added, 0, "amount"],
                 run: 2,
                 twin: 1
               },
               difference
             ),
             "U_STORE_SNAPSHOT_WITNESS"
    after
      Scenarios.reset!(context.prefix)
    end
  end

  @tag :u_store_acl_observation
  test "U observation: native ACL arrays retain every element and change exactly", context do
    table = "snapshot_acl_observation"
    relation = ~s["#{context.prefix}"."#{table}"]
    row = row!(:issue, :execute)
    SQL.query!(context.repo, "CREATE TABLE #{relation} (id integer, permissions aclitem[])", [])

    try do
      before = Persisted.snapshot(context.prefix, context.repo)

      SQL.query!(
        context.repo,
        "INSERT INTO #{relation} SELECT 1, ARRAY[NULL::aclitem] || pg_catalog.acldefault('r', current_user::regrole)",
        []
      )

      first = Persisted.snapshot(context.prefix, context.repo)
      equal = Persisted.snapshot(context.prefix, context.repo)

      [[expected]] =
        SQL.query!(context.repo, "SELECT permissions::text[] FROM #{relation}", []).rows

      assert [%{"id" => 1, "permissions" => ^expected}] = first[table]
      assert [nil, _permission] = expected

      SQL.query!(
        context.repo,
        "UPDATE #{relation} SET permissions = ARRAY[NULL::aclitem, pg_catalog.makeaclitem(current_user::regrole, current_user::regrole, 'SELECT', true)]",
        []
      )

      changed = Persisted.snapshot(context.prefix, context.repo)
      run = consumer_capture(0)
      twin = consumer_capture(0)
      delta = &Persisted.delta(before, &1)
      twin_side = observation_side(context, twin, delta.(first), row)
      equal_side = observation_side(context, run, delta.(equal), row)
      run_side = observation_side(context, run, delta.(changed), row)
      assert compare_observation(equal_side, twin_side, row).errors == []
      difference = compare_observation(run_side, twin_side, row).errors |> List.first()

      assert match?(
               %{
                 at: :store,
                 rule: :o5,
                 path: [:store, ^table, :added, 0, "permissions", 1]
               },
               difference
             ),
             "U_STORE_ACL_SNAPSHOT_WITNESS"
    after
      SQL.query!(context.repo, "DROP TABLE #{relation}", [])
    end
  end

  @tag :r17
  @tag :u_error_observation
  test "U observation: captured error details remain exact", context do
    row = row!(:issue, :execute)
    twin = observation_side(context, error_capture(0), %{}, row)
    equal = observation_side(context, error_capture(0), %{}, row)
    changed = observation_side(context, error_capture(1), %{}, row)

    assert compare_observation(equal, twin, row).errors == []
    first = compare_observation(changed, twin, row).errors |> List.first()
    IO.puts("U_ERROR_NATIVE_FIRST_DIVERGENCE" <> ": " <> Diagnostics.render(first, pretty: true))

    assert match?(
             %{
               at: %{mfa: {AshOnetime.Error, :new, 3}},
               path: [:event, 3, :details, :n],
               rule: :o5,
               run: 1,
               twin: 0
             },
             first
           ),
           "U_ERROR_DETAILS_WITNESS"
  end

  defp error_capture(n) do
    run =
      ExitBoundary.observe(
        fn -> :ok end,
        fn _ ->
          AshOnetime.Error.new(:store_failure, "authoritative admission store failed", %{n: n})
        end,
        %{host: [], callbacks: []}
      )

    returns =
      Enum.filter(run.events, fn event ->
        match?(%{event: {_, :return_from, {AshOnetime.Error, :new, 3}, _}}, event)
      end)

    assert [%{event: {_, :return_from, _, error}}] = returns
    assert error === run.result
    %{run | events: returns}
  end

  defp compare_observation(run, twin, row),
    do: Comparator.compare(%{run: run, twin: twin, row: row}, readback_reference?: true)

  # Capture the actual callback invocation and its native descendants. Taking
  # this closed callback interval excludes its caller's input; no event or term
  # inside the interval is edited to manufacture either side of the self-test.
  defp consumer_capture(n) do
    consumer = AshOnetime.Test.ExitBoundary.Consumer
    subject = %{context: %{private: %{ash_onetime_delivery: %{ref: "callback-ref", n: n}}}}

    run =
      ExitBoundary.observe(
        fn -> subject end,
        fn input -> consumer.after_action(input, :ok) end,
        %{host: [], callbacks: [consumer, AshOnetime.Test.ExitBoundary.Recorder]}
      )

    {_prefix, tail} =
      Enum.split_while(run.events, fn event ->
        not match?(%{event: {_, :call, {^consumer, :after_action, _}}}, event)
      end)

    stop =
      Enum.find_index(tail, fn event ->
        match?(%{event: {_, :return_from, {^consumer, :after_action, 2}, _}}, event)
      end)

    assert is_integer(stop)
    %{run | events: Enum.take(tail, stop + 1)}
  end

  defp cross_lease_captures(context) do
    row = row!(:issue, :execute)

    captures =
      for ordinal <- 1..8 do
        # Exercise the existing pool without changing its size. Real checkins rotate
        # its ready members; the subsequent snapshot grounds that capture's clocks.
        rotate_pool(rem(ordinal, context.pool_size))

        historical = Historical.capture(context.prefix)

        run =
          ExitBoundary.observe(
            fn ->
              Repo.put_dynamic_repo(context.repo)
              :allocation_observation
            end,
            fn _ -> Scenarios.allocation_checkpoint() end,
            %{host: [], callbacks: []}
          )

        side = observation_side(context, run, %{}, row, historical)
        [lease] = Allocation.leases(side, Origins.build(side))
        assert is_integer(lease.checkin) and is_integer(lease.giveaway)
        assert run.result == :allocation_checkpoint

        assert Enum.any?(
                 run.events,
                 &match?(%{event: {_, :return_from, {DBConnection.Holder, :checkin, 1}, :ok}}, &1)
               )

        assert Enum.any?(
                 run.events,
                 &match?(%{event: {_, :return_from, {:ets, :give_away, 3}, true}}, &1)
               )

        {lease.holder, side}
      end

    groups = captures |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> Map.values()
    a = Enum.find(groups, &(length(&1) >= 3))
    b = Enum.find(groups, &(&1 != a and length(&1) >= 2))

    assert a != nil and b != nil,
           "native checkouts must witness repeated and distinct pool members"

    [a1, a2, a3 | _] = a
    [b1, b2 | _] = b
    positive = [{a1, b1}, {a2, b2}]
    negative = [{a1, b1}, {a2, a3}]

    for {run, twin} <- positive ++ negative do
      # These comparisons use each complete, untouched native observation. They
      # establish that the shared-map failure is not an individual lease failure.
      errors =
        compare_observation(run, twin, row).errors
        |> Diagnostics.safe()

      assert errors == []
      assert Allocation.captured_pairs([{run, twin}]).errors == []
    end

    roots = for {run, twin} <- negative, side <- [run, twin], do: side.run.snapshot.root
    assert length(Enum.uniq(roots)) == 4
    %{positive: positive, negative: negative}
  end

  defp rotate_pool(count) do
    for _ <- List.duplicate(:rotate, count), do: Repo.checkout(fn -> :fixture_rotation end)
  end

  defp borrower_capture(context, order) do
    historical = Historical.capture(context.prefix)
    repo = context.repo

    run =
      ExitBoundary.observe(
        fn ->
          Repo.put_dynamic_repo(repo)
          :allocation_observation
        end,
        fn _ -> borrower_run(repo, order) end,
        %{host: [], callbacks: []}
      )

    assert run.result == :allocation_order
    observation_side(context, run, %{}, row!(:issue, :execute), historical)
  end

  defp borrower_run(repo, order) do
    case Repo.checkout(fn -> borrow_parent(repo, order) end) do
      {:pending, child} ->
        send(child, {:release, self()})
        receive do: ({:checked_in, ^child} -> :allocation_order)

      :joined ->
        :allocation_order
    end
  end

  defp borrow_parent(repo, order) do
    parent = self()
    child = spawn(fn -> borrow_child(repo, parent) end)
    receive do: ({:borrowed, ^child} -> :ok)

    if order == :child_first do
      send(child, {:release, parent})
      receive do: ({:checked_in, ^child} -> :joined)
    else
      {:pending, child}
    end
  end

  defp borrow_child(repo, parent) do
    Repo.put_dynamic_repo(repo)

    Repo.checkout(fn ->
      send(parent, {:borrowed, self()})
      receive do: ({:release, ^parent} -> :ok)
    end)

    send(parent, {:checked_in, self()})
  end

  defp observation_side(context, run, delta, row, historical \\ nil) do
    %{
      run: run,
      delta: delta,
      row: row,
      prefix: context.prefix,
      resource: Withheld,
      bound: %{},
      hooks: %{},
      hook_frames: %{},
      historical: historical || Historical.capture(context.prefix),
      operation_reference: References.operation(Withheld, row.action)
    }
  end

  defp assert_green(pair) do
    result = Comparator.compare(pair)

    if first = List.first(result.errors) do
      IO.puts(
        "C_NATIVE_FIRST_DIVERGENCE" <>
          ": " <>
          Diagnostics.render(
            %{
              path: {pair.row.action, pair.row.branch, pair.row.fault},
              first: Diagnostics.safe(first)
            },
            pretty: true,
            limit: :infinity
          )
      )
    end

    locations = Enum.map(result.errors, &{&1.at, &1.rule, &1.path})
    assert locations == [], "comparator differences: #{Diagnostics.render(locations)}"
    :ok
  end

  defp next_second(side) do
    reads = ttl_reads(side)
    if reads == [], do: raise("C-tick did not capture a TTL read")
    target = (DateTime.to_unix(List.last(reads)) + 1) * 1_000
    now = System.system_time(:millisecond)

    IO.puts(
      "C_TICK_BOUNDARY" <>
        ": " <> Diagnostics.render(%{target: target, after_side: now}, pretty: true)
    )

    Process.sleep(max(target - now, 0))
  end

  defp ttl_reads(side) do
    for %{event: {_, :return_from, {DateTime, :utc_now, _}, now}, stack: stack} <- side.run.events,
        {AshOnetime.Cache, :ttl_seconds, 1} in stack,
        do: now
  end

  defp anchors(side) do
    indexed = Origins.build(side)

    for {holder, clock} <- side.historical.pool_clocks,
        Map.has_key?(indexed.roles, holder),
        into: %{},
        do: {{indexed.roles[holder], :checkin}, clock}
  end

  defp role_order(side), do: Origins.build(side).events |> Enum.map(& &1.role)

  defp assert_pool_monitor_origins(pair) do
    run = Origins.build(pair.run)
    twin = Origins.build(pair.twin)
    comparison = Comparator.compare(pair)

    sources =
      for {key = {_role, _phase, stack, {module, function, _}, _ordinal}, origin} <- run.origins,
          module == :erlang and function == :monitor,
          Enum.any?(stack, fn {m, _, _} -> m == DBConnection.Holder end),
          do: {key, origin}

    assert sources != [], "U8 did not observe the pool holder's monitor origins"

    for {key, origin} <- sources do
      {expected, pairing} =
        if proof = Map.get(comparison.readback_sources, origin.index) do
          assert proof.key == key and proof.value === origin.value,
                 "U8: readback proof must identify the same native monitor occurrence"

          assert proof.twin != nil, "U8: readback monitor has no reference occurrence"

          assert proof.pairing === comparison.pairing,
                 "U8: OPEN and every other lease must use the same whole-observation bijection"

          {proof.twin.value, proof.pairing}
        else
          assert Map.has_key?(twin.origins, key),
                 "U8: a pool monitor role has no twin occurrence: #{Diagnostics.render(%{key: key, index: origin.index})}"

          {Map.fetch!(twin.origins, key).value, comparison.pairing}
        end

      assert Map.fetch!(pairing.forward, origin.value) == expected
      assert Map.fetch!(pairing.reverse, expected) == origin.value
    end

    values = Enum.map(sources, fn {_, source} -> source.value end)
    assert length(Enum.uniq(values)) == length(values), "U8: monitor occurrences alias"
  end

  defp exit_observation(events) do
    events
    |> Enum.filter(&String.match?(Atom.to_string(&1.class), ~r/^e[0-9]+$/))
    |> Enum.group_by(& &1.pid, &{&1.class, &1.event})
  end

  defp event_mfa({_, :call, {m, f, args}}), do: {m, f, length(args)}
  defp event_mfa({_, tag, mfa, _}) when tag in [:return_from, :exception_from], do: mfa
  defp event_mfa(_), do: nil

  # Read-only diagnosis over the same captured U2 pair. The comparator and its
  # whole-run physical identity rule remain unchanged while the design is ruled.
  defp u2_command_ownership(side, open_claimed) do
    history = ConnectionHistory.build(side)
    indexed = Origins.build(side)
    scheduled = Scheduling.build(indexed, history.native)
    indexed = %{indexed | events: scheduled.events}
    wire = indexed |> TransportReferences.build() |> Wire.build()

    leases = u2_leases(indexed, open_claimed)
    commands = u2_commands(wire, leases, indexed, open_claimed)

    checkouts =
      Enum.map(leases, fn lease ->
        %{
          lease
          | caller: indexed.roles[lease.caller],
            port: indexed.roles[lease.port],
            pool: indexed.roles[lease.pool],
            holder: indexed.roles[lease.holder]
        }
      end)

    IO.puts(
      "U2_CANONICAL_COMMAND_OWNERSHIP" <>
        ": " <>
        Diagnostics.render(
          %{
            side: side.resource,
            scheduling_errors: scheduled.errors,
            checkouts: checkouts,
            commands: commands
          },
          pretty: true,
          limit: :infinity
        )
    )
  end

  defp u2_leases(indexed, open_claimed) do
    for %{
          event:
            {caller, :return_from, {DBConnection.Holder, :checkout, 3},
             {:ok, {:pool_ref, pool, _, _, holder, _} = pool_ref, Postgrex.Protocol, _,
              %Postgrex.Protocol{sock: socket}}}
        } = source <- indexed.events do
      port = u2_socket(socket)

      stop =
        Enum.find(indexed.events, fn event ->
          event.index > source.index and
            match?(
              %{event: {^caller, :call, {DBConnection.Holder, :checkin, [^pool_ref]}}},
              event
            )
        end)

      %{
        start: source.index,
        stop: if(stop, do: stop.index),
        caller: caller,
        port: port,
        pool: pool,
        holder: holder,
        open?: MapSet.member?(open_claimed, source.index),
        stack:
          Enum.filter(source.stack, fn {module, _, _} ->
            String.starts_with?(Atom.to_string(module), "Elixir.AshOnetime.")
          end)
      }
    end
  end

  defp u2_commands(wire, leases, indexed, open_claimed) do
    for %{event: {port, :receive, {caller, {:command, payload}}}} = event <- wire,
        is_port(port) do
      u2_command(event, port, caller, payload, leases, indexed, open_claimed)
    end
  end

  defp u2_socket({:gen_tcp, port}), do: port
  defp u2_socket({:gen_tcp, port, _}), do: port
  defp u2_socket(port) when is_port(port), do: port
  defp u2_socket(_socket), do: nil

  defp u2_command(event, port, caller, payload, leases, indexed, open_claimed) do
    lease =
      leases
      |> Enum.filter(&u2_lease_owns?(&1, caller, event.index))
      |> Enum.max_by(& &1.start, fn -> nil end)

    messages =
      case payload do
        {:pg_transport, :driver_command, _, messages} -> Enum.map(messages, &elem(&1, 0))
        _ -> :undecoded
      end

    %{
      index: event.index,
      port: indexed.roles[port],
      caller: indexed.roles[caller],
      lease: if(lease, do: lease.start),
      owner_port: if(lease, do: indexed.roles[lease.port]),
      owner_matches?: lease != nil and port === lease.port,
      open?: MapSet.member?(open_claimed, event.index),
      sql: if(event.wire_sql, do: Base.encode16(:crypto.hash(:sha256, event.wire_sql))),
      messages: messages
    }
  end

  defp u2_lease_owns?(lease, caller, index),
    do:
      lease.caller == caller and lease.start < index and
        (lease.stop == nil or index < lease.stop)

  defp wire_terms(value, tag) when is_tuple(value) do
    own = if tuple_size(value) > 0 and elem(value, 0) == tag, do: [value], else: []
    own ++ Enum.flat_map(Tuple.to_list(value), &wire_terms(&1, tag))
  end

  defp wire_terms([], _tag), do: []
  defp wire_terms([head | tail], tag), do: wire_terms(head, tag) ++ wire_terms(tail, tag)

  defp wire_terms(value, tag) when is_map(value),
    do: value |> Map.to_list() |> Enum.flat_map(&wire_terms(&1, tag))

  defp wire_terms(_, _), do: []
  @tag connection_streams: :tls
  test "Connection diagnostics: every output boundary keeps captured native state private",
       context do
    Repo.put_dynamic_repo(context.repo)
    captured = Historical.capture(context.prefix)
    {_holder, connection} = Enum.find(captured.connections, fn {_, value} -> value.protocol end)
    marker = "known-native-diagnostic-sentinel"
    private = %{connection.protocol | scram: marker, connection_key: 9_876_543_219_876}
    tls = ConnectionNative.observe_tls()

    tls_states =
      for {_pid, {_name, data}} <- tls.tls_binding.states,
          do: diagnostic_sentinel(data, marker)

    {:error, postgres_error} = SQL.query(context.repo, "SELECT 1 / 0", [])
    marked_error = %{postgres_error | query: marker}

    state = %{
      captured: captured,
      protocol: private,
      tls: tls_states,
      copied_key: private.connection_key,
      postgres_error: marked_error
    }

    # This is an output-only copy of a real capture. Neither the observation nor
    # the comparison sees the marker. The unprojected printer proves the witness.
    unguarded = ExUnit.CaptureIO.capture_io(fn -> IO.puts(inspect(state, limit: :infinity)) end)
    assert String.contains?(unguarded, marker)

    assertion =
      try do
        assert state == %{state | copied_key: 0}
      rescue
        error in ExUnit.AssertionError -> error
      end

    pattern =
      try do
        raise MatchError, term: state
      rescue
        error in MatchError -> error
      end

    test = %ExUnit.Test{
      name: :"test native diagnostic witness",
      module: __MODULE__,
      tags: %{file: __ENV__.file, line: __ENV__.line}
    }

    status = %{state: state, message: state, reason: state, log: [state]}
    stack = [{__MODULE__, :diagnostic_witness, [state], [file: __ENV__.file, line: 0]}]
    assert TestFormatter.failure(test, marked_error, stack).postgres_code == "22012"

    printers = [
      setup_exit: fn ->
        IO.puts(Diagnostics.render(Diagnostics.exit_summary({pattern, stack})))
      end,
      setup_call_exit: fn ->
        IO.puts(
          Diagnostics.render(Diagnostics.exit_summary({:noproc, {GenServer, :call, [state]}}))
        )
      end,
      residual: fn -> IO.puts(Diagnostics.render(state, limit: :infinity)) end,
      residual_projection: fn -> IO.puts(inspect(Diagnostics.safe(state), limit: :infinity)) end,
      assertion_failure: fn ->
        TestFormatter.print_failure(test, [{:error, assertion, stack}])
      end,
      pattern_failure: fn ->
        TestFormatter.print_failure(test, [{:error, pattern, stack}])
      end,
      exit_failure: fn ->
        TestFormatter.print_failure(test, [{:exit, state, stack}])
      end,
      mutation_failure: fn ->
        MutationFormatter.handle_cast(
          {:test_finished, %{test | state: {:failed, [{:error, assertion, stack}]}}},
          nil
        )
      end,
      history_status: fn ->
        IO.puts(inspect(ConnectionHistory.format_status(status), limit: :infinity))
      end,
      test_formatter_status: fn ->
        IO.puts(inspect(TestFormatter.format_status(status), limit: :infinity))
      end,
      mutation_formatter_status: fn ->
        IO.puts(inspect(MutationFormatter.format_status(status), limit: :infinity))
      end
    ]

    for {site, printer} <- printers do
      output = ExUnit.CaptureIO.capture_io(printer)
      private? = String.contains?(output, marker) or String.contains?(output, "9876543219876")
      refute private?, "a native diagnostic output boundary exposed its witness"
      assert is_atom(site)
    end

    require Logger

    reports = [%{capture: state}, marked_error] ++ Enum.map(tls_states, &%{native_state: &1})

    for report <- reports do
      logged = ExUnit.CaptureLog.capture_log(fn -> Logger.error(fn -> report end) end)
      refute String.contains?(logged, marker)
      refute String.contains?(logged, "9876543219876")
    end

    assert state.protocol.scram == marker
    assert assertion.left === state
    IO.puts("NATIVE_DIAGNOSTIC_CLASS: unprojected RED; every typed output GREEN")
  end

  defp diagnostic_sentinel(value, marker) when is_binary(value), do: marker

  defp diagnostic_sentinel(value, marker) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&diagnostic_sentinel(&1, marker)) |> List.to_tuple()

  defp diagnostic_sentinel(value, marker) when is_map(value),
    do:
      Map.new(Map.to_list(value), fn {key, item} -> {key, diagnostic_sentinel(item, marker)} end)

  defp diagnostic_sentinel([head | tail], marker),
    do: [diagnostic_sentinel(head, marker) | diagnostic_sentinel(tail, marker)]

  defp diagnostic_sentinel(value, _marker), do: value

  @tag connection_streams: :transport
  test "Connection streams: a historical active mode owns the first native delivery" do
    run = ConnectionNative.observe(:historical_active)
    assert run.result == :ok

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    unbound = NativeTransport.build(%{events: events})
    assert Enum.any?(unbound.errors, &(&1.actual == :native_active_mode))
    native = NativeTransport.build(%{events: events}, run.native_history)
    assert native.errors == []
    assert length(native.active) == 1
    assert Enum.map(native.options, & &1.mode) == [false]
    [delivery] = native.active
    assert {:historical_active_mode, holder} = delivery.activation.origin
    assert run.native_history[holder].protocol.buffer == :active_once
    assert ConnectionReads.build(native).errors == []
    assert_native_copies(delivery.copies, events, delivery.bytes)

    corrupt = ConnectionNative.observe(:historical_active, :unbound_active_control)

    corrupt_events =
      corrupt.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    rejected = NativeTransport.build(%{events: corrupt_events}, corrupt.native_history)
    assert Enum.any?(rejected.errors, &(&1.actual == :native_option_source))

    IO.puts(
      "CONNECTION_HISTORY_ACTIVE: missing origin RED; native origin GREEN; foreign control RED"
    )
  end

  @tag connection_streams: :transport
  test "Connection streams: coalesced messages have distinct addresses and real native indices" do
    run = ConnectionNative.observe(:pipeline)
    assert run.result == :ok

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    native = NativeTransport.build(%{events: events}, run.native_history)
    streams = ConnectionReads.build(native)
    assert native.errors == [] and streams.errors == []
    messages = ConnectionReads.messages(streams, %{events: events})
    assert messages != []
    assert Enum.all?(messages, &is_integer(&1.index))
    assert length(Enum.uniq_by(messages, & &1.message_address)) == length(messages)
    assert Enum.any?(Enum.group_by(messages, & &1.index), fn {_, group} -> length(group) > 1 end)
    contexts = DatabaseOrigins.sql_contexts(messages)
    assert map_size(contexts) == length(messages)

    for message <- messages do
      source = Enum.fetch!(events, message.index)
      assert source.pid == message.pid
      assert Capture.address(message) == message.message_address
      assert Map.fetch!(contexts, message.message_address) == message.wire_sql

      assert message.wire_frame.stop - message.wire_frame.start ==
               5 + byte_size(message.wire_frame.payload)
    end

    associated = Enum.filter(messages, &(not is_nil(&1.wire_frame.context)))
    requests? = Enum.all?(associated, &Map.has_key?(&1.wire_frame, :request))
    assert requests?, "logical messages must retain their exact frontend request instance"

    frontend = Enum.filter(associated, &(&1.wire_frame.direction == :frontend))

    for reply <- associated, reply.wire_frame.direction == :backend do
      requests = Enum.filter(frontend, &(&1.wire_frame.request == reply.wire_frame.request))
      assert length(requests) == 1
      [request] = requests
      assert request.wire_sql == reply.wire_sql
      assert is_integer(reply.wire_frame.request)
    end

    IO.puts(
      "CONNECTION_LOGICAL_ADDRESSES: coalesced native indices retained; all message contexts distinct"
    )
  end

  for boundary <- [:input, :buffer] do
    @tag connection_streams: :tls
    test "Connection streams: cold TLS handshake #{boundary} retains its native source" do
      boundary = unquote(boundary)

      build = fn run ->
        assert run.result == :ok
        events = Enum.with_index(run.events, &Map.put(&1, :index, &2))
        births = ConnectionTls.births(%{events: events})
        assert births.errors == []
        ConnectionTls.build(%{events: events}, births.bindings)
      end

      assert build.(ConnectionNative.observe_tls_startup()).errors == []

      control =
        if boundary == :input,
          do: :with_tls_handshake_input,
          else: :with_tls_handshake_buffer

      run = apply(ComparatorMutants, control, [&ConnectionNative.observe_tls_startup/0])
      proof = build.(run)
      rule = if boundary == :input, do: :tls_worker_state_copy, else: :tls_handshake_copy

      owner =
        if boundary == :input,
          do: :stream_tls_worker_state_copy,
          else: :stream_tls_handshake_copy

      coordinates =
        run.events
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {%{
             event:
               {_, :call,
                {:tls_gen_connection, :get_tls_handshakes, [_, _, {:native_foreign_helper, _}]}}
           }, index} ->
            [{index, [2, 2, 2]}]

          {%{
             event:
               {_, :return_from, {:tls_gen_connection, :get_tls_handshakes, 3},
                {_, {:native_foreign_return, _}, _}}
           }, index} ->
            [{index, [3, 1]}]

          _ ->
            []
        end)

      assert coordinates != []

      assert Enum.map(proof.errors, &{&1.rule, &1.index, Map.get(&1, :path)}) ==
               Enum.map(coordinates, fn {index, path} -> {rule, index, path} end)

      for mutant <- [
            :stream_tls_worker_state_copy,
            :stream_tls_handshake_copy,
            :stream_tls_machine_copy,
            :stream_tls_state_copy
          ] do
        checked = ComparatorMutants.with_mutant(mutant, fn -> build.(run) end)
        expected = if mutant == owner, do: [], else: proof.errors
        assert checked.errors == expected
      end

      assert build.(run).errors == proof.errors
      assert build.(ConnectionNative.observe_tls_startup()).errors == []
    end
  end

  @tag connection_streams: :tls
  test "Connection streams: ServerHello state has an independent native program" do
    build = fn run ->
      assert run.result == :ok
      events = Enum.with_index(run.events, &Map.put(&1, :index, &2))
      births = ConnectionTls.births(%{events: events})
      assert births.errors == []
      ConnectionTls.build(%{events: events}, births.bindings)
    end

    assert build.(ConnectionNative.observe_tls_startup()).errors == []

    run = ComparatorMutants.with_tls_server_hello_state(&ConnectionNative.observe_tls_startup/0)
    proof = build.(run)

    coordinates =
      run.events
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{
           event:
             {_, :return_from, {:tls_client_connection_1_3, :handle_server_hello, 2},
              {{:native_foreign_return, _}, :wait_ee}}
         }, index} ->
          [{index, [3]}]

        _ ->
          []
      end)

    assert coordinates != []

    assert Enum.map(proof.errors, &{&1.rule, &1.index, Map.get(&1, :path)}) ==
             Enum.map(coordinates, fn {index, path} -> {:tls_handshake_copy, index, path} end)

    for mutant <- [
          :stream_tls_handshake_copy,
          :stream_tls_worker_state_copy,
          :stream_tls_machine_copy,
          :stream_tls_state_copy
        ] do
      checked = ComparatorMutants.with_mutant(mutant, fn -> build.(run) end)
      expected = if mutant == :stream_tls_handshake_copy, do: [], else: proof.errors
      assert checked.errors == expected
    end

    assert build.(run).errors == proof.errors
    assert build.(ConnectionNative.observe_tls_startup()).errors == []
  end

  @tag connection_streams: :tls
  test "Connection streams: an equivalent native callback result retains its source form" do
    run =
      ComparatorMutants.with_tls_sender_mutant(:equivalent_callback_result, fn ->
        ConnectionNative.observe_tls()
      end)

    assert run.result == []
    events = Enum.with_index(run.events, &Map.put(&1, :index, &2))

    coordinates =
      for %{event: {_, :return_from, {:tls_sender, :connection, 3}, result}, index: index} <-
            events,
          is_tuple(result) and elem(result, 0) == :keep_state,
          do: index

    assert coordinates != []
    build = fn -> ConnectionTls.build(%{events: events}, run.tls_binding) end
    proof = build.()

    assert Enum.map(proof.errors, &{&1.rule, &1.index}) ==
             Enum.map(coordinates, &{:tls_callback_result, &1})

    for mutant <- [:stream_tls_callback_result, :stream_tls_worker_state_copy] do
      checked = ComparatorMutants.with_mutant(mutant, build)
      expected = if mutant == :stream_tls_callback_result, do: [], else: proof.errors
      assert checked.errors == expected
    end

    assert build.().errors == proof.errors
    positive = ConnectionNative.observe_tls()
    indexed = %{events: Enum.with_index(positive.events, &Map.put(&1, :index, &2))}
    assert ConnectionTls.build(indexed, positive.tls_binding).errors == []
  end

  @tag connection_streams: :tls
  test "Connection streams: record proof never reexecutes the native encoder" do
    run = ConnectionNative.observe_tls()
    assert native_encoder_calls(run) == []

    ComparatorMutants.with_mutant(:stream_tls_encode_replay, fn ->
      assert native_encoder_calls(run) != []
    end)

    assert native_encoder_calls(run) == []
    assert native_encoder_calls(ConnectionNative.observe_tls()) == []
  end

  defp native_encoder_calls(run) do
    encoders = [{:tls_record, :encode_data, 3}, {:tls_record_1_3, :encode_data, 2}]
    native_record_calls(run, encoders)
  end

  for {name, functions} <- [
        decoder: [
          {:tls_record, :decode_cipher_text, 4},
          {:tls_record_1_3, :decode_cipher_text, 2}
        ],
        parser: [{:tls_record, :get_tls_records, 5}]
      ] do
    @tag connection_streams: :tls
    test "Connection streams: record proof never reexecutes the native #{name}" do
      functions = unquote(Macro.escape(functions))
      run = ConnectionNative.observe_tls()
      assert native_record_calls(run, functions) == []
    end
  end

  defp native_record_calls(run, functions) do
    events = Enum.with_index(run.events, &Map.put(&1, :index, &2))

    calls =
      comparator_call_order(
        fn ->
          assert ConnectionTls.build(%{events: events}, run.tls_binding).errors == []
        end,
        functions
      )

    Enum.filter(calls, &match?({:call, _, _}, &1))
  end

  for {kind, mfa} <- [
        parser: {:tls_record, :get_tls_records, 5},
        decoder: {:tls_record_1_3, :decode_cipher_text, 2}
      ] do
    @tag connection_streams: :tls
    test "Connection streams: native #{kind} results have an independent sole catcher" do
      kind = unquote(kind)
      mfa = unquote(Macro.escape(mfa))
      positive = ConnectionNative.observe_tls()
      events = Enum.with_index(positive.events, &Map.put(&1, :index, &2))
      assert ConnectionTls.build(%{events: events}, positive.tls_binding).errors == []

      run = ComparatorMutants.with_tls_record_result(kind, &ConnectionNative.observe_tls/0)
      assert run.result == []
      events = Enum.with_index(run.events, &Map.put(&1, :index, &2))

      coordinates =
        for %{index: index, event: {_, :return_from, ^mfa, {{:native_foreign_return, _}, _}}} <-
              events,
            do: {:tls_record_output, index}

      assert coordinates != []
      proof = ConnectionTls.build(%{events: events}, run.tls_binding)
      assert Enum.map(proof.errors, &{&1.rule, &1.index}) == coordinates

      for mutant <- [
            :stream_tls_record_output,
            :stream_tls_record_copy,
            :stream_tls_worker_state_copy
          ] do
        checked =
          ComparatorMutants.with_mutant(mutant, fn ->
            ConnectionTls.build(%{events: events}, run.tls_binding)
          end)

        expected = if mutant == :stream_tls_record_output, do: [], else: proof.errors
        assert checked.errors == expected
      end

      assert ConnectionTls.build(%{events: events}, run.tls_binding).errors == proof.errors
      fresh = ConnectionNative.observe_tls()
      fresh_events = Enum.with_index(fresh.events, &Map.put(&1, :index, &2))
      assert ConnectionTls.build(%{events: fresh_events}, fresh.tls_binding).errors == []
    end
  end

  for boundary <- [:input, :return, :record] do
    @tag connection_streams: :tls
    test "Connection streams: TLS record #{boundary} copy retains its native source" do
      boundary = unquote(boundary)
      positive = ConnectionNative.observe_tls()
      events = Enum.with_index(positive.events, &Map.put(&1, :index, &2))
      assert ConnectionTls.build(%{events: events}, positive.tls_binding).errors == []

      control =
        case boundary do
          :input -> :with_tls_record_input
          :return -> :with_tls_record_output
          :record -> :with_tls_record_value
        end

      rule = if boundary == :record, do: :tls_record_selection, else: :tls_worker_state_copy

      owner =
        if boundary == :record,
          do: :stream_tls_record_selection,
          else: :stream_tls_worker_state_copy

      run = apply(ComparatorMutants, control, [&ConnectionNative.observe_tls/0])
      assert run.result == []
      events = Enum.with_index(run.events, &Map.put(&1, :index, &2))

      coordinates =
        Enum.flat_map(events, fn
          %{
            index: index,
            event:
              {_, :call, {:tls_gen_connection, :next_record, [_, _, {:native_foreign_helper, _}]}}
          } ->
            [{index, [2, 2, 2]}]

          %{
            index: index,
            event:
              {_, :return_from, {:tls_gen_connection, :next_record_done, 4},
               {_, {:native_foreign_return, _}}}
          } ->
            [{index, [3, 1]}]

          %{
            index: index,
            event:
              {_, :return_from, {:tls_gen_connection, :next_record_done, 4},
               {{:native_foreign_return, _}, _}}
          } ->
            [{index, [3, 0]}]

          _ ->
            []
        end)

      assert coordinates != []
      proof = ConnectionTls.build(%{events: events}, run.tls_binding)

      assert Enum.map(proof.errors, &{&1.rule, &1.index, Map.get(&1, :path)}) ==
               Enum.map(coordinates, fn {index, path} ->
                 {rule, index, path}
               end)

      for mutant <- [
            :stream_tls_worker_state_copy,
            :stream_tls_record_selection,
            :stream_tls_machine_copy,
            :stream_tls_state_copy
          ] do
        checked =
          ComparatorMutants.with_mutant(mutant, fn ->
            ConnectionTls.build(%{events: events}, run.tls_binding)
          end)

        expected = if mutant == owner, do: [], else: proof.errors
        assert checked.errors == expected
      end

      assert ConnectionTls.build(%{events: events}, run.tls_binding).errors == proof.errors
      restored = ConnectionNative.observe_tls()
      restored_events = Enum.with_index(restored.events, &Map.put(&1, :index, &2))
      assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
    end
  end

  @tag connection_streams: :tls
  test "Connection streams: native TLS sender state copies need an owning guard" do
    run = ComparatorMutants.with_tls_sender_mutant(&ConnectionNative.observe_tls/0)
    assert run.result == []

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    [corrupted] =
      Enum.filter(events, fn
        %{
          event:
            {_, :call,
             {:tls_sender, :send_application_data,
              [_data, _from, :connection, {:native_foreign_tls_state, _state}]}}
        } ->
          true

        _ ->
          false
      end)

    assert corrupted.pid == run.tls_binding.sender

    IO.puts(
      "NATIVE_OWNER_TLS_STATE_COPY: " <>
        Diagnostics.render(%{index: corrupted.index, mfa: corrupted.mfa})
    )

    native = ConnectionTls.build(%{events: events}, run.tls_binding)
    assert Enum.map(native.errors, & &1.rule) == [:tls_state_copy]
    assert hd(native.errors).index == corrupted.index

    for mutant <- [:stream_tls_workers, :stream_buffer_copy, :stream_tls_state_copy] do
      checked =
        ComparatorMutants.with_mutant(mutant, fn ->
          ConnectionTls.build(%{events: events}, run.tls_binding)
        end)

      expected = if mutant == :stream_tls_state_copy, do: [], else: [:tls_state_copy]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(ConnectionTls.build(%{events: events}, run.tls_binding).errors, & &1.rule) ==
             [:tls_state_copy]

    restored = ConnectionNative.observe_tls()

    restored_events =
      restored.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
    IO.puts("CONNECTION_TLS_STATE_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
  end

  @tag connection_streams: :tls
  test "Connection streams: native TLS callback actions retain their constructor" do
    run =
      ComparatorMutants.with_tls_sender_mutant(
        :callback_actions,
        &ConnectionNative.observe_tls/0
      )

    assert run.result == []

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    corrupted =
      Enum.filter(events, fn
        %{
          event:
            {_, :return_from, {:tls_sender, :hibernate_after, 3},
             {:next_state, :connection, _, [{:hibernate, false} | _]}}
        } ->
          true

        _ ->
          false
      end)

    assert corrupted != []
    native = ConnectionTls.build(%{events: events}, run.tls_binding)

    Diagnostics.emit("CONNECTION_TLS_CALLBACK_ACTION_PROOF", %{
      constructors: Enum.map(corrupted, & &1.index),
      errors: Enum.map(native.errors, &Map.take(&1, [:index, :rule, :path]))
    })

    assert Enum.map(native.errors, & &1.rule) == [:tls_callback_result]
    assert hd(native.errors).index == hd(corrupted).index

    for mutant <- [:stream_tls_state_copy, :stream_tls_reply_copy, :stream_tls_callback_result] do
      checked =
        ComparatorMutants.with_mutant(mutant, fn ->
          ConnectionTls.build(%{events: events}, run.tls_binding)
        end)

      expected = if mutant == :stream_tls_callback_result, do: [], else: [:tls_callback_result]
      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(ConnectionTls.build(%{events: events}, run.tls_binding).errors, & &1.rule) ==
             [:tls_callback_result]

    restored = ConnectionNative.observe_tls()

    restored_events =
      restored.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
    IO.puts("CONNECTION_TLS_CALLBACK_RESULT: owning RED; sole catcher; restore; fresh GREEN")
  end

  @tag connection_streams: :tls
  test "Connection streams: native TLS constructed state needs its own guard" do
    run =
      ComparatorMutants.with_tls_sender_mutant(
        :constructed_state,
        &ConnectionNative.observe_tls/0
      )

    assert run.result == []

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    [corrupted] =
      Enum.filter(events, fn
        %{
          event:
            {_, :call,
             {:tls_sender, :send_or_buffer, [_, _, _, _, {:native_foreign_tls_constructed, _}]}}
        } ->
          true

        _ ->
          false
      end)

    assert corrupted.pid == run.tls_binding.sender
    native = ConnectionTls.build(%{events: events}, run.tls_binding)
    assert Enum.map(native.errors, & &1.rule) == [:tls_worker_state_copy]
    assert hd(native.errors).index == corrupted.index

    for mutant <- [:stream_tls_state_copy, :stream_buffer_copy, :stream_tls_worker_state_copy] do
      checked =
        ComparatorMutants.with_mutant(mutant, fn ->
          ConnectionTls.build(%{events: events}, run.tls_binding)
        end)

      expected =
        if mutant == :stream_tls_worker_state_copy, do: [], else: [:tls_worker_state_copy]

      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(ConnectionTls.build(%{events: events}, run.tls_binding).errors, & &1.rule) ==
             [:tls_worker_state_copy]

    restored = ConnectionNative.observe_tls()

    restored_events =
      restored.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []

    IO.puts(
      "CONNECTION_TLS_CONSTRUCTED_STATE: owning RED; sole catcher; exact restore; fresh GREEN"
    )
  end

  for {corruption, position} <- [hibernate_name: 0, hibernate_actions: 2] do
    @tag connection_streams: :tls
    test "Connection streams: native TLS constructor #{corruption} keeps its earlier input" do
      corruption = unquote(corruption)
      position = unquote(position)

      run =
        ComparatorMutants.with_tls_sender_mutant(corruption, &ConnectionNative.observe_tls/0)

      assert run.result == []

      events =
        run.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      [corrupted] =
        Enum.filter(events, fn
          %{event: {_, :call, {:tls_sender, :hibernate_after, arguments}}} ->
            match?({:native_foreign_hibernate, _}, Enum.at(arguments, position))

          _ ->
            false
        end)

      native = ConnectionTls.build(%{events: events}, run.tls_binding)
      assert Enum.map(native.errors, & &1.rule) == [:tls_callback_input]
      assert hd(native.errors).index == corrupted.index

      for mutant <- [:stream_tls_callback_input, :stream_tls_callback_result] do
        checked =
          ComparatorMutants.with_mutant(mutant, fn ->
            ConnectionTls.build(%{events: events}, run.tls_binding)
          end)

        expected = if mutant == :stream_tls_callback_input, do: [], else: [:tls_callback_input]
        assert Enum.map(checked.errors, & &1.rule) == expected
      end

      assert Enum.map(ConnectionTls.build(%{events: events}, run.tls_binding).errors, & &1.rule) ==
               [:tls_callback_input]

      restored = ConnectionNative.observe_tls()

      restored_events =
        restored.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
      IO.puts("CONNECTION_TLS_CALLBACK_INPUT: owning RED; sole catcher; restore; fresh GREEN")
    end
  end

  @tag connection_streams: :tls
  test "Connection streams: native TLS forwarding retains record and reply copies" do
    for {control, rule, owner} <- [
          {:record_copy, :tls_record_copy, :stream_tls_record_copy},
          {:from_copy, :tls_forward_copy, :stream_tls_forward_copy}
        ] do
      run = ComparatorMutants.with_tls_sender_mutant(control, &ConnectionNative.observe_tls/0)
      assert run.result == []

      events =
        run.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      native = ConnectionTls.build(%{events: events}, run.tls_binding)
      assert Enum.map(native.errors, & &1.rule) == [rule]

      for mutant <- [
            :stream_tls_worker_state_copy,
            :stream_tls_record_copy,
            :stream_tls_forward_copy
          ] do
        checked =
          ComparatorMutants.with_mutant(mutant, fn ->
            ConnectionTls.build(%{events: events}, run.tls_binding)
          end)

        assert Enum.map(checked.errors, & &1.rule) == if(mutant == owner, do: [], else: [rule])
      end

      assert Enum.map(ConnectionTls.build(%{events: events}, run.tls_binding).errors, & &1.rule) ==
               [rule]

      restored = ConnectionNative.observe_tls()

      restored_events =
        restored.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
      IO.puts("CONNECTION_TLS_FORWARD_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
    end
  end

  @tag connection_streams: :tls
  test "Connection streams: TLS ciphertext retains its actual native port program" do
    run = ConnectionNative.observe_tls()
    assert run.result == []

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    # This is the encrypted transport ledger only. These bytes never enter the
    # PostgreSQL framing or association machine at the plaintext SSL boundary.
    transport = NativeTransport.build(%{events: events}, %{}, [run.tls_binding.transport])
    assert transport.errors == []
    assert transport.writes != []
    assert transport.active != []

    missing = NativeTransport.build(%{events: events})
    assert missing.errors != []
    assert Enum.all?(missing.errors, &(&1.actual == :native_active_mode))

    bypassed =
      ComparatorMutants.with_mutant(:stream_active_mode, fn ->
        NativeTransport.build(%{events: events})
      end)

    assert bypassed.errors == []
    assert NativeTransport.build(%{events: events}).errors != []
    assert NativeTransport.build(%{events: events}, %{}, [run.tls_binding.transport]).errors == []
  end

  for mode <- [nil, :debug] do
    @tag connection_streams: :tls
    test "Connection streams: TLS #{mode} machine roots retain queue and timer metadata" do
      run = ConnectionNative.observe_tls(unquote(mode))
      assert run.result == []
      machines = Map.get(run.tls_binding, :machines)
      assert is_map(machines), "TLS_MACHINE_HISTORY_ORIGIN_WITNESS"
      assert Enum.sort(Map.keys(machines)) == Enum.sort(Map.keys(run.tls_binding.states))

      assert_machine_debug(machines, unquote(mode))

      for {pid, %{params: params, state: state}} <- machines do
        assert tuple_size(params) == 7
        assert elem(params, 0) == :params
        assert tuple_size(state) == 6
        assert elem(state, 0) == :state
        assert elem(state, 1) === Map.fetch!(run.tls_binding.states, pid)
        assert is_list(elem(state, 2))
        assert is_map(elem(state, 3))
        assert is_list(elem(state, 4))
        assert is_boolean(elem(state, 5))
      end

      events =
        run.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      native = ConnectionTls.build(%{events: events}, run.tls_binding)

      for error <- native.errors do
        IO.puts("CONNECTION_MACHINE_STATE: " <> Diagnostics.render(error))
      end

      assert native.errors == []

      if unquote(mode) == :debug do
        for mfa <- [{:sys, :handle_debug, 4}, {:sys, :nlog_put, 2}] do
          assert Enum.any?(events, &(&1.mfa == mfa))
        end
      end

      covered = MapSet.new(native.terms, &{&1.index, &1.path})

      unbound =
        for %{event: {pid, :call, {module, function, arguments}}} = source <- events,
            Map.has_key?(machines, pid),
            (module == :gen_statem and machine_program_function?(function)) or
              (module == :sys and function in [:handle_debug, :nlog_put]),
            {argument, position} <- Enum.with_index(arguments),
            path = [2, 2, position],
            not native_argument_bound?(covered, source.index, path, argument),
            do: %{index: source.index, mfa: source.mfa, path: path}

      for copy <- unbound do
        IO.puts("CONNECTION_MACHINE_ARGUMENT_UNBOUND: " <> Diagnostics.render(copy))
      end

      assert unbound == [], "every native machine temporary argument needs its own program origin"
    end
  end

  defp assert_machine_debug(machines, :debug),
    do: assert(Enum.all?(machines, fn {_pid, machine} -> machine.debug != [] end))

  defp assert_machine_debug(_machines, _mode), do: :ok

  defp machine_program_function?(function),
    do:
      String.starts_with?(Atom.to_string(function), "loop") or
        function in [
          :reply_then_terminate,
          :do_reply_then_terminate,
          :terminate,
          :terminate_sys_debug,
          :sys_debug
        ]

  defp native_argument_bound?(covered, index, path, value) do
    MapSet.member?(covered, {index, path}) or
      native_argument_children?(covered, index, path, value)
  end

  defp native_argument_children?(covered, index, path, value)
       when is_tuple(value) and tuple_size(value) > 0 do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.all?(fn {item, position} ->
      native_argument_bound?(covered, index, path ++ [position], item)
    end)
  end

  defp native_argument_children?(_covered, _index, _path, _value), do: false

  for {corruption, position} <- [params: 0, queue: 3, hibernate: 4] do
    @tag connection_streams: :tls
    test "Connection streams: native TLS machine #{corruption} copies retain their origins" do
      assert :ok == ComparatorMutants.machine_copy_control(unquote(corruption), unquote(position))
    end
  end

  @tag connection_streams: :tls
  test "Connection streams: native machine temporary arguments retain their complete program" do
    targets = %{
      {:loop_state_callback, 11} => [1, 3, 5, 6, 7, 8, 9, 10],
      {:loop_state_callback_result, 11} => [1, 3, 5, 6, 7, 8, 9, 10],
      {:loop_actions_list, 12} => [1, 3, 5, 6, 7, 8, 9, 10, 11]
    }

    assert :ok == ComparatorMutants.machine_program_control(targets)
  end

  @tag connection_streams: :tls
  test "Connection streams: native debug logs retain their program inputs and successive roots" do
    targets = %{{:loop_event, 5} => [1], {:sys_debug, 3} => [0, 1, 2]}
    assert :ok == ComparatorMutants.machine_program_control(targets, :debug)
  end

  @tag connection_streams: :tls
  test "Connection streams: native debug ring outputs retain every entry and formatter" do
    assert :ok == ComparatorMutants.machine_debug_log_control()
  end

  @tag connection_streams: :tls
  test "Connection streams: native machine termination retains class, reason, stack and replies" do
    targets = %{
      {:reply_then_terminate, 8} => [0, 1, 2, 4, 6, 7],
      {:do_reply_then_terminate, 8} => [0, 1, 2, 4, 6, 7],
      {:terminate, 7} => [0, 1, 2, 4, 6]
    }

    assert :ok == ComparatorMutants.machine_program_control(targets)
  end

  @tag connection_streams: :tls
  test "Connection streams: native machine timeout arguments retain their action program" do
    targets = %{
      {:loop_timeouts, 12} => [1, 3, 5, 6, 7, 8, 9, 10, 11],
      {:loop_timeouts, 16} => [1, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      {:loop_timeouts_cancel, 13} => [1, 3, 5, 6, 7, 8, 9, 10, 11, 12]
    }

    assert :ok == ComparatorMutants.machine_program_control(targets)
  end

  for mode <- [nil, :fragmented] do
    @tag connection_streams: :tls
    test "Connection streams: native #{mode} machine and direct TLS reply values retain their origins" do
      assert :ok == ComparatorMutants.machine_reply_control(unquote(mode))
    end
  end

  for corruption <- [:reply_copy, :reply_value] do
    @tag connection_streams: :tls
    test "Connection streams: TLS reply forwarding binds #{corruption}" do
      corruption = unquote(corruption)

      run =
        ComparatorMutants.with_tls_sender_mutant(corruption, &ConnectionNative.observe_tls/0)

      assert run.result == []

      events =
        run.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      assert Enum.any?(events, fn
               %{event: {_, :call, {:tls_sender, :send_reply, arguments}}} ->
                 Enum.any?(arguments, &match?({:native_foreign_tls_reply, _}, &1))

               _ ->
                 false
             end)

      native = ConnectionTls.build(%{events: events}, run.tls_binding)
      assert Enum.map(native.errors, & &1.rule) == [:tls_reply_copy]

      for mutant <- [:stream_tls_state_copy, :stream_tls_forward_copy, :stream_tls_reply_copy] do
        bypassed =
          ComparatorMutants.with_mutant(mutant, fn ->
            ConnectionTls.build(%{events: events}, run.tls_binding)
          end)

        expected = if mutant == :stream_tls_reply_copy, do: [], else: [:tls_reply_copy]
        assert Enum.map(bypassed.errors, & &1.rule) == expected
      end

      assert Enum.map(ConnectionTls.build(%{events: events}, run.tls_binding).errors, & &1.rule) ==
               [:tls_reply_copy]

      restored = ConnectionNative.observe_tls()

      restored_events =
        restored.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
      IO.puts("CONNECTION_TLS_REPLY_COPY: owning RED; sole catcher; exact restore; fresh GREEN")
    end
  end

  @tag connection_streams: :transport
  test "Connection streams: counted passive notifications need their own native origin" do
    for corruption <- [nil, :passive_source] do
      run = ConnectionNative.observe(:active_counted, corruption)
      assert run.result == :ok

      events =
        run.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      native = NativeTransport.build(%{events: events}, run.native_history)
      expected = if corruption, do: [:native_passive_source], else: []
      assert Enum.map(native.errors, & &1.actual) == expected
      assert Map.get(native, :passive, []) != [], "NATIVE_PASSIVE_ORIGIN_WITNESS"

      for notification <- native.passive do
        assert notification.source.index < notification.received.index
        assert notification.origin < notification.source.index
        assert notification.source.index in notification.indexes
        assert notification.received.index in notification.indexes
      end

      if corruption do
        for mutant <- [:stream_active_source, :stream_active_mode, :stream_passive_source] do
          bypassed =
            ComparatorMutants.with_mutant(mutant, fn ->
              NativeTransport.build(%{events: events}, run.native_history)
            end)

          expected = if mutant == :stream_passive_source, do: [], else: expected
          assert Enum.map(bypassed.errors, & &1.actual) == expected
        end

        assert Enum.map(
                 NativeTransport.build(%{events: events}, run.native_history).errors,
                 & &1.actual
               ) == expected
      end
    end

    restored = ConnectionNative.observe(:active_counted)

    restored_events =
      restored.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    assert NativeTransport.build(%{events: restored_events}, restored.native_history).errors == []
    IO.puts("CONNECTION_PASSIVE_ORIGIN: native positive; owning RED; sole catcher; restore GREEN")
  end

  @tag connection_streams: :tls
  test "Connection streams: fragmented TLS binds active counts and worker transitions" do
    run = ConnectionNative.observe_tls(:fragmented)
    assert run.result == []

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    transport = NativeTransport.build(%{events: events}, %{}, [run.tls_binding.transport])
    assert transport.errors == []

    assert Enum.any?(transport.options, fn option ->
             option.mode == 2
           end),
           "real fragmented TLS must replenish its native active count"

    assert transport.passive != [],
           "the fragmented fixture must actually cross passive transitions"

    tls = ConnectionTls.build(%{events: events}, run.tls_binding)

    for error <- tls.errors do
      IO.puts("CONNECTION_TLS_FRAGMENTED: " <> Diagnostics.render(error))
    end

    assert tls.errors == []
  end

  for {corruption, rule, owner} <- [
        {:active_option, :tls_active_option_copy, :stream_tls_active_option},
        {:passive_option, :tls_passive_option, :stream_tls_passive_option}
      ] do
    @tag connection_streams: :tls
    test "Connection streams: native TLS #{corruption} is independently enforced" do
      corruption = unquote(corruption)
      rule = unquote(rule)
      owner = unquote(owner)

      run =
        ComparatorMutants.with_tls_connection_mutant(corruption, fn ->
          ConnectionNative.observe_tls(:fragmented)
        end)

      assert run.result == []

      events =
        run.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      native = ConnectionTls.build(%{events: events}, run.tls_binding)
      expected = tls_option_corruptions(events, native, run.tls_binding, corruption)
      assert expected != []

      for error <- native.errors do
        Diagnostics.emit(
          "CONNECTION_TLS_OPTION_CONTROL_FAILURE",
          Map.take(error, [:index, :rule, :path, :differences])
        )
      end

      assert Enum.map(native.errors, & &1.rule) == List.duplicate(rule, length(expected))
      assert Enum.map(native.errors, & &1.index) == expected

      for mutant <- [:stream_tls_worker_state_copy, owner] do
        checked =
          ComparatorMutants.with_mutant(mutant, fn ->
            ConnectionTls.build(%{events: events}, run.tls_binding)
          end)

        errors = if mutant == owner, do: [], else: List.duplicate(rule, length(expected))
        assert Enum.map(checked.errors, & &1.rule) == errors
      end

      assert Enum.map(ConnectionTls.build(%{events: events}, run.tls_binding).errors, & &1.index) ==
               expected

      restored = ConnectionNative.observe_tls(:fragmented)

      restored_events =
        restored.events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

      assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
      IO.puts("CONNECTION_TLS_OPTION: owning RED; sole catcher; restore; fresh GREEN")
    end
  end

  defp tls_option_corruptions(_events, native, binding, :active_option) do
    for option <- native.transport.options,
        option.port == binding.port and option.source.pid == binding.owner and option.mode == 3,
        do: option.returned.index
  end

  defp tls_option_corruptions(events, native, binding, :passive_option) do
    for %{
          event:
            {pid, :call,
             {:tls_gen_connection, :gen_info, [{:tcp_passive, port}, :connection, data]}}
        } = source <- events,
        pid == binding.owner and port == binding.port,
        elem(elem(data, 9), 1) == :undefined or elem(elem(data, 11), 3) != [],
        pair = Map.fetch!(native.pairs, source.index) do
      tls_passive_transition(events, pid, source.index, pair.returned.index)
    end
  end

  defp tls_passive_transition(events, pid, first, last) do
    Enum.find_value(events, fn
      %{pid: ^pid, index: index, mfa: {:tls_gen_connection, :next_event, 3}}
      when index > first and index < last ->
        index

      _ ->
        nil
    end)
  end

  @tag connection_streams: :tls
  test "Connection streams: TLS plaintext has a native physical port binding" do
    observations =
      Map.new([nil, :binding, :workers, :byte], fn corruption ->
        run = ConnectionNative.observe_tls(corruption)

        expected =
          case corruption do
            :binding -> [:tls_local_endpoint]
            :workers -> [:tls_connection_workers]
            _ -> []
          end

        assert run.result == expected

        service_timers =
          for {_ref, %{dest: :ssl_manager} = timer} <- run.snapshot.timers, do: timer

        assert service_timers != [], "native TLS certificate cleanup must be observed"

        for timer <- service_timers do
          assert timer.state == :fired
          assert MapSet.member?(run.snapshot.pids, timer.creator)
          service = Map.fetch!(run.snapshot.services, timer.terminal.pid)
          assert service.name == :ssl_manager
          assert service.callback == {:ssl_manager, :handle_info, 2}
          assert {_, :receive, message} = timer.terminal.received
          assert message == timer.expected

          assert {_, :return_from, {:ssl_manager, :handle_info, 2}, {:noreply, _}} =
                   timer.terminal.returned
        end

        for process <- run.tls_binding.processes do
          IO.puts(
            "CONNECTION_TLS_PROCESS_ORIGIN: " <>
              Diagnostics.render(%{
                mfa: process.mfa,
                role:
                  if(process.pid == run.tls_binding.owner, do: :transport_owner, else: :linked)
              })
          )
        end

        events =
          run.events
          |> Enum.with_index()
          |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

        assert Enum.any?(events, &(&1.pid == run.tls_binding.owner)),
               "the actual preexisting TLS receiver must be traced"

        assert Enum.any?(events, &(&1.pid == run.tls_binding.sender)),
               "the actual preexisting TLS sender must be traced"

        assert Enum.any?(events, fn source ->
                 source.pid == run.tls_binding.sender and
                   source.mfa == {:tls_sender, :connection, 3}
               end),
               "the actual TLS sender callback needs its own native frame origin"

        native = ConnectionTls.build(%{events: events}, run.tls_binding)
        assert native.errors == []

        bound_states = MapSet.new(native.terms, &{&1.index, &1.path})

        unbound_states =
          events
          |> Enum.flat_map(&native_tls_states(&1, run.tls_binding))
          |> Enum.reject(&MapSet.member?(bound_states, {&1.index, &1.path}))

        for copy <- unbound_states do
          IO.puts("CONNECTION_TLS_STATE_UNBOUND: " <> Diagnostics.render(copy))
        end

        assert unbound_states == [], "every native TLS worker state copy needs an earlier origin"
        assert length(native.writes) == 1
        assert native.reads != []

        for write <- native.writes, do: assert_native_copies(write.copies, events, write.bytes)
        for read <- native.reads, do: assert_native_copies(read.copies, events, read.bytes)

        streams = ConnectionReads.build(native)
        assert streams.errors == []
        assert map_size(streams.connections) == 1
        connection = Map.fetch!(streams.connections, run.tls_binding.port)
        messages = Enum.map(connection.protocol.messages, & &1.decoded)
        assert messages != []
        logical = ConnectionReads.messages(streams, %{events: events})
        assert length(logical) == length(messages)
        assert Enum.all?(logical, &is_integer(&1.index))
        assert Enum.all?(logical, &(elem(&1.message_address, 1) == run.tls_binding.port))

        for event <- events do
          owner =
            cond do
              event.pid == run.snapshot.root -> :caller
              event.pid == run.tls_binding.owner -> :tls_transport_owner
              event.pid == run.tls_binding.sender -> :tls_sender
              event.pid == run.tls_binding.port -> :transport
              Map.has_key?(run.snapshot.services, event.pid) -> :shared_service
              true -> :other_native_process
            end

          IO.puts(
            "CONNECTION_TLS_NATIVE_EVENT: " <>
              Diagnostics.render(%{
                index: event.index,
                mfa: event.mfa,
                tag: elem(event.event, 1),
                owner: owner
              })
          )
        end

        {corruption, messages}
      end)

    assert observations[nil] == observations.binding
    assert observations[nil] == observations.workers
    refute observations[nil] == observations.byte

    bypassed =
      ComparatorMutants.with_mutant(:stream_tls_binding, fn ->
        ConnectionNative.observe_tls(:binding).result
      end)

    assert bypassed == []
    assert ConnectionNative.observe_tls(:binding).result == [:tls_local_endpoint]
    assert ConnectionNative.observe_tls().result == []
    IO.puts("CONNECTION_TLS_BINDING: native positive; owning RED; exact restore GREEN")

    bypassed =
      ComparatorMutants.with_mutant(:stream_tls_workers, fn ->
        ConnectionNative.observe_tls(:workers).result
      end)

    assert bypassed == []
    assert ConnectionNative.observe_tls(:workers).result == [:tls_connection_workers]
    assert ConnectionNative.observe_tls().result == []
    IO.puts("CONNECTION_TLS_WORKERS: native positive; owning RED; exact restore GREEN")
  end

  defp native_tls_states(source, binding) do
    # Pinned OTP 29.1.2 tls_sender's data and ssl_connection.hrl's state.
    # This enumerates native coordinates; it grants no event or field allowance.
    families = Map.get(binding, :families, [binding])
    sockets = Enum.map(families, & &1.socket)

    kind =
      Enum.find_value(families, fn family ->
        cond do
          source.pid == family.sender -> {:data, 5}
          source.pid == family.owner -> {:state, 13}
          true -> nil
        end
      end)

    for path <- tls_state_paths(source.event, [], kind, sockets),
        do: %{index: source.index, mfa: source.mfa, path: path}
  end

  defp tls_state_paths(_value, _path, nil, _sockets), do: []

  defp tls_state_paths(value, path, kind, sockets) do
    if Enum.any?(sockets, &(&1 === value)),
      do: [],
      else: tls_state_value_paths(value, path, kind, sockets)
  end

  defp tls_state_value_paths(value, path, {tag, size} = kind, socket) when is_tuple(value) do
    if tuple_size(value) == size and elem(value, 0) == tag do
      [path]
    else
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, position} ->
        tls_state_paths(item, path ++ [position], kind, socket)
      end)
    end
  end

  defp tls_state_value_paths(value, path, kind, socket) when is_map(value) do
    Enum.flat_map(value, fn {key, item} ->
      tls_state_paths(key, path ++ [{:map_key, key}], kind, socket) ++
        tls_state_paths(item, path ++ [key], kind, socket)
    end)
  end

  defp tls_state_value_paths(value, path, kind, socket) when is_function(value) do
    {:env, environment} = Function.info(value, :env)
    tls_state_paths(environment, path ++ [:function, :env], kind, socket)
  end

  defp tls_state_value_paths([_head | _tail] = list, path, kind, socket),
    do: tls_state_list(list, path, kind, socket, 0)

  defp tls_state_value_paths(_value, _path, _kind, _socket), do: []

  defp tls_state_list([head | tail], path, kind, socket, position),
    do:
      tls_state_paths(head, path ++ [position], kind, socket) ++
        tls_state_list(tail, path, kind, socket, position + 1)

  defp tls_state_list([], _path, _kind, _socket, _position), do: []

  defp tls_state_list(tail, path, kind, socket, position),
    do: tls_state_paths(tail, path ++ [{:improper_tail, position}], kind, socket)
end
