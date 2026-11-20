defmodule AshOnetime.Delivery.ComparatorControlsTest do
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false

  alias AshOnetime.Test.ExitBoundary.{
    Comparator,
    Completeness,
    ContextCopies,
    Declarations,
    Origins,
    PermittedTrace,
    Registry,
    Returned,
    Scenarios,
    Search,
    TransportReferences,
    Values,
    Wire,
    Withheld
  }

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

        IO.inspect(%{attempt: attempt, run: run, twin: twin, seconds: delta},
          label: "C_TICK_READS"
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
    IO.inspect(Enum.map(tail, fn e -> {elem(e, 1), event_mfa(e)} end), label: "U1_RERAISE")
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

    assert_green(pair)
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

      assert Enum.all?(binds, fn {:bind_column, _, oid, format, _} ->
               is_integer(oid) and format in [0, 1]
             end)

      assert Enum.all?(rows, fn {:data_column, sql, {ordinal, _}, _, _, {:table_oid, oid}, _,
                                 type, format, _} ->
               is_binary(sql) and is_integer(ordinal) and is_integer(oid) and is_integer(type) and
                 format in [0, 1]
             end)

      clocks =
        for {:data_column, _, _, _, field, _, _, type, _, _} <- rows,
            field in ["admitted_at", "retain_until", "inserted_at"],
            do: type

      assert clocks != [] and Enum.all?(clocks, &(&1 == 1184))
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

      IO.inspect(
        %{side: name, full: length(captured.pattern_probe), reduced: length(captured.events)},
        label: "U10_SAME_INVOCATION_EXIT_EQUALITY"
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

        IO.inspect(
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
          label: "U14_ANCHORS",
          limit: :infinity
        )

        pair
      end

    production_raises =
      AshOnetime.Test.ExitBoundary.PathFrameWitnesses.capture(context, Values.set()[:va])

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
    IO.inspect(first, label: "U_CONSUMER_NATIVE_FIRST_DIVERGENCE")

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
      before = AshOnetime.Test.ExitBoundary.Persisted.snapshot(context.prefix, context.repo)
      Ecto.Adapters.SQL.query!(
        context.repo,
        ~s[INSERT INTO "#{context.prefix}".ash_onetime_boundary_records (id, amount) VALUES ($1::uuid, 1)],
        [Ecto.UUID.dump!(id)]
      )

      first = AshOnetime.Test.ExitBoundary.Persisted.snapshot(context.prefix, context.repo)
      equal = AshOnetime.Test.ExitBoundary.Persisted.snapshot(context.prefix, context.repo)

      Ecto.Adapters.SQL.query!(
        context.repo,
        ~s[UPDATE "#{context.prefix}".ash_onetime_boundary_records SET amount = amount + 1 WHERE id = $1::uuid],
        [Ecto.UUID.dump!(id)]
      )

      changed = AshOnetime.Test.ExitBoundary.Persisted.snapshot(context.prefix, context.repo)
      run = consumer_capture(0)
      twin = consumer_capture(0)
      delta = &AshOnetime.Test.ExitBoundary.Persisted.delta(before, &1)
      twin_side = observation_side(context, twin, delta.(first), row)
      equal_side = observation_side(context, run, delta.(equal), row)
      run_side = observation_side(context, run, delta.(changed), row)

      assert compare_observation(equal_side, twin_side, row).errors == []
      comparison = compare_observation(run_side, twin_side, row)
      difference = List.first(comparison.errors)
      IO.inspect(difference, label: "U_STORE_NATIVE_FIRST_DIVERGENCE")

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

  @tag :r17
  @tag :u_error_observation
  test "U observation: captured error details remain exact", context do
    row = row!(:issue, :execute)
    twin = observation_side(context, error_capture(0), %{}, row)
    equal = observation_side(context, error_capture(0), %{}, row)
    changed = observation_side(context, error_capture(1), %{}, row)

    assert compare_observation(equal, twin, row).errors == []
    first = compare_observation(changed, twin, row).errors |> List.first()
    IO.inspect(first, label: "U_ERROR_NATIVE_FIRST_DIVERGENCE")

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
      AshOnetime.Test.ExitBoundary.observe(
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
      AshOnetime.Test.ExitBoundary.observe(
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

  defp observation_side(context, run, delta, row) do
    %{
      run: run,
      delta: delta,
      row: row,
      prefix: context.prefix,
      resource: Withheld,
      bound: %{},
      hooks: %{},
      hook_frames: %{},
      historical: AshOnetime.Test.ExitBoundary.Historical.capture(context.prefix),
      operation_reference: AshOnetime.Test.ExitBoundary.References.operation(Withheld, row.action)
    }
  end

  defp assert_green(pair) do
    result = Comparator.compare(pair)
    locations = Enum.map(result.errors, &{&1.at, &1.rule, &1.path})
    assert locations == [], "comparator differences: #{inspect(locations)}"
  end

  defp next_second(side) do
    reads = ttl_reads(side)
    if reads == [], do: raise("C-tick did not capture a TTL read")
    target = (DateTime.to_unix(List.last(reads)) + 1) * 1_000
    now = System.system_time(:millisecond)
    IO.inspect(%{target: target, after_side: now}, label: "C_TICK_BOUNDARY")
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
