defmodule AshOnetime.Delivery.ComparatorControlsTest do
  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.Allocation
  alias AshOnetime.Test.ExitBoundary.ClockExpressions
  alias AshOnetime.Test.ExitBoundary.Comparator
  alias AshOnetime.Test.ExitBoundary.ComparatorMutants
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.Completeness
  alias AshOnetime.Test.ExitBoundary.ConnectionDecoders
  alias AshOnetime.Test.ExitBoundary.ConnectionNative
  alias AshOnetime.Test.ExitBoundary.ConnectionProtocol
  alias AshOnetime.Test.ExitBoundary.ConnectionReads
  alias AshOnetime.Test.ExitBoundary.ContextCopies
  alias AshOnetime.Test.ExitBoundary.DatabaseOrigins
  alias AshOnetime.Test.ExitBoundary.Declarations
  alias AshOnetime.Test.ExitBoundary.Diagnostics
  alias AshOnetime.Test.ExitBoundary.Historical
  alias AshOnetime.Test.ExitBoundary.NativeTransport
  alias AshOnetime.Test.ExitBoundary.Origins
  alias AshOnetime.Test.ExitBoundary.PathFrameWitnesses
  alias AshOnetime.Test.ExitBoundary.PermittedTrace
  alias AshOnetime.Test.ExitBoundary.Persisted
  alias AshOnetime.Test.ExitBoundary.QueryOrigins
  alias AshOnetime.Test.ExitBoundary.Readback
  alias AshOnetime.Test.ExitBoundary.References
  alias AshOnetime.Test.ExitBoundary.Registry
  alias AshOnetime.Test.ExitBoundary.Returned
  alias AshOnetime.Test.ExitBoundary.Scenarios
  alias AshOnetime.Test.ExitBoundary.Scheduling
  alias AshOnetime.Test.ExitBoundary.Search
  alias AshOnetime.Test.ExitBoundary.TransportReferences
  alias AshOnetime.Test.ExitBoundary.Values
  alias AshOnetime.Test.ExitBoundary.Wire
  alias AshOnetime.Test.ExitBoundary.Withheld
  alias AshOnetime.Test.Repo
  alias AshOnetime.Test.StoreCase
  alias Ecto.Adapters.SQL
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false

  @tag :connection_streams
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
    end
  end

  @tag :connection_streams
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

  @tag :connection_streams
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

  defp native_result(%{result: {:caught, kind, _reason}}), do: {:caught, kind, :term}
  defp native_result(_run), do: :unexpected_result

  @tag :connection_streams
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
    result = ConnectionReads.build(native, MapSet.new(), %{history.port => prepared.statements})
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

  @tag :connection_streams
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
    IO.puts("CONNECTION_STREAM_ACTIVE_PROGRAMS: " <> inspect(programs, limit: :infinity))

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

  @tag :connection_streams
  test "Connection streams: every active control has its own native option origin" do
    run = ConnectionNative.observe(:active, :unbound_active_control)
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

    assert Enum.map(NativeTransport.build(indexed).errors, & &1.actual) == [:native_option_source]
    {restored, _streams} = native_connection(:active, nil)
    assert restored.errors == []
    IO.puts("CONNECTION_STREAM_NATIVE_ISOLATION: stream_active_source RED; exact restore GREEN")
  end

  @tag :connection_streams
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
    IO.puts("CONNECTION_STREAM_DEFERRED_CONTROLS: " <> inspect(length(deferred)))
  end

  @tag :connection_streams
  test "Connection streams: Postgrex replays its own unread native buffer" do
    replays =
      for _ <- 1..20 do
        run = ConnectionNative.observe(:buffered)
        assert native_result(run) == :ok

        events =
          run.events
          |> Enum.with_index()
          |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

        native = NativeTransport.build(%{events: events})
        assert native.errors == []
        assert_native_streams_complete(run)
        buffer_replays(events, native)
      end

    replays = List.flatten(replays)
    IO.puts("CONNECTION_STREAM_BUFFER_PROGRAMS: " <> inspect(replays, limit: :infinity))
    assert replays != [], "the native runs must actually execute Postgrex buffered replay"
  end

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
    # This observes the producer's actual program. Buffered-copy validation and
    # the ping's finite timeout origin are separate transducer obligations.
    demand_rules = Enum.map(ConnectionReads.build(native).errors, & &1.rule)

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

  @tag :connection_streams
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

  @tag :connection_streams
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
            inspect(%{attempt: attempt, run: run, twin: twin, seconds: delta}, pretty: true)
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
        ": " <> inspect(Enum.map(tail, fn e -> {elem(e, 1), event_mfa(e)} end), pretty: true)
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
        inspect(
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

    indexed = Origins.build(pair.run)
    scheduled = Scheduling.build(indexed)
    indexed = %{indexed | events: scheduled.events}
    permitted = PermittedTrace.match(pair.run, indexed)
    readback = Readback.check(pair.run, indexed, permitted.bound)

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
    IO.puts("U2_NATIVE_WIRE_ORIGINS" <> ": " <> inspect(origins, pretty: true, limit: :infinity))

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
          inspect(%{side: side.resource, instances: counts}, pretty: true, limit: :infinity)
      )

      u2_command_ownership(
        side,
        if(side.resource == Withheld, do: readback.claimed, else: MapSet.new())
      )
    end

    assert outside == [],
           "OPEN claimed transport outside its native interval: #{inspect(outside)}"

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
    proof = Allocation.check(pair.twin, Origins.build(pair.twin))
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
        indexed = Origins.build(captured.twin)
        rejected = Allocation.check(captured.twin, indexed)
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
            ": " <> inspect(%{fault: name, rejected_by: rule}, pretty: true)
        )
      end)

      assert File.read!(path) === original
    end

    restored = observe(context, row, values)

    errors =
      Allocation.check(restored.twin, Origins.build(restored.twin)).errors
      |> Diagnostics.safe()

    assert errors == []
    assert_green(restored)
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

      assert owned?, inspect(Diagnostics.safe(first))
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

        assert owned?, inspect(Diagnostics.safe(first))
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
    IO.puts("U_CROSS_LEASE_NATIVE_CONFLICT" <> ": " <> inspect(rejected.errors, pretty: true))
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
          ": " <> inspect(%{mutant: rule, remaining: length(rejected.errors)}, pretty: true)
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
        inspect(Enum.map(rejected.errors, &Map.take(&1, [:rule, :run, :twin])), pretty: true)
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
          inspect(
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
          ": " <> inspect(%{side: side.resource, copies: Enum.frequencies(tokens)}, pretty: true)
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
          inspect(
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
            inspect(
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
    IO.puts("U_CONSUMER_NATIVE_FIRST_DIVERGENCE" <> ": " <> inspect(first, pretty: true))

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
      IO.puts("U_STORE_NATIVE_FIRST_DIVERGENCE" <> ": " <> inspect(difference, pretty: true))

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
    IO.puts("U_ERROR_NATIVE_FIRST_DIVERGENCE" <> ": " <> inspect(first, pretty: true))

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
          inspect(
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
    assert locations == [], "comparator differences: #{inspect(locations)}"
  end

  defp next_second(side) do
    reads = ttl_reads(side)
    if reads == [], do: raise("C-tick did not capture a TTL read")
    target = (DateTime.to_unix(List.last(reads)) + 1) * 1_000
    now = System.system_time(:millisecond)

    IO.puts(
      "C_TICK_BOUNDARY" <> ": " <> inspect(%{target: target, after_side: now}, pretty: true)
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
                 "U8: a pool monitor role has no twin occurrence: #{inspect(%{key: key, index: origin.index})}"

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
    indexed = Origins.build(side)
    scheduled = Scheduling.build(indexed)
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
        inspect(
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
end
