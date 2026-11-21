defmodule AshOnetime.Test.ExitBoundary.ClockExpressions do
  @moduledoc false

  @starters [
    {AshOnetime.Admission, :reserve, 3},
    {AshOnetime.Admission, :reserve_committed, 3},
    {AshOnetime.Admission, :complete, 2},
    {AshOnetime.Admission, :key_component, 6},
    {AshOnetime.ExternalRecovery, :reserve, 4},
    {AshOnetime.Store.Postgres, :record_outcome_committed, 4}
  ]

  def build(indexed, side) do
    initial = %{
      pending: %{},
      active: %{},
      outcome_workers: %{},
      reads: %{},
      slots: %{},
      errors: [],
      cache_expiries: side.historical.cache_expiries,
      cache_ttls: %{},
      ttls: %{},
      cache_calls: %{},
      checkpoints: %{},
      durations: %{},
      telemetry: %{},
      spans: %{},
      entries: %{},
      meters: %{},
      checkout: %{},
      db_checkout: %{},
      last_checkin: %{},
      holder_clocks: side.historical.pool_clocks,
      connected: Map.new(side.historical.connections, fn {holder, c} -> {holder, c.clock} end)
    }

    Enum.reduce(indexed.events, initial, fn e, s ->
      s =
        if e.mfa == {AshOnetime.Store, :committed_completion, 2} and elem(e.event, 1) == :call,
          do: put_in(s.checkpoints[e.index], s.holder_clocks),
          else: s

      event(e, s)
    end)
  end

  def project(event, index, state), do: project_at(event, index, [], state)
  def project_at(event, index, base, state), do: walk(event, base, index, state.slots)

  defp walk(value, path, index, slots) do
    case Map.fetch(slots, {index, path}) do
      {:ok, {_expected, token}} -> {:clock_expression, token}
      :error -> descend(value, path, index, slots)
    end
  end

  defp descend(value, path, index, slots) when is_map(value),
    do:
      Map.new(Map.to_list(value), fn {key, item} ->
        {key, walk(item, path ++ [key], index, slots)}
      end)

  defp descend(value, path, index, slots) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {item, n} -> walk(item, path ++ [n], index, slots) end)
      |> List.to_tuple()

  defp descend(value, path, index, slots) when is_list(value),
    do: list(value, path, index, slots, 0)

  defp descend(value, _, _, _), do: value
  defp list([], _, _, _, _), do: []

  defp list([h | t], path, index, slots, n),
    do: [walk(h, path ++ [n], index, slots) | list(t, path, index, slots, n + 1)]

  defp list(t, path, index, slots, n), do: walk(t, path ++ [n], index, slots)

  defp event(%{event: {pid, :call, {m, f, args}}} = e, s) do
    mfa = {m, f, length(args)}
    active = Map.get(s.active, pid, [])
    frame = %{mfa: mfa, args: args, index: e.index, started: nil}
    s = put_in(s.active[pid], [frame | active])
    s = put_in(s.pending[{pid, mfa}], [frame | Map.get(s.pending, {pid, mfa}, [])])
    call(e, mfa, args, s) |> then(&exits(e, &1))
  end

  defp event(%{event: {pid, tag, mfa, value}} = e, s)
       when tag in [:return_from, :exception_from] do
    {frame, pending} = pop(s.pending, {pid, mfa})
    s = %{s | pending: pending}
    s = if tag == :return_from, do: returned(e, mfa, frame, value, s), else: s
    {_inner, rest} = Enum.split_while(Map.get(s.active, pid, []), &(&1.mfa != mfa))
    put_in(s.active[pid], Enum.drop(rest, 1)) |> then(&exits(e, &1))
  end

  defp event(%{event: {_, :receive, {:"ETS-TRANSFER", holder, _, {_, _, checkin}}}} = e, s) do
    expected = Map.fetch(s.holder_clocks, holder)
    check(s, e, [2, 3, 2], checkin, expected, :pool_checkin)
  end

  defp event(%{event: {parent, :spawn, child, _}} = e, s) do
    s =
      case outcome_start(s, parent) do
        {:ok, start} -> put_in(s.outcome_workers[child], start)
        :error -> s
      end

    exits(e, s)
  end

  defp event(e, s), do: exits(e, s)

  defp call(e, {DBConnection, :checkout, 3}, [_pool, meter, _opts], s) do
    s = meter_copy(s, e, [2, 2, 1], meter)
    put_in(s.db_checkout[e.role], :awaiting_clock)
  end

  defp call(e, {DBConnection, :event, 2}, [meter, _name], s),
    do: meter_copy(s, e, [2, 2, 0], meter)

  defp call(e, {DBConnection, :past_event, 3}, [meter, name, time], s) do
    expected =
      case name do
        :checkin -> Map.fetch(s.last_checkin, e.role)
        :checkout -> Map.fetch(s.db_checkout, e.role)
      end

    meter_copy(s, e, [2, 2, 0], meter)
    |> check(e, [2, 2, 2], time, expected, {:past_event_source, name})
  end

  defp call(e, {DBConnection, :log, 5}, [meter, _call, _query, _params, _result], s),
    do: meter_copy(s, e, [2, 2, 0], meter)

  defp call(e, {DBConnection, :log, 4}, [result, _call, _query, _params], s) do
    if is_tuple(result),
      do:
        meter_copy(s, e, [2, 2, 0, tuple_size(result) - 1], elem(result, tuple_size(result) - 1)),
      else: s
  end

  defp call(e, {DBConnection.LogEntry, :new, 5}, [_call, _query, _params, times, _result], s),
    do: times_copy(s, e, [2, 2, 3], times)

  defp call(e, {DBConnection, :log, 2}, [_logger, entry], s),
    do: mark_entry(s, e, [2, 2, 1], entry)

  defp call(e, {DBConnection.Holder, :checkout, 3}, [_pool, _callers, opts], s) do
    put_in(s.checkout[e.role], %{opts: opts})
  end

  defp call(e, {DBConnection.Holder, :checkout, 5}, [_pool, _callers, _queue, now, deadline], s) do
    {expected_now, _} = read(s, e.role, {:monotonic_time, 1000})
    opts = Map.fetch!(s.checkout, e.role).opts
    timeout = Keyword.get(opts, :timeout, 15_000)

    expected_deadline =
      if timeout == :infinity,
        do: Keyword.get(opts, :deadline),
        else: min(expected_now + timeout, Keyword.get(opts, :deadline))

    s =
      check(s, e, [2, 2, 3], now, {:ok, expected_now}, :checkout_start)
      |> check(e, [2, 2, 4], deadline, {:ok, expected_deadline}, :checkout_deadline)

    put_in(s.checkout[e.role], %{opts: opts, start: expected_now, deadline: expected_deadline})
  end

  defp call(e, {AshOnetime.Admission, :duration, 1}, [started], s) do
    expected = started(s, e.pid)
    check(s, e, [2, 2, 0], started, expected, :duration_start)
  end

  defp call(e, {AshOnetime.ExternalRecovery, :emit, 3}, [_state, actual, _class], s) do
    check(
      s,
      e,
      [2, 2, 1],
      actual,
      started(s, e.pid, AshOnetime.ExternalRecovery),
      :external_start
    )
  end

  defp call(e, {AshOnetime.Telemetry, function, _}, [duration | _], s)
       when function in [:admission, :verification, :encoding, :replay, :external_recovery] do
    expected =
      cond do
        function == :external_recovery and Map.has_key?(s.outcome_workers, e.pid) ->
          {stop, _} = read(s, e.role, {:monotonic_time, :native})
          {:ok, stop - Map.fetch!(s.outcome_workers, e.pid)}

        function == :external_recovery ->
          with {:ok, start} <- started(s, e.pid, AshOnetime.ExternalRecovery) do
            {stop, _} = read(s, e.role, {:monotonic_time, :native})
            {:ok, stop - start}
          end

        true ->
          Map.fetch(s.durations, e.role)
      end

    s = check(s, e, [2, 2, 0], duration, expected, {:package_duration, function})

    put_in(
      s.durations[e.role],
      if(match?({:ok, _}, expected), do: elem(expected, 1), else: :missing)
    )
  end

  defp call(e, {:telemetry, :execute, 3}, [name, measurements, metadata], s) do
    {expected, s} = measurements(e, name, measurements, metadata, s)
    s = mark_fields(s, e, [2, 2, 1], measurements, expected, {:telemetry, name})
    put_in(s.telemetry[e.role], expected)
  end

  defp call(e, {:telemetry, :do_execute, 4}, [_handlers, _name, measurements, _metadata], s),
    do:
      mark_fields(
        s,
        e,
        [2, 2, 2],
        measurements,
        Map.get(s.telemetry, e.role, %{}),
        :telemetry_copy
      )

  defp call(e, {Ecto.Adapters.SQL, :log, 5}, [_context, _stack, _params, entry, _opts], s),
    do: mark_entry(s, e, [2, 2, 3], entry)

  defp call(e, {AshOnetime.Telemetry, :emit, 6}, [_name, measurements | _], s) do
    if Map.has_key?(measurements, :duration),
      do:
        check(
          s,
          e,
          [2, 2, 1, :duration],
          measurements.duration,
          Map.fetch(s.durations, e.role),
          :package_duration_copy
        ),
      else: s
  end

  defp call(e, {AshOnetime.Telemetry, :validate_measurements, 2}, [_name, measurements], s) do
    if Map.has_key?(measurements, :duration),
      do:
        check(
          s,
          e,
          [2, 2, 1, :duration],
          measurements.duration,
          Map.fetch(s.durations, e.role),
          :package_duration_copy
        ),
      else: s
  end

  defp call(e, {AshOnetime.ExternalRecovery, function, _}, args, s) do
    index =
      %{
        continue: 4,
        lock_for_peer: 2,
        recover_processing: 5,
        execute_then_settle: 5,
        settle_unknown_execute: 5,
        ambiguous_recovery: 2,
        publish_outcome: 4,
        finalize: 4,
        lock_replay: 2,
        resolve_finalization_claim: 2
      }[function]

    if index == nil,
      do: s,
      else:
        check(
          s,
          e,
          [2, 2, index],
          Enum.at(args, index),
          started(s, e.pid, AshOnetime.ExternalRecovery),
          :external_start_copy
        )
  end

  defp call(e, {AshOnetime.Admission, function, 5}, args, s)
       when function in [:resolve, :decide] do
    check(s, e, [2, 2, 3], Enum.at(args, 3), started(s, e.pid), :admission_start_copy)
  end

  defp call(e, {AshOnetime.Admission, :replay, 3}, [_result, _state, at], s),
    do: check(s, e, [2, 2, 2], at, started(s, e.pid), :admission_start_copy)

  defp call(e, {AshOnetime.Admission, :emit_admission, 3}, [_state, at, _outcome], s),
    do: check(s, e, [2, 2, 1], at, started(s, e.pid), :admission_start_copy)

  defp call(e, {AshOnetime.Admission, :emit_replay, 3}, [_state, at, _outcome], s),
    do: check(s, e, [2, 2, 1], at, Map.fetch(s.durations, e.role), :replay_duration_copy)

  defp call(
         e,
         {AshOnetime.Admission, :persist_completion, 4},
         [_state, _encoded, at, _reference],
         s
       ),
       do: check(s, e, [2, 2, 2], at, started(s, e.pid), :encoding_start_copy)

  defp call(e, {AshOnetime.Admission, :emit_encoding, 3}, [_state, duration, _class], s),
    do: check(s, e, [2, 2, 1], duration, Map.fetch(s.durations, e.role), :encoding_duration_copy)

  defp call(e, {AshOnetime.Cache, :persist, 4}, [_config, key, _entry, ttl], s) do
    expected = Map.fetch(s.ttls, e.role)
    s = check(s, e, [2, 2, 3], ttl, expected, :cache_ttl_copy)

    case expected do
      {:ok, expected} -> put_in(s.cache_ttls[key], expected)
      :error -> s
    end
  end

  defp call(e, {AshOnetime.Cache, function, 3}, [_config_or_module, :put, [key, _entry, ttl]], s)
       when function in [:invoke, :safe_apply],
       do: check(s, e, [2, 2, 2, 2], ttl, Map.fetch(s.cache_ttls, key), :cache_ttl_copy)

  defp call(
         e,
         {AshOnetime.Cache, :"-invoke/3-fun-0-", 3},
         [:put, [key, _entry, ttl], _module],
         s
       ),
       do: check(s, e, [2, 2, 1, 2], ttl, Map.fetch(s.cache_ttls, key), :cache_ttl_copy)

  defp call(e, {AshOnetime.Cache.Ets, :put, 3}, [key, _entry, ttl], s),
    do: check(s, e, [2, 2, 2], ttl, Map.fetch(s.cache_ttls, key), :cache_ttl_copy)

  defp call(
         e,
         {AshOnetime.Cache.Ets, :handle_call, 3},
         [{:put, key, _entry, ttl}, _from, _state],
         s
       ) do
    s = check(s, e, [2, 2, 0, 3], ttl, Map.fetch(s.cache_ttls, key), :cache_ttl_copy)
    put_in(s.cache_calls[e.role], key)
  end

  defp call(e, {AshOnetime.Store.Postgres, function, _}, args, s) do
    index =
      case function do
        :report_abandoned_outcome -> {:ok, 2}
        :report_outcome_failure -> {:ok, 1}
        _ -> outcome_capture(function)
      end

    case index do
      {:ok, n} ->
        check(s, e, [2, 2, n], Enum.at(args, n), outcome_start(s, e.pid), :outcome_start_copy)

      :not_called ->
        s
    end
  end

  defp call(_e, _mfa, _args, s), do: s

  defp returned(e, mfa, _frame, value, s)
       when mfa in [
              {:erlang, :monotonic_time, 0},
              {:erlang, :monotonic_time, 1},
              {:erlang, :system_time, 0},
              {:erlang, :system_time, 1},
              {System, :os_time, 0},
              {System, :os_time, 1},
              {System, :monotonic_time, 0},
              {System, :monotonic_time, 1},
              {System, :system_time, 0},
              {System, :system_time, 1},
              {:os, :system_time, 0},
              {:os, :system_time, 1}
            ] do
    frame = hd(Map.get(s.active, e.pid))
    {_module, function, _arity} = mfa

    unit =
      case frame.args do
        [] -> :native
        [unit] -> unit
      end

    kind = if elem(mfa, 0) == :os and function == :system_time, do: :os_time, else: function
    key = {e.role, {kind, unit}}
    s = put_in(s.reads[key], {value, e.index})

    s =
      if kind == :monotonic_time and unit == :native and s.db_checkout[e.role] == :awaiting_clock,
        do: put_in(s.db_checkout[e.role], value),
        else: s

    active =
      Enum.map(Map.get(s.active, e.pid), fn f ->
        if f.mfa in @starters and f.started == nil and function == :monotonic_time and
             unit == :native, do: %{f | started: value}, else: f
      end)

    s = put_in(s.active[e.pid], active)
    slot(s, e.index, [3], value, {:read, function, unit})
  end

  defp returned(e, {DateTime, :utc_now, _}, _frame, value, s) do
    # utc_now reads the VM's system clock in native units through System.
    {time, _} = read(s, e.role, {:os_time, :native})
    expected = DateTime.from_unix!(time, :native)
    s = check(s, e, [3], value, {:ok, expected}, :utc_now)
    put_in(s.reads[{e.role, :utc_now}], {expected, e.index})
  end

  defp returned(e, {AshOnetime.Admission, :duration, 1}, _frame, value, s) do
    expected =
      with {:ok, start} <- started(s, e.pid) do
        {stop, _} = read(s, e.role, {:monotonic_time, :native})
        {:ok, stop - start}
      end

    s = check(s, e, [3], value, expected, :duration)

    put_in(
      s.durations[e.role],
      if(match?({:ok, _}, expected), do: elem(expected, 1), else: :missing)
    )
  end

  defp returned(e, {DBConnection.LogEntry, :new, 5}, frame, entry, s) do
    [_call, _query, _params, times, _result] = frame.args
    {stop, _} = read(s, e.role, {:monotonic_time, :native})

    {_stop, fields} =
      Enum.reduce(times, {stop, %{}}, fn
        {:decode, start}, {stop, fields} ->
          {start, Map.put(fields, :decode_time, stop - start)}

        {:checkout, start}, {stop, fields} ->
          {start, Map.put(fields, :pool_time, stop - start)}

        {:checkin, start}, {stop, fields} ->
          {stop, Map.put(fields, :idle_time, max(stop - start, 0))}

        {_event, start}, {stop, fields} ->
          {start, Map.update(fields, :connection_time, stop - start, &(&1 + stop - start))}
      end)

    s = put_in(s.entries[e.role], fields)
    mark_entry(s, e, [3], entry)
  end

  defp returned(e, {DBConnection, :event, 2}, frame, value, s) do
    case frame.args do
      [nil, _] ->
        s

      [{log, times}, name] ->
        {now, _} = read(s, e.role, {:monotonic_time, :native})
        expected = {log, [{name, now} | times]}
        s = if value === expected, do: s, else: failure(s, e, :meter_event, value, expected)
        put_in(s.meters[e.role], expected) |> meter(e, [3], elem(expected, 1))
    end
  end

  defp returned(e, {DBConnection, :past_event, 3}, frame, value, s) do
    case frame.args do
      [{log, times}, name, time] when time != nil ->
        expected = {log, [{name, time} | times]}
        s = if value === expected, do: s, else: failure(s, e, :past_event, value, expected)
        put_in(s.meters[e.role], expected) |> meter(e, [3], elem(expected, 1))

      _ ->
        s
    end
  end

  defp returned(
         e,
         {DBConnection.Holder, :checkout, arity},
         _frame,
         {:ok, _pool_ref, _mod, checkin, _protocol},
         s
       )
       when arity in [3, 5] do
    meter_path = [3, 3]
    # The check-in value is the one carried by the pool's ETS transfer.
    holder = elem(elem(e.event, 3), 1) |> elem(4)
    expected = Map.fetch(s.holder_clocks, holder)
    s = check(s, e, meter_path, checkin, expected, :pool_checkin)
    if match?({:ok, _}, expected), do: put_in(s.last_checkin[e.role], elem(expected, 1)), else: s
  end

  defp returned(e, {DBConnection, :meter, 1}, frame, value, s) do
    [opts] = frame.args

    expected =
      case Keyword.get(opts, :log) do
        nil -> nil
        log -> {log, []}
      end

    s = if value === expected, do: s, else: failure(s, e, :meter_source, value, expected)
    put_in(s.meters[e.role], expected)
  end

  defp returned(e, {DBConnection, :checkout, 3}, _frame, {:ok, _conn, meter}, s),
    do: meter_copy(s, e, [3, 2], meter)

  defp returned(e, {AshOnetime.Cache, :ttl_seconds, 1}, frame, value, s) do
    [%{response_retain_until: until}] = frame.args
    {now, _} = read(s, e.role, :utc_now)
    expected = DateTime.diff(until, now, :second)
    check(s, e, [3], value, {:ok, expected}, :cache_ttl) |> put_in([:ttls, e.role], expected)
  end

  defp returned(
         e,
         {AshOnetime.Telemetry, :validate_measurements, 2},
         _frame,
         {:ok, %{duration: actual}},
         s
       ),
       do:
         check(
           s,
           e,
           [3, 1, :duration],
           actual,
           Map.fetch(s.durations, e.role),
           :package_duration_copy
         )

  defp returned(
         e,
         {:ets, :lookup, 2},
         %{args: [table, :conn]},
         [{:conn, _, _, _, _, at, _, _}],
         s
       ) do
    case Map.fetch(s.connected, table) do
      {:ok, expected} -> check(s, e, [3, 0, 5], at, {:ok, expected}, :connected_at)
      :error -> s
    end
  end

  defp returned(
         e,
         {:ets, :lookup, 2},
         %{args: [AshOnetime.Cache.Ets, key]},
         [{key, _entry, expiry}],
         s
       ) do
    check(s, e, [3, 0, 2], expiry, Map.fetch(s.cache_expiries, key), :cache_expiry_copy)
  end

  defp returned(_e, _mfa, _frame, _value, s), do: s

  defp measurements(e, name, actual, metadata, s) do
    cond do
      hd(name) == :ash and List.last(name) == :start ->
        {now, _} = read(s, e.role, {:monotonic_time, :native})
        {wall, _} = read(s, e.role, {:system_time, :native})
        key = {e.role, Enum.drop(name, -1)}
        {%{system_time: wall}, put_in(s.spans[key], [now | Map.get(s.spans, key, [])])}

      hd(name) == :ash and List.last(name) == :stop ->
        {now, _} = read(s, e.role, {:monotonic_time, :native})
        {wall, _} = read(s, e.role, {:system_time, :native})
        key = {e.role, Enum.drop(name, -1)}
        [start | rest] = Map.fetch!(s.spans, key)
        {%{system_time: wall, duration: now - start}, put_in(s.spans[key], rest)}

      Enum.take(name, -1) == [:start] ->
        {now, _} = read(s, e.role, {:monotonic_time, :native})
        {wall, _} = read(s, e.role, {:system_time, :native})
        key = {e.role, Enum.drop(name, -1), Map.get(metadata, :telemetry_span_context)}
        {%{monotonic_time: now, system_time: wall}, put_in(s.spans[key], now)}

      Enum.take(name, -1) in [[:stop], [:exception]] ->
        {now, _} = read(s, e.role, {:monotonic_time, :native})
        key = {e.role, Enum.drop(name, -1), Map.get(metadata, :telemetry_span_context)}
        {%{monotonic_time: now, duration: now - Map.fetch!(s.spans, key)}, s}

      Map.has_key?(actual, :total_time) ->
        entry = Map.get(s.entries, e.role, %{})

        fields =
          for {source, target} <- [
                connection_time: :query_time,
                decode_time: :decode_time,
                pool_time: :queue_time,
                idle_time: :idle_time
              ],
              Map.has_key?(entry, source),
              into: %{},
              do: {target, entry[source]}

        total =
          Enum.sum(
            for key <- [:query_time, :decode_time, :queue_time],
                Map.has_key?(fields, key),
                do: fields[key]
          )

        {Map.put(fields, :total_time, total), s}

      Map.has_key?(actual, :duration) ->
        {%{duration: Map.get(s.durations, e.role, :missing)}, s}

      Map.has_key?(actual, :system_time) ->
        {wall, _} = read(s, e.role, {:system_time, :native})
        {%{system_time: wall}, s}

      true ->
        {%{}, s}
    end
  end

  defp exits(
         %{event: {_, :call, {:ets, :give_away, [holder, _pool, {:checkin, _ref, at}]}}} = e,
         s
       ) do
    {now, _} = read(s, e.role, {:monotonic_time, :native})
    s = check(s, e, [2, 2, 2, 2], at, {:ok, now}, :pool_checkin_write)
    put_in(s.holder_clocks[holder], now)
  end

  defp exits(
         %{
           event:
             {_, :call,
              {:erlang, :start_timer,
               [deadline, _pool, {_ref, _holder, _caller, timeout}, [abs: true]]}}
         } = e,
         s
       ) do
    c = Map.fetch!(s.checkout, e.role)

    s
    |> check(e, [2, 2, 0], deadline, {:ok, c.deadline}, :checkout_deadline)
    |> check(e, [2, 2, 2, 3], timeout, {:ok, c.deadline - c.start}, :checkout_timeout)
  end

  defp exits(
         %{event: {_, :send, {:db_connection, _from, {:checkout, _callers, start, _queue}}, _to}} =
           e,
         s
       ),
       do: check(s, e, [2, 2, 2], start, {:ok, s.checkout[e.role].start}, :checkout_start)

  defp exits(
         %{
           event:
             {_, :return_from, {:erlang, :send, 2},
              {:db_connection, _from, {:checkout, _callers, start, _queue}}}
         } = e,
         s
       ),
       do: check(s, e, [3, 2, 2], start, {:ok, s.checkout[e.role].start}, :checkout_start)

  defp exits(
         %{
           event:
             {_, :call,
              {:erlang, :send,
               [_to, {:db_connection, _from, {:checkout, _callers, start, _queue}}]}}
         } = e,
         s
       ),
       do: check(s, e, [2, 2, 1, 2, 2], start, {:ok, s.checkout[e.role].start}, :checkout_start)

  defp exits(e, s), do: cache_copies(e.event, [], e, s)

  defp cache_copies({:"$gen_call", from, {:put, key, entry, ttl}}, path, e, s) do
    s = check(s, e, path ++ [2, 3], ttl, Map.fetch(s.cache_ttls, key), :cache_ttl_message)
    cache_copies({from, entry}, path ++ [:rest], e, s)
  end

  defp cache_copies({:ets, :insert, [AshOnetime.Cache.Ets, {key, _entry, expiry}]}, path, e, s) do
    {now, _} = read(s, e.role, {:monotonic_time, :second})
    expected = with {:ok, ttl} <- Map.fetch(s.cache_ttls, key), do: {:ok, now + ttl}
    s = check(s, e, path ++ [2, 1, 2], expiry, expected, :cache_expiry)

    case expected do
      {:ok, value} -> put_in(s.cache_expiries[key], value)
      :error -> s
    end
  end

  defp cache_copies(value, path, e, s) when is_function(value) do
    info = Map.new(Function.info(value))

    if info.module == AshOnetime.Cache and info.name == :"-invoke/3-fun-0-" do
      case info.env do
        [:put, [key, _entry, ttl], _module] ->
          check(
            s,
            e,
            path ++ [:function, :env, 1, 2],
            ttl,
            Map.fetch(s.cache_ttls, key),
            :cache_ttl_closure
          )

        _ ->
          s
      end
    else
      s =
        if info.module == AshOnetime.Store.Postgres do
          case outcome_capture(info.name) do
            {:ok, n} ->
              check(
                s,
                e,
                path ++ [:function, :env, n],
                Enum.at(info.env, n),
                outcome_start(s, e.pid),
                :outcome_start_closure
              )

            :not_called ->
              s
          end
        else
          s
        end

      cache_copies(info.env, path ++ [:function, :env], e, s)
    end
  end

  defp cache_copies(value, path, e, s) when is_map(value),
    do:
      Enum.reduce(Map.to_list(value), s, fn {key, v}, acc ->
        cache_copies(v, path ++ [key], e, acc)
      end)

  defp cache_copies(value, path, e, s) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce(s, fn {v, n}, acc -> cache_copies(v, path ++ [n], e, acc) end)

  defp cache_copies(value, path, e, s) when is_list(value), do: cache_list(value, path, e, s, 0)
  defp cache_copies(_, _, _, s), do: s
  defp cache_list([], _, _, s, _), do: s

  defp cache_list([h | t], path, e, s, n),
    do: cache_list(t, path, e, cache_copies(h, path ++ [n], e, s), n + 1)

  defp cache_list(t, path, e, s, n), do: cache_copies(t, path ++ [n], e, s)

  defp meter_copy(s, _e, _path, nil), do: s

  defp meter_copy(s, e, path, {_log, times} = actual) do
    expected = Map.get(s.meters, e.role, :missing_meter)
    s = if actual === expected, do: s, else: failure(s, e, {:meter_copy, path}, actual, expected)

    case expected do
      {_, expected_times} when times === expected_times -> meter(s, e, path, expected_times)
      _ -> s
    end
  end

  defp meter_copy(s, e, path, actual), do: failure(s, e, {:meter_copy, path}, actual, :meter)

  defp times_copy(s, e, path, actual) do
    case Map.get(s.meters, e.role) do
      {_, expected} ->
        s =
          if actual === expected,
            do: s,
            else: failure(s, e, {:times_copy, path}, actual, expected)

        Enum.with_index(expected)
        |> Enum.reduce(s, fn {{name, time}, n}, acc ->
          check(
            acc,
            e,
            path ++ [n, 1],
            Enum.at(actual, n) |> elem(1),
            {:ok, time},
            {:meter, name, n}
          )
        end)

      _ ->
        s
    end
  end

  defp mark_entry(s, e, path, entry) do
    fields = Map.get(s.entries, e.role, %{})

    Enum.reduce([:pool_time, :connection_time, :decode_time, :idle_time], s, fn field, acc ->
      check(
        acc,
        e,
        path ++ [field],
        Map.get(entry, field),
        {:ok, Map.get(fields, field)},
        {:log_entry, field}
      )
    end)
  end

  defp meter(s, e, path, times) do
    Enum.with_index(times)
    |> Enum.reduce(s, fn {{name, time}, n}, acc ->
      slot(acc, e.index, path ++ [1, n, 1], time, {:meter, name, n})
    end)
  end

  defp mark_fields(s, e, path, actual, expected, token) do
    Enum.reduce(expected, s, fn {field, value}, acc ->
      check(acc, e, path ++ [field], Map.get(actual, field), {:ok, value}, {token, field})
    end)
  end

  defp outcome_capture(function) do
    if String.starts_with?(Atom.to_string(function), "-record_outcome_committed/4-fun-") do
      AshOnetime.Test.ExitBoundary.Compiled.captured_argument(
        AshOnetime.Store.Postgres,
        function,
        :report_abandoned_outcome,
        4,
        2
      )
    else
      :not_called
    end
  end

  defp outcome_start(s, pid) do
    case Map.fetch(s.outcome_workers, pid) do
      {:ok, _} = source ->
        source

      :error ->
        Enum.find_value(Map.get(s.active, pid, []), :error, fn frame ->
          if frame.mfa == {AshOnetime.Store.Postgres, :record_outcome_committed, 4} and
               frame.started != nil,
             do: {:ok, frame.started}
        end)
    end
  end

  defp started(s, pid, module \\ nil) do
    Enum.find_value(Map.get(s.active, pid, []), :error, fn frame ->
      if frame.started != nil and (module == nil or elem(frame.mfa, 0) == module),
        do: {:ok, frame.started}
    end)
  end

  defp read(s, role, kind), do: Map.fetch!(s.reads, {role, kind})

  defp check(s, e, path, actual, {:ok, expected}, token) do
    if actual === expected,
      do: slot(s, e.index, path, expected, token),
      else: failure(s, e, {token, path}, actual, expected)
  end

  defp check(s, e, path, actual, :error, token),
    do: failure(s, e, {token, path}, actual, :missing_origin)

  defp slot(s, index, path, expected, token),
    do: put_in(s.slots[{index, path}], {expected, token})

  defp failure(s, e, rule, actual, expected),
    do: %{
      s
      | errors: [
          %{
            rule: rule,
            index: e.index,
            at: Map.take(e, [:mfa, :role, :stack]),
            expected: expected,
            actual: actual
          }
          | s.errors
        ]
    }

  defp pop(map, key) do
    case Map.get(map, key, []) do
      [head | rest] -> {head, Map.put(map, key, rest)}
      [] -> {nil, map}
    end
  end
end
