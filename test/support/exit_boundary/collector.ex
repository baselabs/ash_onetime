defmodule AshOnetime.Test.ExitBoundary.Collector do
  @moduledoc false

  # §2.7.8, the observation and the drain. One collector process per run sits outside
  # the trace tree and owns the trace session:
  #
  # 1. Before the root is released from its start handshake, the session traces every
  #    function of `:erlang`, `:erts_internal` and every module the class table names
  #    (`[:local]`), the window frames with `exception_trace`, the timer functions with
  #    `return_trace` (the ledger), `:on_load` for modules loaded during the run, and the
  #    root with `[:send, :receive, :procs, :call, :set_on_spawn]`; ports are traced new
  #    and existing. Every trace message carries a strictly monotonic timestamp, so the
  #    snapshot is in the order the events happened, not the order their messages
  #    arrived from the processes and ports that emitted them. The port operations'
  #    `erts_internal` functions are traced with `return_trace`: an operation the port
  #    runs later returns a reference, and its result comes as a `{reference, result}`
  #    message paired by the scheduling registry.
  # 2. Every pid from `:spawn` and `:spawned` events is recorded and monitored.
  # 3. The terminal boundary: the boundary function returned, every descendant is down,
  #    every port the run opened is closed with its `:closed` event seen, and every timer
  #    the run started fired (its message seen at the recipient) or was cancelled with a
  #    cancel result seen. Only then is the root told to stop, and its exit awaited.
  # 4. Per-pid `trace_delivered` fences, then `trace_delivered(:all)`, repeated until the
  #    known set is stable; then the snapshot goes to the test and the session is
  #    destroyed. A run that cannot reach the boundary within its deadline fails, and
  #    every recorded process is killed.
  #
  # Nothing here formats an event: a failure names counts and classes, never a term.

  @flags [:send, :receive, :procs, :call, :set_on_spawn, :strict_monotonic_timestamp]
  @port_flags [:send, :receive, :strict_monotonic_timestamp]

  defmodule Snapshot do
    @moduledoc false
    # `events` are the trace messages in timestamp order, without the trace tag and the
    # timestamp;
    # `root` is the caller; `pids` every recorded process; `opened` the ports the run
    # opened; `timers` the ledger, each entry terminal.
    defstruct [:events, :root, :pids, :opened, :timers, :loaded_before, :residue]
  end

  @doc """
  Starts the collector for one run. `frames` are `{module, function, arity | :_}`
  patterns traced with `exception_trace`. Returns the collector pid; the caller then
  hands it the root with `arm/2`.
  """
  def start(frames, deadline, options \\ []) do
    test = self()
    collector = spawn(fn -> init(test, frames, deadline, options) end)

    receive do
      {:collector_ready, ^collector} -> collector
    after
      deadline -> raise "exit-boundary collector did not start"
    end
  end

  @doc "Arms the root (traced before release) and releases it."
  def arm(collector, root) do
    send(collector, {:arm, self(), root})

    receive do
      {:armed, ^collector} -> :ok
    end
  end

  @doc "Waits for the drained snapshot, or the failure that replaced it."
  def snapshot(collector, deadline) do
    receive do
      {:snapshot, ^collector, snapshot} -> {:ok, snapshot}
      {:snapshot_failed, ^collector, reason} -> {:error, reason}
    after
      deadline * 2 -> {:error, :collector_silent}
    end
  end

  defp init(test, frames, deadline, options) do
    loaded_before = MapSet.new(:code.all_loaded(), &elem(&1, 0))
    session = :trace.session_create(:ash_onetime_exit_boundary, self(), [])

    try do
      AshOnetime.Test.ExitBoundary.Capture.patterns(session, frames, options)
      send(test, {:collector_ready, self()})

      receive do
        {:arm, ^test, root} ->
          1 = :trace.process(session, root, true, @flags)
          :trace.port(session, :new, true, [:ports | @port_flags])
          :trace.port(session, :existing, true, @port_flags)
          Process.monitor(root)
          send(test, {:armed, self()})
          unless Keyword.get(options, :passive?, false), do: send(root, {:go, self()})

          state = %{
            session: session,
            test: test,
            root: root,
            events: [],
            pids: MapSet.new([root]),
            down: MapSet.new(),
            opened: MapSet.new(),
            closed: MapSet.new(),
            timers: %{},
            pending_start: %{},
            pending_cancel: %{},
            returned?: false,
            published?: false,
            stopped?: Keyword.get(options, :passive?, false),
            residue: nil,
            fence_timeout: false,
            untimed: 0,
            deadline: System.monotonic_time(:millisecond) + deadline
          }

          finish(test, collect(state), loaded_before)
      end
    after
      :trace.session_destroy(session)
    end
  end

  defp finish(test, {:ok, state}, loaded_before) do
    snapshot = %Snapshot{
      events: state.events |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)),
      root: state.root,
      pids: state.pids,
      opened: state.opened,
      timers: state.timers,
      loaded_before: loaded_before,
      residue: state.residue
    }

    send(test, {:snapshot, self(), snapshot})
  end

  defp finish(test, {:error, reason, state}, _loaded_before) do
    for pid <- state.pids, do: Process.exit(pid, :kill)
    send(test, {:snapshot_failed, self(), reason})
  end

  # Phase 1: record until the terminal boundary holds, stop the root, await its exit.
  defp collect(state) do
    cond do
      terminal?(state) and not state.stopped? ->
        # The observer takes residue after every descendant and timer has drained.
        # A probe in the caller would itself add observable dictionary operations.
        {:dictionary, dictionary} = Process.info(state.root, :dictionary)
        residue = Enum.count(dictionary, fn {key, _} -> match?({AshOnetime.Delivery, _}, key) end)
        send(state.root, {:stop, self()})
        collect(%{state | stopped?: true, residue: residue})

      state.stopped? and MapSet.member?(state.down, state.root) ->
        fence(state)

      true ->
        remaining = state.deadline - System.monotonic_time(:millisecond)

        receive do
          message -> message |> record(state) |> collect()
        after
          max(remaining, 0) -> {:error, pending(state), state}
        end
    end
  end

  # Phase 2: per-pid fences, then the port fence, until the known set is stable.
  defp fence(state) do
    known = state.pids

    state =
      Enum.reduce(known, state, fn pid, acc ->
        ref = :trace.delivered(acc.session, pid)
        await_fence(acc, pid, ref)
      end)

    ref = :trace.delivered(state.session, :all)
    state = await_fence(state, :all, ref)

    cond do
      state.fence_timeout ->
        {:error, Map.put(pending(state), :fence, :timeout), state}

      state.untimed > 0 ->
        {:error, Map.put(pending(state), :untimed_events, state.untimed), state}

      not MapSet.equal?(known, state.pids) ->
        # A pid found while fencing sends the protocol back to the terminal boundary.
        collect(%{state | stopped?: true})

      not terminal_after_stop?(state) ->
        {:error, pending(state), state}

      true ->
        {:ok, state}
    end
  end

  defp await_fence(state, target, ref) do
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:trace_delivered, ^target, ^ref} -> state
      message -> message |> record(state) |> await_fence(target, ref)
    after
      remaining -> %{state | fence_timeout: true}
    end
  end

  defp terminal?(state) do
    state.returned? and state.published? and MapSet.size(live(state)) <= 1 and
      MapSet.subset?(state.opened, state.closed) and map_size(open_timers(state)) == 0
  end

  defp terminal_after_stop?(state) do
    MapSet.size(live(state)) == 0 and MapSet.subset?(state.opened, state.closed) and
      map_size(open_timers(state)) == 0
  end

  defp live(state), do: MapSet.difference(state.pids, state.down)

  defp open_timers(state), do: Map.filter(state.timers, fn {_ref, t} -> t.state == :pending end)

  defp pending(state) do
    %{
      returned?: state.returned?,
      live_processes: MapSet.size(live(state)),
      open_ports: MapSet.size(MapSet.difference(state.opened, state.closed)),
      pending_timers: map_size(open_timers(state))
    }
  end

  defp record({:DOWN, _ref, :process, pid, _reason}, state),
    do: %{state | down: MapSet.put(state.down, pid)}

  defp record(message, state) when elem(message, 0) == :trace_ts do
    [_trace | rest] = Tuple.to_list(message)
    {rest, [stamp]} = Enum.split(rest, -1)
    event = List.to_tuple(rest)

    %{state | events: [{stamp, event} | state.events]}
    |> procs(event)
    |> ports(event)
    |> ledger(event)
    |> boundary(event)
  end

  # Every traced process and port carries the timestamp flag; a message without one
  # could not be placed in order, and fails the run.
  defp record(message, state) when elem(message, 0) == :trace,
    do: %{state | untimed: state.untimed + 1}

  defp record(_other, state), do: state

  defp procs(state, {pid, :spawn, child, _mfa}) when is_pid(pid), do: add_pid(state, child)
  defp procs(state, {child, :spawned, _parent, _mfa}), do: add_pid(state, child)
  defp procs(state, _event), do: state

  defp add_pid(state, pid) do
    if MapSet.member?(state.pids, pid) do
      state
    else
      Process.monitor(pid)
      %{state | pids: MapSet.put(state.pids, pid)}
    end
  end

  defp ports(state, {port, :open, pid, _driver}) when is_port(port) do
    if MapSet.member?(state.pids, pid),
      do: %{state | opened: MapSet.put(state.opened, port)},
      else: state
  end

  defp ports(state, {port, :closed, _reason}) when is_port(port),
    do: %{state | closed: MapSet.put(state.closed, port)}

  defp ports(state, _event), do: state

  # The deferred-effect ledger. A start's call and its `return_from` arrive in order on
  # the same pid; the reference is the return value.
  defp ledger(state, {pid, :call, {:erlang, function, args}})
       when function in [:send_after, :start_timer] do
    [_time, dest, message | _opts] = args
    put_in(state.pending_start[pid], {function, dest, message})
  end

  defp ledger(state, {pid, :return_from, {:erlang, function, _arity}, ref})
       when function in [:send_after, :start_timer] and is_reference(ref) do
    {{kind, dest, message}, pending} = Map.pop(state.pending_start, pid)

    expected =
      case kind do
        :send_after -> message
        :start_timer -> {:timeout, ref, message}
      end

    timer = %{kind: kind, dest: dest, expected: expected, state: :pending}
    %{state | pending_start: pending, timers: Map.put(state.timers, ref, timer)}
  end

  defp ledger(state, {pid, :call, {:erlang, :cancel_timer, [ref | _opts]}}),
    do: put_in(state.pending_cancel[pid], ref)

  # A cancel counts only with its result seen: the remaining time (an integer), or `:ok`
  # from a cancel issued without `info`. `false` means the timer already fired or never
  # existed, and is never taken as either outcome; only the `:receive` settles it.
  defp ledger(state, {pid, :return_from, {:erlang, :cancel_timer, _arity}, result}) do
    {ref, pending} = Map.pop(state.pending_cancel, pid)
    state = %{state | pending_cancel: pending}

    case {Map.fetch(state.timers, ref), result} do
      {{:ok, %{state: :pending} = timer}, result} when is_integer(result) or result == :ok ->
        put_in(state.timers[ref], %{timer | state: :cancelled})

      _other ->
        state
    end
  end

  defp ledger(state, {pid, :receive, message}) when is_pid(pid) do
    case Enum.find(state.timers, fn {_ref, t} ->
           t.state == :pending and t.expected === message and recipient?(t.dest, pid)
         end) do
      {ref, timer} -> put_in(state.timers[ref], %{timer | state: :fired})
      nil -> state
    end
  end

  defp ledger(state, _event), do: state

  defp recipient?(dest, pid) when is_pid(dest), do: dest == pid
  defp recipient?(dest, pid) when is_atom(dest), do: Process.whereis(dest) in [pid, nil]

  defp boundary(
         %{root: root} = state,
         {root, tag, {AshOnetime.Test.ExitBoundary.Root, :invoke, 2}, _}
       )
       when tag in [:return_from, :exception_from],
       do: %{state | returned?: true}

  defp boundary(
         %{root: root, test: observer} = state,
         {root, :send, {:result, root, _result, _residue}, observer}
       ),
       do: %{state | published?: true}

  defp boundary(state, _event), do: state
end
