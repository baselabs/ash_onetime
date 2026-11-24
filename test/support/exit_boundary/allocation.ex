defmodule AshOnetime.Test.ExitBoundary.Allocation do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.{
    Capture,
    Compiled,
    ConnectionHistory,
    Historical,
    NativeTransport,
    Origins,
    References,
    Registry,
    Root,
    Scenarios
  }

  alias AshOnetime.Test.Repo

  @checkpoint {Scenarios, :allocation_checkpoint, 0}
  @literal {Scenarios, :"-allocation_checkpoint/0-fun-0-", 0}

  # All main-pool leases participate, including those before and after OPEN.
  # The same accumulated bijection binds each occurrence; it is never reset at
  # a checkin. This makes a later reuse of another holder a real conflict.
  def pair(pairing, run, twin, ri, ti) do
    run = Map.put_new_lazy(run, :connection_history, fn -> ConnectionHistory.build(run) end)
    twin = Map.put_new_lazy(twin, :connection_history, fn -> ConnectionHistory.build(twin) end)
    left = leases(run, ri)
    right = leases(twin, ti)
    roles = Enum.uniq(Enum.map(left ++ right, & &1.role))

    {errors, paired} =
      Enum.reduce(roles, {[], []}, fn role, {errors, pairs} ->
        a = Enum.filter(left, &(&1.role == role))
        b = Enum.filter(right, &(&1.role == role))

        errors =
          if length(a) == length(b),
            do: errors,
            else: [difference(nil, :allocation_multiplicity, length(a), length(b)) | errors]

        {errors, pairs ++ Enum.zip(a, b)}
      end)

    pairing = bind_pairs(pairing, paired)

    # Native program order, spawn and uniquely owned send/receive edges provide
    # the partial order. Sorted timestamps provide no cross-process edge here.
    rc = causal(run.connection_history.program_events, left)
    tc = causal(twin.connection_history.program_events, right)

    order_errors =
      for {a, b} <- paired,
          {c, d} <- paired,
          a != c,
          from <- [:acquired, :giveaway],
          to <- [:acquired, :giveaway],
          before?(rc, a[from], c[to]) != before?(tc, b[from], d[to]),
          do:
            difference(
              a,
              :allocation_happens_before,
              {from, a.ordinal, to, c.ordinal, before?(rc, a[from], c[to])},
              {from, b.ordinal, to, d.ordinal, before?(tc, b[from], d[to])}
            )

    %{
      pairing: pairing,
      errors:
        errors ++
          order_errors ++
          errors_for_leases(left ++ right) ++
          joined_borrowers(left, rc) ++ joined_borrowers(right, tc),
      leases: {left, right}
    }
  end

  # The observation self-test supplies whole, independent native captures. The
  # lease parser and the accumulated map below are the ones used by pair/5.
  def captured_pairs(captures) do
    histories =
      Enum.map(captures, fn {run, twin} ->
        {run, twin, ConnectionHistory.build(run), ConnectionHistory.build(twin)}
      end)

    errors =
      for {_run, _twin, left, right} <- histories,
          proof <- [left, right],
          error <- proof.errors,
          do: {:allocation_raw_history, error}

    if errors == [] do
      pairs =
        Enum.map(histories, fn {run, twin, left, right} ->
          [a] = leases(Map.put(run, :connection_history, left), Origins.build(run))
          [b] = leases(Map.put(twin, :connection_history, right), Origins.build(twin))
          {a, b}
        end)

      bind_pairs(%{forward: %{}, reverse: %{}, errors: []}, pairs)
    else
      %{forward: %{}, reverse: %{}, errors: errors}
    end
  end

  defp bind_pairs(initial, pairs) do
    Enum.reduce(pairs, initial, fn {a, b}, acc ->
      bind_lease(acc, a, b)
    end)
  end

  defp bind_lease(pairing, a, b) do
    pairing =
      Enum.reduce(
        [:pool, :queue, :timer, :holder, :lock, :conn_ref, :port, :owner],
        pairing,
        fn key, acc ->
          Origins.bind(
            acc,
            Map.fetch!(a, key),
            Map.fetch!(b, key),
            {:allocation, a.role, a.ordinal, key, a.acquired, b.acquired}
          )
        end
      )

    Origins.bind(
      pairing,
      {:postgres_backend, a.backend},
      {:postgres_backend, b.backend},
      {:allocation, a.role, a.ordinal, :backend, a.acquired, b.acquired}
    )
  end

  def leases(side, indexed) do
    pool = side.historical.repo_metadata.pid
    history = Map.get_lazy(side, :connection_history, fn -> ConnectionHistory.build(side) end)

    unless history.errors == [], do: raise("allocation requires the whole valid raw history")

    # Rendering may change qualified field copies and consume native transport
    # instructions. Lease facts still come from the original complete program;
    # only the already-established structural role comes from Origins.
    before = Map.get(side.historical, :event_offset, 0)
    events = Enum.filter(history.program_events, &(&1.index >= before))

    events
    |> Enum.flat_map(fn
      %{
        event:
          {caller, :return_from, {DBConnection.Holder, :checkout, 3},
           {:ok, {:pool_ref, ^pool, queue, timer, holder, lock} = ref, Postgrex.Protocol, _,
            protocol}}
      } = source ->
        source = Map.put(source, :role, Map.fetch!(indexed.roles, caller))
        terminal = lease_terminal(history.native.pairs, source, ref, pool, queue, holder)

        conn_ref =
          Enum.find_value(events, fn
            %{
              index: n,
              event:
                {^caller, :return_from, {DBConnection, :checkout, 3},
                 {:ok, %DBConnection{pool_ref: ^ref, conn_ref: value}, _}}
            }
            when n > source.index ->
              value

            _ ->
              nil
          end)

        {owner, port} = lease_origin(history, source, holder, pool, protocol)

        [
          %{
            role: source.role,
            source: source,
            acquired: source.index,
            terminal: if(terminal, do: terminal.kind),
            terminal_source: if(terminal, do: terminal.source.index),
            terminal_return: if(terminal, do: terminal.returned.index),
            checkin: if(terminal && terminal.kind == :checkin, do: terminal.source.index),
            giveaway: if(terminal, do: terminal.giveaway.index),
            pool: pool,
            queue: queue,
            timer: timer,
            holder: holder,
            lock: lock,
            conn_ref: conn_ref,
            owner: owner,
            backend: protocol.connection_id,
            port: port
          }
        ]

      _ ->
        []
    end)
    |> Enum.map_reduce(%{}, fn lease, counts ->
      ordinal = Map.get(counts, lease.role, 0)
      {Map.put(lease, :ordinal, ordinal), Map.put(counts, lease.role, ordinal + 1)}
    end)
    |> elem(0)
  end

  # A successful native handoff ends the lease. Holder.checkin/1 can still be
  # called after disconnect/stop, when the caller no longer owns the table;
  # that later cleanup must not replace the handoff that actually occurred.
  defp lease_terminal(pairs, source, ref, pool, queue, holder) do
    caller = source.pid

    terminals =
      for {_, giveaway} <- pairs,
          giveaway.source.index > source.index,
          {^caller, :call, {:ets, :give_away, [^holder, ^pool, {kind, ^queue, _}]}} <-
            [giveaway.source.event],
          kind in [:checkin, :disconnect, :stop],
          giveaway.returned.event === {caller, :return_from, {:ets, :give_away, 3}, true},
          {_, terminal} <- pairs,
          terminal.source.index > source.index,
          terminal.source.index < giveaway.source.index,
          giveaway.returned.index < terminal.returned.index,
          {^caller, :call, {DBConnection.Holder, ^kind, [^ref | rest]}} <-
            [terminal.source.event],
          arity = if(kind == :checkin, do: 1, else: 2),
          length(rest) == arity - 1,
          terminal.returned.event ===
            {caller, :return_from, {DBConnection.Holder, kind, arity}, :ok},
          do: %{
            kind: kind,
            source: terminal.source,
            returned: terminal.returned,
            giveaway: giveaway.source
          }

    Enum.min_by(terminals, & &1.giveaway.index, fn -> nil end)
  end

  # A lease can acquire a holder born after arming. Resolve its owner and
  # physical connection from that holder's validated native creation and the
  # last committed row at this occurrence, never from a later live ETS read.
  defp lease_origin(history, source, holder, pool, protocol) do
    origin = Map.fetch!(history.states.holder_origins, holder)

    commit =
      history.states.commits
      |> Enum.filter(&(&1.holder == holder and &1.index < source.index))
      |> Enum.max_by(& &1.index)

    {:conn, owner, Postgrex.Protocol, committed, _lock, _clock, _deadline, _status} = commit.row
    port = NativeTransport.physical_port(history.native, protocol.sock)

    unless Map.get(origin, :holder_origin_index, -1) < source.index and
             origin.owner == owner and origin.pool == pool and origin.port == port and
             committed === protocol,
           do: raise("the native lease does not match its holder origin and committed row")

    {owner, port}
  end

  defp errors_for_leases(leases) do
    for lease <- leases,
        lease.terminal_source == nil or lease.terminal_return == nil or lease.giveaway == nil,
        do: difference(lease, :allocation_terminal, :missing, :same_reference_native_handoff)
  end

  defp difference(nil, rule, actual, expected),
    do: %{at: nil, rule: rule, path: [], run: actual, twin: expected}

  defp difference(lease, rule, actual, expected),
    do: %{
      at: Map.take(lease.source, [:role, :mfa, :stack]) |> Map.put(:run_index, lease.acquired),
      rule: rule,
      path: [],
      run: actual,
      twin: expected
    }

  defp joined_borrowers(leases, clocks) do
    for parent <- leases,
        parent.role == :caller,
        child <- leases,
        match?({:spawned, :caller, _}, child.role),
        parent.giveaway != nil,
        parent.acquired < child.acquired and child.acquired < parent.giveaway,
        not before?(clocks, child.giveaway, parent.giveaway),
        do:
          difference(
            child,
            :allocation_borrower_join,
            :no_causal_checkin_order,
            :child_checkin_before_parent_checkin
          )
  end

  defp causal(events, leases) do
    targets = MapSet.new(Enum.flat_map(leases, &[&1.acquired, &1.giveaway]))
    sends = for %{event: {_, :send, message, to}} <- events, is_pid(to), do: {to, message}
    unique = Enum.frequencies(sends)
    receipts = for %{event: {pid, :receive, message}} <- events, do: {pid, message}
    received = Enum.frequencies(receipts)

    {_, _, result} =
      Enum.reduce(
        Enum.sort_by(events, & &1.index),
        {%{}, %{}, %{}},
        &causal_event(&1, &2, targets, unique, received)
      )

    result
  end

  defp causal_event(e, {actors, sent, result}, targets, unique, received) do
    clock = receive_clock(e.event, Map.get(actors, e.pid, %{}), sent, unique, received)
    clock = Map.put(clock, e.pid, e.index)
    actors = Map.put(actors, e.pid, clock)
    {actors, sent} = send_clock(e.event, actors, sent, clock)

    result =
      if MapSet.member?(targets, e.index),
        do: Map.put(result, e.index, {e.pid, clock}),
        else: result

    {actors, sent, result}
  end

  defp receive_clock({pid, :receive, message}, clock, sent, unique, received) do
    if unique[{pid, message}] == 1 and received[{pid, message}] == 1,
      do: merge_clock(clock, Map.get(sent, {pid, message}, %{})),
      else: clock
  end

  defp receive_clock(_event, clock, _sent, _unique, _received), do: clock

  defp send_clock({_, :send, message, to}, actors, sent, clock) when is_pid(to),
    do: {actors, Map.put(sent, {to, message}, clock)}

  defp send_clock({_, :spawn, child, _}, actors, sent, clock),
    do: {Map.update(actors, child, clock, &merge_clock(&1, clock)), sent}

  defp send_clock(_event, actors, sent, _clock), do: {actors, sent}

  defp merge_clock(a, b), do: Map.merge(a, b, fn _, x, y -> max(x, y) end)
  defp before?(_clocks, nil, _), do: false
  defp before?(_clocks, _, nil), do: false

  defp before?(clocks, a, b) do
    {pid, _} = Map.fetch!(clocks, a)
    {_, clock} = Map.fetch!(clocks, b)
    Map.get(clock, pid, -1) >= a
  end

  # A closed caller program, grounded in DBConnection 2.10.2 Holder's protocol.
  # No stack/region selects an effect: each claimed event is consumed by one
  # instruction below, with its complete payload and exact native stack checked.
  def check(side, indexed) do
    caller = side.run.snapshot.root
    events = Enum.filter(indexed.events, &(&1.pid == caller))

    starts =
      Enum.filter(
        events,
        &match?(%{event: {_, :call, {Scenarios, :allocation_checkpoint, []}}}, &1)
      )

    eligible? = Registry.allocation_checkpoint?(side.row)

    initial = %{
      events: events,
      stack: [{Root, :invoke, 2}],
      claimed: [],
      errors: [],
      lease: nil
    }

    checked =
      try do
        ensure(
          initial,
          hd(events),
          :checkpoint_count,
          length(starts),
          if(eligible?, do: 1, else: 0)
        )

        case starts do
          [] ->
            initial

          [start] ->
            {before, tail} = Enum.split_while(events, &(&1.index != start.index))
            previous = List.last(before)

            ash =
              %{create: :create, update: :update, destroy: :destroy, action: :run_action}[
                side.row.type
              ]

            ensure(
              initial,
              start,
              :checkpoint_placement,
              match?(%{event: {^caller, :return_from, {Ash, ^ash, 2}, _}}, previous),
              true
            )

            %{initial | events: tail} |> program(side, indexed)
        end
      catch
        {:allocation, error} -> %{initial | errors: [error]}
      end

    %{checked | claimed: MapSet.new(checked.claimed)}
  end

  defp program(s, side, indexed) do
    literal_code!()
    caller = side.run.snapshot.root
    meta = side.historical.repo_metadata
    pool = meta.pid
    s = enter(s, @checkpoint, [])
    s = leaf(s, {Process, :get, 2}, [{Repo, :dynamic_repo}, Repo], side.historical.repo)
    s = leaf(s, {:ets, :lookup_element, 3}, [Ecto.Repo.Registry, side.historical.repo, 4], meta)

    # The logger's code and every captured input are checked against the pinned
    # adapter's compiled call to log/5, independently of the checked environment.
    {_, :call, {DBConnection, :checkout, [_, _, opts]}} = hd(s.events).event
    log = Keyword.fetch!(opts, :log)
    validate_logger!(s, hd(s.events), log, meta)
    ensure(s, hd(s.events), :checkpoint_options, opts, [log: log] ++ meta.opts)
    s = enter(s, {DBConnection, :checkout, 3}, [pool, nil, opts])
    {s, checkout_clock} = origin(s, {:erlang, :monotonic_time, 0}, [], :integer)
    s = enter(s, {Process, :get, 1}, [:"$callers"])
    s = leaf(s, {Process, :get, 2}, [:"$callers", nil], nil)
    s = leave(s, {Process, :get, 1}, nil)
    s = enter(s, {DBConnection.Holder, :checkout, 3}, [pool, [caller], opts])
    s = enter(s, {System, :monotonic_time, 1}, [1000])
    {s, now} = origin(s, {:erlang, :monotonic_time, 1}, [1000], :integer)
    s = leave(s, {System, :monotonic_time, 1}, now)
    timeout = Keyword.get(opts, :timeout, 15_000)
    deadline = min(now + timeout, Keyword.get(opts, :deadline))
    s = enter(s, {DBConnection.Holder, :checkout, 5}, [pool, [caller], true, now, deadline])
    {s, lock} = origin(s, {:erlang, :monitor, 2}, [:process, pool], :reference)
    message = {:db_connection, {caller, lock}, {:checkout, [caller], now, true}}
    s = enter(s, {:erlang, :send, 2}, [pool, message])
    s = take(s, {caller, :send, message, pool})
    s = leave(s, {:erlang, :send, 2}, message)

    source = hd(s.events)
    {^caller, :receive, {:"ETS-TRANSFER", holder, ^pool, {^lock, queue, checkin}}} = source.event

    queue_source =
      Enum.find_value(indexed.events, fn
        %{
          index: n,
          event:
            {_, :return_from, {DBConnection.Holder, :checkout, 3},
             {:ok, {:pool_ref, ^pool, ref, _, _, _}, _, _, _}}
        }
        when n < source.index ->
          ref

        _ ->
          nil
      end)

    ensure(s, source, :checkpoint_pool_reference, queue, queue_source)
    s = take(s, {caller, :receive, {:"ETS-TRANSFER", holder, pool, {lock, queue, checkin}}})
    s = leaf(s, {:erlang, :demonitor, 2}, [lock, [:flush]], true)

    {s, timer} =
      origin(
        s,
        {:erlang, :start_timer, 4},
        [deadline, pool, {queue, holder, caller, deadline - now}, [abs: true]],
        :reference
      )

    s = leaf(s, {:ets, :update_element, 3}, [holder, :conn, [{5, lock}, {7, timer}]], true)

    {:ok, checkpoint} =
      Historical.cut(side.historical, side.connection_history, hd(s.events).index)

    committed = Map.fetch!(checkpoint.connections, holder)
    protocol = committed.protocol
    ensure(s, source, :checkpoint_outside_transaction, protocol.postgres, :idle)

    conn_row = [
      {:conn, committed.owner, Postgrex.Protocol, protocol, lock, committed.clock, timer, :ok}
    ]

    s = leaf(s, {:ets, :lookup, 2}, [holder, :conn], conn_row)
    pool_ref = {:pool_ref, pool, queue, timer, holder, lock}
    returned = {:ok, pool_ref, Postgrex.Protocol, checkin, protocol}
    s = leave(s, {DBConnection.Holder, :checkout, 5}, returned)
    s = leave(s, {DBConnection.Holder, :checkout, 3}, returned)
    {s, conn_ref} = origin(s, {:erlang, :make_ref, 0}, [], :reference)
    s = leaf(s, {DBConnection, :past_event, 3}, [nil, :checkin, checkin], nil)
    s = leaf(s, {DBConnection, :past_event, 3}, [nil, :checkout, checkout_clock], nil)
    conn = %DBConnection{pool_ref: pool_ref, conn_ref: conn_ref}
    s = leave(s, {DBConnection, :checkout, 3}, {:ok, conn, nil})

    s = status(s, holder, protocol, conn_row, opts)
    s = leaf(s, {:erlang, :put, 2}, [{Ecto.Adapters.SQL, pool}, conn], :undefined)
    s = leaf(s, @literal, [], :allocation_checkpoint)
    s = leaf(s, {:erlang, :erase, 1}, [{Ecto.Adapters.SQL, pool}], conn)
    s = status(s, holder, protocol, conn_row, opts)
    s = enter(s, {DBConnection.Holder, :checkin, 1}, [pool_ref])
    {s, at} = origin(s, {:erlang, :monotonic_time, 0}, [], :integer)
    s = leaf(s, {:erlang, :cancel_timer, 2}, [timer, [async: true, info: false]], :ok)
    s = leaf(s, {:ets, :update_element, 3}, [holder, :conn, [{7, nil}, {5, nil}]], true)
    s = leaf(s, {:ets, :give_away, 3}, [holder, pool, {:checkin, queue, at}], true)
    s = leave(s, {DBConnection.Holder, :checkin, 1}, :ok)
    s = leave(s, @checkpoint, :allocation_checkpoint)
    %{s | lease: %{pool_ref: pool_ref, protocol: protocol, conn_ref: conn_ref, caller: caller}}
  rescue
    _ -> fail(s, hd(s.events), :checkpoint_protocol, :malformed, :closed_native_program)
  end

  defp status(s, holder, protocol, row, opts) do
    s = leaf(s, {:ets, :lookup, 2}, [holder, :conn], row)
    s = leaf(s, {Postgrex.Protocol, :handle_status, 2}, [opts, protocol], {:idle, protocol})
    leaf(s, {:ets, :update_element, 3}, [holder, :conn, {4, protocol}], true)
  end

  defp validate_logger!(s, e, log, meta) do
    info = Map.new(Function.info(log))
    identity = {info.module, info.name, info.arity, info.new_uniq, info.index}
    expected = Compiled.identity(Ecto.Adapters.SQL, :"-with_log/4-fun-0-", 1)
    ensure(s, e, :checkpoint_logger, identity, expected)
    inputs = %{0 => meta.telemetry, 1 => meta.log_stacktrace_mfa, 2 => [], 4 => meta.opts}
    expected_env = for _ <- info.env, do: :unbound

    expected_env =
      Enum.reduce(inputs, expected_env, fn {argument, value}, env ->
        {:ok, register} =
          Compiled.captured_argument(Ecto.Adapters.SQL, info.name, :log, 5, argument)

        List.replace_at(env, register - 1, value)
      end)

    ensure(s, e, :checkpoint_logger_environment, info.env, expected_env)
  end

  defp literal_code! do
    References.memo({:allocation_literal, Scenarios.module_info(:md5)}, fn ->
      {:beam_file, _, _, _, _, functions} = :beam_disasm.file(:code.which(Scenarios))
      {_, name, 0} = @literal

      {:function, ^name, 0, _, code} =
        Enum.find(functions, &match?({:function, ^name, 0, _, _}, &1))

      body =
        Enum.reject(code, fn
          {tag, _} when tag in [:line, :label] -> true
          {:func_info, _, _, _} -> true
          _ -> false
        end)

      unless body == [{:move, {:atom, :allocation_checkpoint}, {:x, 0}}, :return],
        do: raise("allocation callback must compile to its fixed literal and return")

      true
    end)
  end

  defp leaf(s, mfa, args, value), do: s |> enter(mfa, args) |> leave(mfa, value)

  defp enter(s, {m, f, _} = mfa, args) do
    s = take(s, {hd(s.events).pid, :call, {m, f, args}})
    %{s | stack: [mfa | s.stack]}
  end

  defp leave(s, mfa, value) do
    s = take(s, {hd(s.events).pid, :return_from, mfa, value})
    %{s | stack: tl(s.stack)}
  end

  defp origin(s, mfa, args, kind) do
    s = enter(s, mfa, args)
    e = hd(s.events)
    value = elem(e.event, 3)

    valid? =
      case kind do
        :integer -> is_integer(value)
        :reference -> is_reference(value)
      end

    ensure(s, e, :checkpoint_origin, valid?, true)
    {leave(s, mfa, value), value}
  end

  defp take(%{events: [e | rest]} = s, event) do
    ensure(s, e, :checkpoint_event, e.event, event)
    ensure(s, e, :checkpoint_stack, e.stack, s.stack)
    %{s | events: rest, claimed: [Capture.address(e) | s.claimed]}
  end

  defp take(s, _), do: fail(s, nil, :checkpoint_event, :missing, :next_instruction)
  defp ensure(_s, _e, _rule, value, value), do: :ok
  defp ensure(s, e, rule, actual, expected), do: fail(s, e, rule, actual, expected)

  defp fail(_s, e, rule, actual, expected) do
    at = if e, do: Map.take(e, [:role, :mfa, :stack]) |> Map.put(:twin_index, e.index), else: nil
    throw({:allocation, %{at: at, rule: rule, path: [], run: actual, twin: expected}})
  end
end
