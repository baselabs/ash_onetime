defmodule AshOnetime.Test.ExitBoundary.Collector do
  alias AshOnetime.Test.ExitBoundary.Capture
  alias AshOnetime.Test.ExitBoundary.NativeTransport
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
    defstruct [
      :events,
      :root,
      :pids,
      :opened,
      :timers,
      :loaded_before,
      :residue,
      :monitors,
      :down,
      :services,
      :service_receipts
    ]
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
  def arm(collector, root, preexisting \\ []) do
    send(collector, {:arm, self(), root, preexisting})

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

  def service_callbacks({module, :handle_call, 3})
      when module in [Postgrex.TypeServer, Postgrex.Parameters, DynamicSupervisor],
      do: [{module, :handle_call, 3}, {module, :handle_cast, 2}, {module, :handle_info, 2}]

  def service_callbacks(callback), do: [callback]

  defp init(test, frames, deadline, options) do
    loaded_before = MapSet.new(:code.all_loaded(), &elem(&1, 0))
    session = :trace.session_create(:ash_onetime_exit_boundary, self(), [])

    try do
      Capture.patterns(session, frames, options)
      send(test, {:collector_ready, self()})

      receive do
        {:arm, ^test, root, preexisting} ->
          pids = MapSet.new([root | preexisting])
          services = service_bindings(Keyword.get(options, :services, %{}))

          for pid <- Enum.uniq(MapSet.to_list(pids) ++ Map.keys(services)) do
            1 = :trace.process(session, pid, true, @flags)
          end

          monitors = Map.new(pids, fn pid -> {pid, Process.monitor(pid)} end)
          :trace.port(session, :new, true, [:ports | @port_flags])
          :trace.port(session, :existing, true, @port_flags)
          send(test, {:armed, self()})
          unless Keyword.get(options, :passive?, false), do: send(root, {:go, self()})

          state = %{
            session: session,
            test: test,
            root: root,
            events: [],
            pids: pids,
            monitors: monitors,
            origins: Map.new(pids, fn pid -> {pid, :proc_lib.translate_initial_call(pid)} end),
            down: MapSet.new(),
            opened: MapSet.new(),
            closed: MapSet.new(),
            timers: %{},
            pending_start: %{},
            pending_cancel: %{},
            services: services,
            service_receipts: [],
            service_pending: %{},
            service_programs: MapSet.new(),
            service_program_generation: 0,
            service_program_attempt: nil,
            stamp: nil,
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
      monitors: state.monitors,
      down: state.down,
      services: state.services,
      service_receipts: Enum.reverse(state.service_receipts),
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
    state = settle_service_programs(state)

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
    known = traced(state)

    state =
      Enum.reduce(known, state, fn pid, acc ->
        ref = :trace.delivered(acc.session, pid)
        await_fence(acc, pid, ref)
      end)

    ref = :trace.delivered(state.session, :all)
    state = await_fence(state, :all, ref)
    state = settle_service_programs(state)

    cond do
      state.fence_timeout ->
        {:error, Map.put(pending(state), :fence, :timeout), state}

      state.untimed > 0 ->
        {:error, Map.put(pending(state), :untimed_events, state.untimed), state}

      not MapSet.equal?(known, traced(state)) ->
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
      MapSet.subset?(state.opened, state.closed) and map_size(open_timers(state)) == 0 and
      map_size(state.service_pending) == 0
  end

  defp terminal_after_stop?(state) do
    MapSet.size(live(state)) == 0 and MapSet.subset?(state.opened, state.closed) and
      map_size(open_timers(state)) == 0 and map_size(state.service_pending) == 0
  end

  defp live(state), do: MapSet.difference(state.pids, state.down)

  defp traced(state), do: MapSet.union(state.pids, MapSet.new(Map.keys(state.services)))

  defp open_timers(state), do: Map.filter(state.timers, fn {_ref, t} -> t.state == :pending end)

  defp pending(state) do
    %{
      returned?: state.returned?,
      live_processes: MapSet.size(live(state)),
      open_ports: MapSet.size(MapSet.difference(state.opened, state.closed)),
      pending_timers: map_size(open_timers(state)),
      pending_service_callbacks: map_size(state.service_pending),
      pending_service_instances:
        for {pid, receipts} <- state.service_pending,
            receipt <- receipts do
          binding = Map.fetch!(state.services, pid)

          %{
            service: elem(binding.callback, 0),
            request: service_request_kind(receipt.message),
            shape: service_message_shape(receipt.message),
            native_calls: service_receipt_calls(state.events, receipt),
            registered?: receipt.registered?,
            callback:
              case receipt.called do
                {_, :call, {module, function, arguments}} -> {module, function, length(arguments)}
                nil -> :not_called
              end,
            returned?: not is_nil(receipt.returned)
          }
        end,
      live_origins:
        for pid <- live(state) do
          %{
            mfa: :proc_lib.translate_initial_call(pid),
            current: Process.info(pid, :current_function)
          }
        end,
      timer_instances:
        Enum.map(open_timers(state), fn {ref, timer} -> timer_diagnostic(ref, timer, state) end)
    }
  end

  defp service_request_kind({:"$gen_call", _from, request}),
    do: service_request_tag(:call, request)

  defp service_request_kind({:"$gen_cast", request}), do: service_request_tag(:cast, request)
  defp service_request_kind({:ack, _pid, _result}), do: :startup_ack
  defp service_request_kind({:nack, _pid, _result}), do: :startup_nack
  defp service_request_kind({:DOWN, _ref, :process, _pid, _reason}), do: :monitor_down
  defp service_request_kind({:EXIT, _pid, _reason}), do: :linked_exit
  defp service_request_kind({:timeout, _ref, _message}), do: :timer_expiration
  defp service_request_kind(_message), do: :info

  defp service_message_shape(message) when is_tuple(message),
    do: {:tuple, tuple_size(message), Enum.map(Tuple.to_list(message), &service_field_kind/1)}

  defp service_message_shape(message), do: service_field_kind(message)

  defp service_field_kind(value) when is_atom(value), do: :atom
  defp service_field_kind(value) when is_reference(value), do: :reference
  defp service_field_kind(value) when is_pid(value), do: :pid
  defp service_field_kind(value) when is_port(value), do: :port
  defp service_field_kind(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp service_field_kind(value) when is_list(value), do: :list
  defp service_field_kind(value) when is_binary(value), do: :binary
  defp service_field_kind(_value), do: :other

  # A failed drain reports only code coordinates around mailbox ingress. Neither
  # a private message nor a native call's arguments enter the diagnostic.
  defp service_receipt_calls(events, receipt) do
    events
    |> Enum.filter(fn {_stamp, event} -> elem(event, 0) == receipt.pid end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.with_index(fn {stamp, event}, index ->
      %{stamp: stamp, event: event, index: index}
    end)
    |> NativeTransport.pairs()
    |> Map.values()
    |> Enum.filter(fn pair ->
      pair.source.stamp < receipt.received_stamp and
        receipt.received_stamp < pair.returned.stamp
    end)
    |> Enum.sort_by(& &1.source.stamp)
    |> Enum.map(fn pair ->
      {module, function, arguments} = elem(pair.source.event, 2)
      %{mfa: {module, function, length(arguments)}, index: pair.source.index}
    end)
  end

  defp service_request_tag(kind, request) do
    tag = if is_tuple(request) and tuple_size(request) > 0, do: elem(request, 0), else: request

    if tag in [
         :fetch,
         :update,
         :done,
         :insert,
         :delete,
         :which_children,
         :start_child,
         :terminate_child
       ],
       do: {kind, tag},
       else: kind
  end

  defp timer_diagnostic(ref, timer, state) do
    %{
      kind: timer.kind,
      creator: %{caller?: timer.creator == state.root, mfa: Map.get(state.origins, timer.creator)},
      recipient: timer_recipient(timer.dest, state),
      active?: is_integer(:erlang.read_timer(ref))
    }
  end

  defp timer_recipient(pid, state) when is_pid(pid) do
    %{
      kind: :pid,
      alive?: Process.alive?(pid),
      monitored?: Map.has_key?(state.monitors, pid),
      death_seen?: MapSet.member?(state.down, pid),
      current: current_origin(pid)
    }
  end

  defp timer_recipient(name, _state) when is_atom(name) do
    %{
      kind: :registered_name,
      name: name,
      current: current_origin(Process.whereis(name))
    }
  end

  defp timer_recipient(_other, _state), do: %{kind: :other}

  defp current_origin(nil), do: :not_registered

  defp current_origin(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, mfa} -> %{mfa: mfa}
      nil -> :exited
    end
  end

  defp record({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.monitors, pid) do
      {:ok, ^ref} ->
        state = %{state | down: MapSet.put(state.down, pid)}
        recipient_exit(state, pid, ref)

      _ ->
        state
    end
  end

  defp record(message, state) when elem(message, 0) == :trace_ts do
    [_trace | rest] = Tuple.to_list(message)
    {rest, [stamp]} = Enum.split(rest, -1)
    event = List.to_tuple(rest)

    %{state | events: [{stamp, event} | state.events], stamp: stamp}
    |> procs(event)
    |> ports(event)
    |> service_event(event)
    |> service_program_event(event)
    |> ledger(event)
    |> boundary(event)
    |> settle_service_timers()
  end

  # Every traced process and port carries the timestamp flag; a message without one
  # could not be placed in order, and fails the run.
  defp record(message, state) when elem(message, 0) == :trace,
    do: %{state | untimed: state.untimed + 1}

  defp record(_other, state), do: state

  # Shared services are bound and armed before root release. Their lifetime is
  # external to this invocation; its deferred work still requires the exact
  # native receive and the matching callback's completed return. Every event and
  # spawned descendant remains in the same trace session.
  defp service_bindings(declared) do
    Map.new(declared, fn
      {name, %{kind: :state_machine, pid: pid} = binding} ->
        unless pid in [binding.owner, binding.sender] and
                 Port.info(binding.port, :connected) == {:connected, binding.owner},
               do: raise("a persistent native connection worker is unavailable")

        {pid, Map.put(binding, :name, name)}

      {name, %{pid: pid, callback: callback, table: table}} ->
        unless is_pid(pid) and :ets.info(table, :owner) == pid,
          do: raise("a declared native type-table owner is unavailable")

        # The synchronous system reply places every pre-arm dispatch before
        # tracing. New ordinary messages then have their own native receipts.
        initial_state = :sys.get_state(pid)

        {pid,
         %{
           name: name,
           callback: callback,
           callbacks: service_callbacks(callback),
           table: table,
           registration_keys: Registry.keys(Postgrex.TypeManager, pid),
           initial_state: initial_state
         }}

      {name, callback} ->
        pid = Process.whereis(name)
        unless is_pid(pid), do: raise("a declared observation service is unavailable")
        {pid, %{name: name, callback: callback, callbacks: service_callbacks(callback)}}
    end)
  end

  defp service_bound?(pid, %{kind: :state_machine} = binding),
    do:
      pid in [binding.owner, binding.sender] and
        Port.info(binding.port, :connected) == {:connected, binding.owner}

  defp service_bound?(pid, %{table: table}), do: :ets.info(table, :owner) == pid

  defp service_bound?(pid, %{registration: {registry, key}}),
    do: key in Registry.keys(registry, pid)

  defp service_bound?(pid, %{name: name}), do: Process.whereis(name) == pid

  defp service_event(state, {pid, :return_from, {Registry, :register, 3}, {:ok, _partition}}) do
    registration =
      Enum.find_value(state.events, fn
        {_stamp, {^pid, :call, {Registry, :register, [Postgrex.TypeManager, key, _value]}}} ->
          key

        _ ->
          nil
      end)

    case registration do
      {module, _endpoint} = key when is_atom(module) ->
        callback = {Postgrex.TypeServer, :handle_call, 3}

        binding = %{
          name: {:native_type_owner, key},
          registration: {Postgrex.TypeManager, key},
          callback: callback,
          callbacks: service_callbacks(callback),
          birth_stamp: state.stamp
        }

        put_in(state.services[pid], binding)

      nil ->
        state
    end
  end

  defp service_event(state, {pid, :exit, _reason} = event) do
    receipts =
      Enum.map(state.service_receipts, fn receipt ->
        if receipt.pid == pid and is_nil(receipt.returned),
          do: Map.put(receipt, :retired, event),
          else: receipt
      end)

    %{state | service_receipts: receipts, service_pending: Map.delete(state.service_pending, pid)}
  end

  defp service_event(state, {pid, :receive, message} = event) do
    case Map.fetch(state.services, pid) do
      {:ok, binding} ->
        receipt = %{
          pid: pid,
          message: message,
          received: event,
          received_stamp: state.stamp,
          registered?: service_bound?(pid, binding),
          called: nil,
          called_stamp: nil,
          returned: nil,
          returned_stamp: nil,
          used_by: nil
        }

        state = %{state | service_receipts: [receipt | state.service_receipts]}

        if service_dispatch?(binding, message) do
          pending = Map.update(state.service_pending, pid, [receipt], &(&1 ++ [receipt]))
          %{state | service_pending: pending}
        else
          state
        end

      :error ->
        state
    end
  end

  defp service_event(state, {pid, :call, {_module, _function, [_message | _]}} = event) do
    case Map.fetch(state.services, pid) do
      {:ok, binding} -> service_callback(state, pid, binding, event)
      :error -> state
    end
  end

  defp service_event(state, {pid, :return_from, mfa, _result} = event) do
    case {Map.fetch(state.services, pid), Map.get(state.service_pending, pid, [])} do
      {{:ok, binding}, [%{called: {_, :call, {module, function, arguments}}} = receipt | rest]} ->
        if mfa == {module, function, length(arguments)} and
             mfa in Map.get(binding, :callbacks, [binding.callback]) do
          service_return(state, pid, event, receipt, rest)
        else
          state
        end

      _ ->
        state
    end
  end

  defp service_event(state, _event), do: state

  defp service_callback(state, pid, binding, {_, :call, {module, function, arguments}} = event) do
    if {module, function, length(arguments)} in Map.get(binding, :callbacks, [binding.callback]) do
      envelope = service_envelope(Map.get(binding, :kind), function, arguments)
      service_call(state, pid, envelope, event)
    else
      state
    end
  end

  defp service_envelope(:state_machine, _function, [{:call, from}, request, _data]),
    do: {:"$gen_call", from, request}

  defp service_envelope(:state_machine, _function, [:cast, request, _data]),
    do: {:"$gen_cast", request}

  defp service_envelope(:state_machine, _function, [:info, request, _data]), do: request

  defp service_envelope(_kind, :handle_call, [request, from, _state]),
    do: {:"$gen_call", from, request}

  defp service_envelope(_kind, :handle_cast, [request, _state]), do: {:"$gen_cast", request}
  defp service_envelope(_kind, _function, [message | _]), do: message

  defp service_return(state, pid, event, receipt, rest) do
    receipt = %{receipt | returned: event, returned_stamp: state.stamp}

    pending =
      if rest == [],
        do: Map.delete(state.service_pending, pid),
        else: Map.put(state.service_pending, pid, rest)

    replace_service_receipt(%{state | service_pending: pending}, receipt)
  end

  defp service_dispatch?(_binding, {:system, _from, _request}), do: false

  defp service_dispatch?(%{kind: :state_machine}, {:"$gen_call", {_caller, _tag}, _request}),
    do: true

  defp service_dispatch?(%{kind: :state_machine}, _message), do: false

  defp service_dispatch?(binding, message) do
    {module, _function, _arity} = binding.callback

    callback =
      case message do
        {:"$gen_call", {_caller, _tag}, _request} -> {module, :handle_call, 3}
        {:"$gen_cast", _request} -> {module, :handle_cast, 2}
        _ -> {module, :handle_info, 2}
      end

    callback in Map.get(binding, :callbacks, [binding.callback])
  end

  defp service_call(state, pid, message, event) do
    receipt =
      Enum.find(state.service_receipts, fn receipt ->
        receipt.pid == pid and receipt.message === message and is_nil(receipt.called)
      end)

    case receipt do
      nil ->
        state

      receipt ->
        receipt = %{receipt | called: event, called_stamp: state.stamp}
        state = replace_service_receipt(state, receipt)

        pending =
          state.service_pending
          |> Map.get(pid, [])
          |> Enum.reject(&(&1.received_stamp == receipt.received_stamp))

        %{state | service_pending: Map.put(state.service_pending, pid, [receipt | pending])}
    end
  end

  defp replace_service_receipt(state, replacement) do
    receipts =
      Enum.map(state.service_receipts, fn receipt ->
        if receipt.received_stamp == replacement.received_stamp, do: replacement, else: receipt
      end)

    %{state | service_receipts: receipts}
  end

  # Mailbox ingress is retained even when a native selective receive or a
  # demonitor flush consumes it. Such a receipt has no GenServer callback.
  # Close it only through its completed, independently captured native program;
  # its called/returned callback fields remain nil and every raw event remains.
  defp settle_service_programs(%{returned?: false} = state), do: state

  defp settle_service_programs(%{service_pending: pending} = state)
       when map_size(pending) == 0,
       do: state

  defp settle_service_programs(state) do
    receipts =
      state.service_pending
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&is_nil(&1.called))
      |> Enum.sort_by(& &1.received_stamp)

    attempt = {state.service_program_generation, Enum.map(receipts, & &1.received_stamp)}

    if receipts == [] or state.service_program_attempt == attempt do
      state
    else
      state
      |> Map.put(:service_program_attempt, attempt)
      |> settle_service_programs(receipts)
    end
  end

  # Rebuild the native index only when a candidate arrives or one of its
  # primitive programs completes, never for each unrelated traced instruction.
  defp service_program_event(state, {_, :return_from, {module, function, _arity}, _})
       when (module == :erlang and function in [:demonitor, :spawn_opt]) or
              (module == :proc_lib and function in [:sync_start, :init_ack]) or
              (module == DynamicSupervisor and
                 function in [:monitor_child, :terminate_children]) do
    Map.update!(state, :service_program_generation, &(&1 + 1))
  end

  defp service_program_event(state, _event), do: state

  defp settle_service_programs(state, receipts) do
    events =
      state.events
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index(fn {stamp, event}, index ->
        %{stamp: stamp, event: event, index: index}
      end)

    context = %{events: events, pairs: NativeTransport.pairs(events)}

    receipts
    |> Enum.reduce(state, &settle_service_program(&1, &2, context))
    |> settle_service_timers()
  end

  defp settle_service_program(receipt, state, context) do
    with true <- receipt.registered?,
         {:ok, key, program} <- service_program(receipt, context),
         false <- MapSet.member?(state.service_programs, key) do
      remaining =
        state.service_pending
        |> Map.fetch!(receipt.pid)
        |> Enum.reject(&(&1.received_stamp == receipt.received_stamp))

      pending =
        if remaining == [],
          do: Map.delete(state.service_pending, receipt.pid),
          else: Map.put(state.service_pending, receipt.pid, remaining)

      state
      |> Map.put(:service_pending, pending)
      |> Map.update!(:service_programs, &MapSet.put(&1, key))
      |> replace_service_receipt(Map.put(receipt, :native_program, program))
    else
      _ -> state
    end
  end

  defp service_program(%{message: {:DOWN, ref, :process, child, _}} = receipt, context) do
    service_flush(receipt, ref, context) ||
      service_shutdown_down(receipt, ref, child, context) || :error
  end

  defp service_program(%{message: {:ack, child, value}} = receipt, context) do
    pid = receipt.pid

    matches =
      for pair <- service_calls(context, pid, :proc_lib, :sync_start),
          {^pid, :call, {_, _, [{^child, ref}, _timeout]}} <- [pair.source.event],
          {^pid, :return_from, _, ^value} <- [pair.returned.event],
          receipt.received_stamp < pair.returned.stamp,
          service_spawn?(context, pid, child, ref, pair.source.index),
          service_ack?(context, receipt, child, value),
          service_demonitored?(context, pid, ref, pair),
          do: pair

    case matches do
      [pair] ->
        service_program_result(:startup_ack, pair, receipt, {:startup_ack, pair.source.stamp})

      _ ->
        :error
    end
  end

  defp service_program(%{message: {:EXIT, child, reason}} = receipt, context) do
    pid = receipt.pid

    matches =
      for pair <- service_calls(context, pid, DynamicSupervisor, :monitor_child),
          pair.source.event == {pid, :call, {DynamicSupervisor, :monitor_child, [child]}},
          pair.returned.event ==
            {pid, :return_from, {DynamicSupervisor, :monitor_child, 1}, {:error, reason}},
          receipt.received_stamp < pair.returned.stamp,
          {:ok, _ref, monitor} <- [service_monitor(context, pid, child, pair)],
          do: {pair, monitor}

    case matches do
      [{pair, monitor}] ->
        service_program_result(
          :shutdown_exit,
          pair,
          receipt,
          {:shutdown_exit, monitor.source.stamp}
        )

      _ ->
        :error
    end
  end

  defp service_program(_receipt, _context), do: :error

  defp service_flush(receipt, ref, context) do
    pid = receipt.pid

    matches =
      for pair <- service_calls(context, pid, :erlang, :demonitor),
          pair.source.event == {pid, :call, {:erlang, :demonitor, [ref, [:flush]]}},
          pair.returned.event == {pid, :return_from, {:erlang, :demonitor, 2}, true},
          receipt.received_stamp < pair.returned.stamp,
          do: pair

    case matches do
      [pair] ->
        service_program_result(:monitor_flush, pair, receipt, {:monitor_flush, pair.source.stamp})

      _ ->
        nil
    end
  end

  defp service_shutdown_down(receipt, ref, child, context) do
    pid = receipt.pid

    matches =
      for pair <- service_calls(context, pid, DynamicSupervisor, :terminate_children),
          {^pid, :call, {_, _, [children, _state]}} <- [pair.source.event],
          is_map_key(children, child),
          pair.returned.event ==
            {pid, :return_from, {DynamicSupervisor, :terminate_children, 2}, :ok},
          receipt.received_stamp < pair.returned.stamp,
          {:ok, ^ref, monitor} <- [service_monitor(context, pid, child, pair)],
          service_shutdown_received?(context, receipt, child, pair, monitor),
          do: {pair, monitor}

    case matches do
      [{pair, monitor}] ->
        service_program_result(
          :shutdown_down,
          pair,
          receipt,
          {:shutdown_down, monitor.source.stamp}
        )

      _ ->
        nil
    end
  end

  defp service_shutdown_received?(context, receipt, child, parent, monitor) do
    pid = receipt.pid
    {:DOWN, _ref, :process, ^child, reason} = receipt.message
    {^pid, :call, {_, _, [children, _state]}} = parent.source.event
    spec = Map.fetch!(children, child)

    waited? =
      Enum.any?(service_calls(context, pid, DynamicSupervisor, :wait_child), fn pair ->
        pair.source.index > monitor.returned.index and
          pair.returned.index < parent.returned.index and
          pair.source.stamp > receipt.received_stamp and
          service_wait_child?(pair, pid, child, spec, reason)
      end)

    waited? or service_monitor_received?(context, receipt, child, parent, monitor)
  end

  defp service_wait_child?(pair, pid, child, spec, reason) do
    case pair.source.event do
      {^pid, :call, {DynamicSupervisor, :wait_child, [^child, ^spec, ^reason, stacks]}}
      when is_map(stacks) and is_tuple(spec) and tuple_size(spec) == 5 ->
        expected = service_shutdown_stack(child, spec, reason, stacks)

        pair.returned.event ===
          {pid, :return_from, {DynamicSupervisor, :wait_child, 4}, expected}

      _ ->
        false
    end
  end

  defp service_shutdown_stack(child, {_, _, :brutal_kill, _, _} = spec, reason, stacks) do
    if reason == :killed, do: stacks, else: Map.put(stacks, child, {spec, reason})
  end

  defp service_shutdown_stack(child, {_, restart, _, _, _} = spec, reason, stacks) do
    if match?({:shutdown, _}, reason) or reason == :shutdown or
         (reason == :normal and restart != :permanent),
       do: stacks,
       else: Map.put(stacks, child, {spec, reason})
  end

  defp service_monitor_received?(context, receipt, child, parent, monitor) do
    pid = receipt.pid

    Enum.any?(service_calls(context, pid, DynamicSupervisor, :monitor_child), fn pair ->
      pair.source.index > parent.source.index and pair.returned.index < parent.returned.index and
        pair.source.index < monitor.source.index and
        monitor.returned.index < pair.returned.index and
        receipt.received_stamp < pair.returned.stamp and
        pair.source.event === {pid, :call, {DynamicSupervisor, :monitor_child, [child]}} and
        match?({^pid, :return_from, _, {:error, _}}, pair.returned.event)
    end)
  end

  defp service_monitor(context, pid, child, parent) do
    matches =
      for pair <- service_calls(context, pid, :erlang, :monitor),
          pair.source.index > parent.source.index,
          pair.returned.index < parent.returned.index,
          pair.source.event == {pid, :call, {:erlang, :monitor, [:process, child]}},
          {^pid, :return_from, _, ref} <- [pair.returned.event],
          is_reference(ref),
          do: {ref, pair}

    case matches do
      [{ref, pair}] -> {:ok, ref, pair}
      _ -> :error
    end
  end

  defp service_calls(context, pid, module, function) do
    for {_index, %{source: %{event: {^pid, :call, {^module, ^function, _}}}} = pair} <-
          context.pairs,
        do: pair
  end

  defp service_spawn?(context, pid, child, ref, before) do
    Enum.any?(service_calls(context, pid, :erlang, :spawn_opt), fn pair ->
      pair.returned.index < before and
        match?({^pid, :return_from, _, {^child, ^ref}}, pair.returned.event)
    end)
  end

  defp service_ack?(context, receipt, child, value) do
    sent? =
      Enum.any?(context.events, fn source ->
        source.stamp < receipt.received_stamp and
          source.event === {child, :send, {:ack, child, value}, receipt.pid}
      end)

    sent? and
      Enum.any?(service_calls(context, child, :proc_lib, :init_ack), fn pair ->
        match?({^child, :return_from, _, :ok}, pair.returned.event) and
          (pair.source.event ===
             {child, :call, {:proc_lib, :init_ack, [receipt.pid, value]}} or
             pair.source.event === {child, :call, {:proc_lib, :init_ack, [value]}})
      end)
  end

  defp service_demonitored?(context, pid, ref, parent) do
    Enum.any?(service_calls(context, pid, :erlang, :demonitor), fn pair ->
      parent.source.index < pair.source.index and pair.returned.index < parent.returned.index and
        pair.source.event === {pid, :call, {:erlang, :demonitor, [ref, [:flush]]}} and
        pair.returned.event === {pid, :return_from, {:erlang, :demonitor, 2}, true}
    end)
  end

  defp service_program_result(kind, pair, receipt, key) do
    # Strict stamps keep the same native occurrence key when a later fence
    # delivers an older event that changes the sorted prefix's integer indexes.
    {:ok, key,
     %{
       kind: kind,
       source: pair.source.event,
       returned: pair.returned.event,
       source_stamp: pair.source.stamp,
       returned_stamp: pair.returned.stamp,
       received: receipt.received
     }}
  end

  defp settle_service_timers(state) do
    Enum.reduce(state.timers, state, fn
      {ref, %{state: :pending} = timer}, state -> settle_service_timer(state, ref, timer)
      _, state -> state
    end)
  end

  defp settle_service_timer(state, ref, timer) do
    receipt =
      Enum.find(state.service_receipts, fn receipt ->
        binding = Map.fetch!(state.services, receipt.pid)

        timer.dest in [receipt.pid, binding.name] and timer.expected === receipt.message and
          timer.started_stamp < receipt.received_stamp and receipt.registered? and
          is_nil(receipt.used_by) and service_completed?(receipt)
      end)

    if receipt do
      terminal = Map.take(receipt, [:pid, :received, :called, :returned])
      state = put_in(state.timers[ref], Map.merge(timer, %{state: :fired, terminal: terminal}))
      replace_service_receipt(state, %{receipt | used_by: ref})
    else
      state
    end
  end

  defp service_completed?(receipt) do
    not is_nil(receipt.called) and not is_nil(receipt.returned) and
      receipt.received_stamp < receipt.called_stamp and
      receipt.called_stamp < receipt.returned_stamp
  end

  # The VM cancels PID-addressed timers when that exact recipient exits. A
  # registered name can outlive its current process and has no such rule. Retain
  # both the monitored death and the native inactive-timer receipt.
  defp recipient_exit(state, pid, monitor) do
    Enum.reduce(state.timers, state, fn
      {ref, %{state: :pending, dest: ^pid} = timer}, state ->
        if :erlang.read_timer(ref) === false do
          terminal = %{process: pid, monitor: monitor, timer_read: false}
          timer = Map.merge(timer, %{state: :recipient_exit, terminal: terminal})
          put_in(state.timers[ref], timer)
        else
          state
        end

      _, state ->
        state
    end)
  end

  defp procs(state, {pid, :spawn, child, _mfa}) when is_pid(pid), do: add_pid(state, child)
  defp procs(state, {child, :spawned, _parent, _mfa}), do: add_pid(state, child)
  defp procs(state, _event), do: state

  defp add_pid(state, pid) do
    if MapSet.member?(state.pids, pid) do
      state
    else
      ref = Process.monitor(pid)

      %{
        state
        | pids: MapSet.put(state.pids, pid),
          monitors: Map.put(state.monitors, pid, ref),
          origins: Map.put(state.origins, pid, :proc_lib.translate_initial_call(pid))
      }
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
    put_in(state.pending_start[pid], {function, dest, message, state.stamp})
  end

  defp ledger(state, {pid, :return_from, {:erlang, function, _arity}, ref})
       when function in [:send_after, :start_timer] and is_reference(ref) do
    {{kind, dest, message, started}, pending} = Map.pop(state.pending_start, pid)

    expected =
      case kind do
        :send_after -> message
        :start_timer -> {:timeout, ref, message}
      end

    timer = %{
      kind: kind,
      creator: pid,
      dest: dest,
      expected: expected,
      state: :pending,
      started_stamp: started
    }

    state = %{state | pending_start: pending, timers: Map.put(state.timers, ref, timer)}

    if is_pid(dest) and MapSet.member?(state.down, dest),
      do: recipient_exit(state, dest, Map.fetch!(state.monitors, dest)),
      else: state
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
           t.state == :pending and t.expected === message and recipient?(t.dest, pid) and
             not Map.has_key?(state.services, pid)
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
