defmodule AshOnetime.Test.ExitBoundary.ConnectionTls do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.NativeTransport

  # The SSL socket stays opaque. Match its public endpoint pair to the unique
  # live TCP port and retain the port's actual connected owner before observation.
  def bind(socket) do
    {:ok, local} = :ssl.sockname(socket)
    {:ok, peer} = :ssl.peername(socket)

    [port] =
      for port <- Port.list(),
          Port.info(port, :name) == {:name, ~c"tcp_inet"},
          :inet.sockname(port) == {:ok, local},
          :inet.peername(port) == {:ok, peer},
          do: port

    {:connected, owner} = Port.info(port, :connected)
    {:ok, [active: active]} = :inet.getopts(port, [:active])
    {:links, links} = Process.info(owner, :links)
    linked = process_origins(links)

    [supervisor] =
      for %{pid: pid, mfa: {:supervisor, :tls_dyn_connection_sup, 1}} <- linked, do: pid

    children = :supervisor.which_children(supervisor)
    {:receiver, ^owner, :worker, _modules} = List.keyfind(children, :receiver, 0)
    {:sender, sender, :worker, [:tls_sender]} = List.keyfind(children, :sender, 0)
    {states, machines} = machine_states([owner, sender])

    %{
      socket: socket,
      port: port,
      owner: owner,
      local: local,
      peer: peer,
      supervisor: supervisor,
      sender: sender,
      transport: %{port: port, active: active, owner: owner},
      states: states,
      machines: machines,
      processes: process_origins([owner, sender, supervisor])
    }
  end

  defp machine_states(pids) do
    session = :trace.session_create(:ash_onetime_tls_machine_history, self(), [])

    try do
      for mfa <- [{:gen_statem, :system_get_state, 1}, {:gen_statem, :system_continue, 3}] do
        :trace.function(session, mfa, [{:_, [], [{:exception_trace}]}], [:local])
      end

      for pid <- pids do
        1 = :trace.process(session, pid, true, [:call, :strict_monotonic_timestamp])
      end

      states = Map.new(pids, &{&1, :sys.get_state(&1)})
      fence = :trace.delivered(session, :all)

      receive do
        {:trace_delivered, :all, ^fence} -> :ok
      after
        5_000 -> raise "native TLS machine history fence did not arrive"
      end

      machines = Map.new(pids, &{&1, machine_origin(&1, Map.fetch!(states, &1))})
      {states, machines}
    after
      :trace.session_destroy(session)
    end
  end

  defp machine_origin(pid, public_state) do
    {params, state, stamp} =
      receive do
        {:trace_ts, ^pid, :call, {:gen_statem, :system_get_state, [{params, state}]}, stamp} ->
          {params, state, stamp}
      after
        0 -> raise "native TLS machine origin was not captured"
      end

    ^public_state = elem(state, 1)

    receive do
      {:trace_ts, ^pid, :return_from, {:gen_statem, :system_get_state, 1}, {:ok, ^public_state},
       returned}
      when returned > stamp ->
        receive do
          {:trace_ts, ^pid, :call,
           {:gen_statem, :system_continue, [_parent, debug, {^params, ^state}]}, continued}
          when continued > returned ->
            %{
              params: params,
              state: state,
              debug: debug,
              origin: {:historical_tls_machine, pid, stamp},
              debug_origin: {:historical_tls_debug, pid, continued}
            }
        after
          5_000 -> raise "native TLS machine debug origin was not captured"
        end
    after
      0 -> raise "native TLS machine public-state copy was not captured"
    end
  end

  defp process_origins(pids) do
    for pid <- Enum.uniq(pids), is_pid(pid) do
      mfa =
        case :proc_lib.translate_initial_call(pid) do
          {module, function, arity}
          when is_atom(module) and is_atom(function) and is_integer(arity) ->
            {module, function, arity}

          _ ->
            :unknown_initial_call
        end

      %{pid: pid, mfa: mfa}
    end
  end

  def validate(binding) do
    local = :ssl.sockname(binding.socket)
    peer = :ssl.peername(binding.socket)
    transport_local = :inet.sockname(binding.port)
    transport_peer = :inet.peername(binding.port)
    owner = Port.info(binding.port, :connected)
    local_matches? = local == transport_local and local == {:ok, binding.local}

    []
    |> mismatch(:tls_local_endpoint, local_matches?)
    |> mismatch(:tls_peer_endpoint, peer == transport_peer and peer == {:ok, binding.peer})
    |> mismatch(:tls_transport_owner, owner == {:connected, binding.owner})
    |> mismatch(:tls_connection_workers, connection_workers?(binding))
  end

  defp connection_workers?(binding) do
    children = :supervisor.which_children(binding.supervisor)

    match?(
      {:receiver, owner, :worker, _} when owner == binding.owner,
      List.keyfind(children, :receiver, 0)
    ) and List.keyfind(children, :sender, 0) == {:sender, binding.sender, :worker, [:tls_sender]}
  catch
    :exit, _reason -> false
  end

  # Only the public SSL send/recv arguments and returns are PostgreSQL bytes.
  # Encrypted port data never enters the framing or protocol association machine.
  # This ledger grants no event allowance; native interior/copy qualification and
  # the main comparator's consumption remain separate obligations.
  def build(indexed, binding) do
    families = Map.get(binding, :families, [binding])
    transport = NativeTransport.build(indexed, %{}, Enum.map(families, & &1.transport))
    pairs = transport.pairs

    state =
      Enum.reduce(indexed.events, %{pairs: pairs, writes: [], reads: [], errors: []}, fn
        %{event: {_, :call, {:ssl, :send, [socket, data]}}} = source, state
        when socket == binding.socket ->
          write(state, source, binding.port, IO.iodata_to_binary(data))

        %{event: {_, :call, {:ssl, :recv, [socket, length, timeout]}}} = source, state
        when socket == binding.socket ->
          read(state, source, binding.port, length, timeout)

        %{event: {_, :call, {:ssl, function, _arguments}}} = source, state
        when function in [:send, :recv] ->
          %{state | errors: [{source.index, :tls_socket_source} | state.errors]}

        _, state ->
          state
      end)

    helper = sender_copies(indexed.events, pairs, binding)
    workers = worker_states(indexed.events, pairs, binding, helper.terms, transport)

    %{
      pairs: pairs,
      writes: Enum.reverse(state.writes),
      reads: Enum.reverse(state.reads),
      active: [],
      historical: %{},
      transport: transport,
      terms: Enum.reverse(helper.terms) ++ Enum.reverse(workers.terms),
      errors:
        Enum.reverse(state.errors) ++
          transport.errors ++
          Enum.reverse(helper.errors) ++
          Enum.reverse(workers.errors)
    }
  end

  @worker_inputs %{
    {:tls_sender, :connection, 3} => 2,
    {:tls_sender, :send_application_data, 4} => 3,
    {:tls_sender, :send_or_buffer, 5} => 4,
    {:tls_sender, :hibernate_after, 3} => 1,
    {:tls_sender, :send_tls_alert, 2} => 1,
    {:tls_sender, :handle_common, 4} => 3,
    {:tls_client_connection_1_3, :connection, 3} => 2,
    {:tls_gen_connection_1_3, :connection, 3} => 2,
    {:tls_gen_connection, :gen_info, 3} => 2,
    {:tls_gen_connection, :next_event, 3} => 2,
    {:tls_gen_connection, :next_event, 4} => 2,
    {:ssl_gen_statem, :connection, 3} => 2,
    {:ssl_gen_statem, :handle_info, 3} => 2,
    {:ssl_gen_statem, :passive_receive, 3} => 0,
    {:ssl_gen_statem, :read_application_data, 2} => 1,
    {:ssl_gen_statem, :hibernate_after, 3} => 1
  }
  @loop_state_functions [
    :loop,
    :loop_hibernate,
    :loop_wakeup,
    :loop_msg,
    :loop_msg_event,
    :loop_event,
    :loop_state_callback,
    :loop_state_callback_result,
    :loop_actions,
    :loop_actions_list,
    :loop_actions_reply,
    :loop_actions_next_event,
    :loop_state_enter,
    :loop_state_change,
    :loop_state_transition,
    :loop_keep_state,
    :loop_next_events,
    :loop_timeouts,
    :loop_timeouts_cancel,
    :loop_timeouts_register,
    :loop_timeouts_update,
    :loop_t0q,
    :loop_done
  ]
  @loop_next_functions [
    :loop_actions,
    :loop_actions_list,
    :loop_actions_reply,
    :loop_state_transition,
    :loop_keep_state,
    :loop_next_events,
    :loop_timeouts,
    :loop_timeouts_cancel
  ]

  # Native sys:get_state roots precede observation. Gen_statem retains its old
  # StateData while a callback's next StateData is carried separately; only
  # loop_done (or the stopping branch) commits that independently built version.
  defp worker_states(events, pairs, binding, covered, transport) do
    families = Map.get(binding, :families, [binding])

    owners =
      for family <- families,
          {pid, {name, data}} <- family.states,
          into: %{} do
        version = %{name: name, data: data, origin: {:historical_tls, pid}}
        {pid, %{version: version, family: family}}
      end

    initial = %{
      owners: owners,
      pending: %{},
      frames: %{},
      received: %{},
      machine_queues: %{},
      machine_states: Map.new(owners, fn {pid, owner} -> {pid, owner.family.machines[pid]} end),
      machine_callbacks: %{},
      machine_zero: %{},
      messages: %{},
      encoded: %{},
      parsed: %{},
      terms: [],
      errors: [],
      pairs: pairs,
      transport: transport,
      events: events,
      records: %{},
      returns: Map.new(pairs, fn {index, pair} -> {pair.returned.index, index} end),
      covered: MapSet.new(covered, &{&1.index, &1.path})
    }

    receipts =
      (transport.writes ++ transport.reads ++ transport.options)
      |> Enum.flat_map(& &1.indexes)
      |> MapSet.new()
      |> MapSet.union(call_receipts(events, pairs))

    initial = Map.put(initial, :receipts, receipts)

    Enum.reduce(events, initial, fn source, state ->
      if Map.has_key?(owners, source.pid), do: worker_event(source, state), else: state
    end)
  end

  defp worker_event(%{event: {pid, :receive, message}} = source, state) do
    if MapSet.member?(state.receipts, source.index) do
      state
    else
      queue = Map.get(state.received, pid, :queue.new())
      put_in(state.received[pid], :queue.in(%{source: source, message: message}, queue))
    end
  end

  defp worker_event(%{event: {_, :call, {:gen_statem, function, arguments}}} = source, state),
    do: loop_copy(state, source, function, arguments)

  defp worker_event(%{event: {_, :call, {module, function, arguments}}} = source, state) do
    case Map.fetch(@worker_inputs, source.mfa) do
      {:ok, position} -> worker_call(state, source, arguments, position)
      :error -> record_call(state, source, module, function, arguments)
    end
  end

  defp worker_event(%{event: {_, :return_from, _, result}} = source, state),
    do: state |> active_option_return(source) |> worker_return(source, result)

  defp worker_event(_source, state), do: state

  defp loop_copy(state, source, function, arguments) do
    state = loop_commit(state, source.pid, function)
    state = machine_commit(state, source, function)
    version = state.owners[source.pid].version
    next = Map.get(state.pending, source.pid, version)

    state =
      state
      |> machine_metadata(source, function, arguments, version)
      |> loop_current_copy(source, function, version)
      |> loop_next_copy(source, function, version, next)
      |> loop_result_copy(source, function, arguments, next)

    if function == :loop_msg, do: loop_message(state, source, arguments), else: state
  end

  defp machine_metadata(state, source, function, arguments, version) do
    root = state.owners[source.pid].family.machines[source.pid]

    state =
      cond do
        function in @loop_state_functions ->
          state
          |> machine_term(source, [2, 2, 0], root.params, root.origin)
          |> machine_state(source, 2, version)

        function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] ->
          state
          |> machine_term(source, [2, 2, 3], root.params, root.origin)
          |> machine_state(source, 5, version)

        true ->
          state
      end

    machine_queue(state, source, function, arguments)
  end

  defp machine_state(state, source, position, version) do
    root = state.machine_states[source.pid]
    state = machine_term(state, source, [2, 2, position, 1, 0], version.name, version.origin)

    Enum.reduce([0, 2, 3, 4, 5], state, fn field, state ->
      machine_term(state, source, [2, 2, position, field], elem(root.state, field), root.origin)
    end)
  end

  defp machine_queue(state, source, :loop_msg_event, arguments) do
    case Map.get(state.messages, source.pid) do
      %{value: event, origin: origin} = message when origin < source.index ->
        hibernate = Map.get(message, :hibernate, false)
        state = machine_term(state, source, [2, 2, 3], event, {:tls_message, origin})
        state = machine_term(state, source, [2, 2, 4], hibernate, {:tls_message, origin})
        queue = %{events: [event], hibernate: hibernate, origin: origin, fresh?: true}
        put_in(state.machine_queues[source.pid], queue)

      _ ->
        _ = arguments
        tls_failure(state, source, :tls_machine_queue_origin)
    end
  end

  defp machine_queue(state, source, :loop_event, _arguments) do
    case Map.get(state.machine_queues, source.pid) do
      %{events: events, hibernate: hibernate, origin: origin, fresh?: true} = queue ->
        state
        |> machine_term(source, [2, 2, 3], events, {:tls_queue, origin})
        |> machine_term(source, [2, 2, 4], hibernate, {:tls_queue, origin})
        |> put_in([:machine_queues, source.pid], %{queue | fresh?: false})
        |> put_in([:messages, source.pid], %{value: hd(events), origin: origin})

      _ ->
        tls_failure(state, source, :tls_machine_queue_origin)
    end
  end

  defp machine_queue(state, source, :loop_t0q, _arguments) do
    root = state.machine_states[source.pid]

    cursor =
      Map.get(state.machine_zero, source.pid, %{
        timers: elem(root.state, 3),
        events: elem(root.state, 4)
      })

    state = machine_term(state, source, [2, 2, 3], cursor.timers, root.origin)
    state = machine_term(state, source, [2, 2, 4], cursor.events, root.origin)
    machine_zero(state, source, root, cursor)
  end

  defp machine_queue(state, _source, _function, _arguments), do: state

  defp machine_zero(state, source, root, %{events: []} = cursor) do
    expected = root.state |> put_elem(3, cursor.timers) |> put_elem(4, [])

    state
    |> put_in([:machine_states, source.pid], %{root | state: expected, origin: source.index})
    |> Map.update!(:machine_zero, &Map.delete(&1, source.pid))
  end

  defp machine_zero(state, source, root, %{events: [{type, ref} | rest]} = cursor) do
    case Map.get(cursor.timers, type) do
      {^ref, message} ->
        expected = root.state |> put_elem(3, Map.delete(cursor.timers, type)) |> put_elem(4, rest)
        event = %{value: {type, message}, origin: source.index, hibernate: elem(root.state, 5)}

        state
        |> put_in([:machine_states, source.pid], %{root | state: expected, origin: source.index})
        |> put_in([:messages, source.pid], event)
        |> Map.update!(:machine_zero, &Map.delete(&1, source.pid))

      _ ->
        if Map.has_key?(cursor.timers, ref) do
          cursor = %{cursor | timers: Map.delete(cursor.timers, ref), events: rest}
          put_in(state.machine_zero[source.pid], cursor)
        else
          tls_failure(state, source, :tls_machine_zero_origin)
        end
    end
  end

  defp machine_term(state, source, path, expected, origin) do
    actual = native_term(source.event, path)
    state = tls_exact(state, source, :tls_machine_copy, actual, expected)

    state =
      if actual === expected do
        state
      else
        [error | rest] = state.errors
        %{state | errors: [Map.put(error, :path, path) | rest]}
      end

    copy = %{index: source.index, path: path, origin: origin}
    Map.update!(state, :terms, &[copy | &1])
  end

  defp machine_commit(state, source, function)
       when function in [:loop_done, :reply_then_terminate, :do_reply_then_terminate, :terminate] do
    case Map.get(state.machine_callbacks, source.pid) do
      %{fresh?: true} = callback ->
        state = put_in(state.machine_callbacks[source.pid], %{callback | fresh?: false})
        commit_callback(state, source, function, callback)

      _ ->
        state
    end
  end

  defp machine_commit(state, _source, _function), do: state

  defp commit_callback(state, source, :loop_done, callback) do
    root = state.machine_states[source.pid]
    queue = state.machine_queues[source.pid]
    {name, data} = elem(root.state, 1)

    case transition_result(callback.result, name, data) do
      {:ok, next_name, next_data, actions} ->
        transition = transition_actions(root.state, queue, next_name, next_data, actions)
        commit_transition(state, source, callback, root, transition)

      :error ->
        tls_failure(state, source, :tls_machine_result_origin)
    end
  end

  defp commit_callback(state, source, _function, callback) do
    root = state.machine_states[source.pid]
    version = state.owners[source.pid].version
    hibernate = state.machine_queues[source.pid].hibernate
    expected = root.state |> put_elem(1, {version.name, version.data}) |> put_elem(5, hibernate)

    put_in(state.machine_states[source.pid], %{
      root
      | state: expected,
        origin: callback.source.index
    })
  end

  defp transition_result({:next_state, name, data}, _name, _data), do: {:ok, name, data, []}

  defp transition_result({:next_state, name, data, actions}, _name, _data),
    do: {:ok, name, data, List.wrap(actions)}

  defp transition_result({:keep_state, data}, name, _data), do: {:ok, name, data, []}

  defp transition_result({:keep_state, data, actions}, name, _data),
    do: {:ok, name, data, List.wrap(actions)}

  defp transition_result(:keep_state_and_data, name, data), do: {:ok, name, data, []}

  defp transition_result({:keep_state_and_data, actions}, name, data),
    do: {:ok, name, data, List.wrap(actions)}

  defp transition_result(_result, _name, _data), do: :error

  defp transition_actions(old, queue, name, data, actions) do
    initial = %{
      state: put_elem(old, 1, {name, data}),
      hibernate: queue.hibernate,
      postpone: false,
      next: [],
      timeouts: [],
      unknown: []
    }

    transition = Enum.reduce(actions, initial, &transition_action/2)
    [event | rest] = queue.events
    postponed = if transition.postpone, do: [event | elem(old, 2)], else: elem(old, 2)
    changed? = name !== elem(elem(old, 1), 0)
    events = if changed?, do: Enum.reverse(postponed) ++ rest, else: rest
    postponed = if changed?, do: [], else: postponed
    next = transition.state |> put_elem(2, postponed) |> put_elem(5, transition.hibernate)

    Map.merge(transition, %{state: next, events: transition.next ++ events, changed?: changed?})
  end

  defp transition_action(:hibernate, state), do: %{state | hibernate: true}

  defp transition_action({:hibernate, value}, state) when is_boolean(value),
    do: %{state | hibernate: value}

  defp transition_action(:postpone, state), do: %{state | postpone: true}

  defp transition_action({:postpone, value}, state) when is_boolean(value),
    do: %{state | postpone: value}

  defp transition_action({:reply, _from, _reply}, state), do: state

  defp transition_action({:next_event, type, content}, state),
    do: %{state | next: state.next ++ [{type, content}]}

  defp transition_action({type, time, message}, state),
    do: %{state | timeouts: [{type, time, message, []} | state.timeouts]}

  defp transition_action({type, time, message, options}, state),
    do: %{state | timeouts: [{type, time, message, List.wrap(options)} | state.timeouts]}

  defp transition_action({type, :cancel}, state),
    do: %{state | timeouts: [{type, :infinity, :undefined, []} | state.timeouts]}

  defp transition_action(value, state) when is_integer(value) or value == :infinity,
    do: %{state | timeouts: [{:timeout, value, value, []} | state.timeouts]}

  defp transition_action(action, state), do: %{state | unknown: [action | state.unknown]}

  defp commit_transition(state, source, callback, root, transition) do
    state = tls_exact(state, source, :tls_machine_action_origin, transition.unknown, [])
    pairs = machine_timer_pairs(state, source, callback.source.index)
    timers = elem(root.state, 3)

    context = %{
      state: state,
      source: source,
      pairs: pairs,
      timers: timers,
      zero: [],
      seen: MapSet.new()
    }

    context =
      if transition.changed?, do: cancel_machine_timer(context, :state_timeout), else: context

    context = cancel_machine_timer(context, :timeout)
    context = Enum.reduce(transition.timeouts, context, &machine_timeout/2)
    state = tls_exact(context.state, source, :tls_machine_timer_program, context.pairs, [])
    expected = put_elem(transition.state, 3, context.timers)
    expected = put_elem(expected, 4, elem(root.state, 4) ++ context.zero)

    queue = %{
      events: transition.events,
      hibernate: transition.hibernate,
      origin: callback.source.index,
      fresh?: transition.events != []
    }

    state
    |> put_in([:machine_states, source.pid], %{
      root
      | state: expected,
        origin: callback.source.index
    })
    |> put_in([:machine_queues, source.pid], queue)
  end

  defp machine_timer_pairs(state, source, first) do
    state.pairs
    |> Map.values()
    |> Enum.filter(fn pair ->
      pair.source.pid == source.pid and pair.source.index > first and
        pair.returned.index < source.index and
        pair.source.mfa in [
          {:erlang, :start_timer, 4},
          {:erlang, :cancel_timer, 1},
          {:erlang, :make_ref, 0}
        ]
    end)
    |> Enum.sort_by(& &1.source.index)
  end

  defp cancel_machine_timer(context, type) do
    case Map.get(context.timers, type) do
      {ref, _message} ->
        {result, context} = machine_timer_call(context, :cancel_timer, [ref])
        timers = Map.delete(context.timers, type)
        timers = if result == false, do: Map.put(timers, ref, []), else: timers
        %{context | timers: timers}

      nil ->
        context
    end
  end

  defp machine_timeout({type, time, message, options}, context) do
    if MapSet.member?(context.seen, type) do
      context
    else
      context = %{context | seen: MapSet.put(context.seen, type)}
      install_machine_timeout(context, type, time, message, options)
    end
  end

  defp install_machine_timeout(context, type, :infinity, _message, _options),
    do: cancel_machine_timer(context, type)

  defp install_machine_timeout(context, type, :update, message, _options) do
    case Map.get(context.timers, type) do
      {ref, _old} -> %{context | timers: Map.put(context.timers, type, {ref, message})}
      nil -> install_machine_timeout(context, type, 0, message, [])
    end
  end

  defp install_machine_timeout(context, type, time, message, options) do
    {ref, context} =
      if time == 0,
        do: machine_timer_call(context, :make_ref, []),
        else: machine_timer_call(context, :start_timer, [time, context.source.pid, type, options])

    context = cancel_machine_timer(context, type)
    timers = Map.put(context.timers, type, {ref, message})
    zero = if time == 0, do: [{type, ref} | context.zero], else: context.zero
    %{context | timers: timers, zero: zero}
  end

  defp machine_timer_call(%{pairs: [pair | rest]} = context, function, arguments) do
    {_, :call, {module, actual_function, actual}} = pair.source.event
    {_, :return_from, _, result} = pair.returned.event
    expected = {:erlang, function, arguments}

    state =
      tls_exact(
        context.state,
        pair.source,
        :tls_machine_timer_program,
        {module, actual_function, actual},
        expected
      )

    valid? =
      if function == :cancel_timer,
        do: result == false or (is_integer(result) and result >= 0),
        else: is_reference(result)

    state = tls_exact(state, pair.returned, :tls_machine_timer_program, valid?, true)
    {result, %{context | state: state, pairs: rest}}
  end

  defp machine_timer_call(context, _function, _arguments) do
    state = tls_failure(context.state, context.source, :tls_machine_timer_origin)
    {:missing_native_timer, %{context | state: state}}
  end

  defp loop_current_copy(state, source, function, version) do
    cond do
      function in @loop_state_functions ->
        worker_copy(state, source, [2, 2, 2, 1, 1], version.data, version.origin)

      function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] ->
        worker_copy(state, source, [2, 2, 5, 1, 1], version.data, version.origin)

      true ->
        state
    end
  end

  defp loop_next_copy(state, source, function, version, next) do
    cond do
      function in [:loop_state_callback, :loop_state_callback_result] ->
        worker_copy(state, source, [2, 2, 4, 1], version.data, version.origin)

      function in @loop_next_functions ->
        worker_copy(state, source, [2, 2, 4, 1], next.data, next.origin)

      true ->
        state
    end
  end

  defp loop_result_copy(state, source, :loop_state_callback_result, arguments, next) do
    case result_data_path(List.last(arguments)) do
      nil -> state
      path -> worker_copy(state, source, [2, 2, 10 | path], next.data, next.origin)
    end
  end

  defp loop_result_copy(state, _source, _function, _arguments, _next), do: state

  defp loop_commit(state, pid, function)
       when function in [:loop_done, :reply_then_terminate, :do_reply_then_terminate, :terminate] do
    case Map.pop(state.pending, pid) do
      {nil, _pending} ->
        state

      {version, pending} ->
        state |> Map.put(:pending, pending) |> put_in([:owners, pid, :version], version)
    end
  end

  defp loop_commit(state, _pid, _function), do: state

  defp loop_message(state, source, arguments) do
    queue = Map.get(state.received, source.pid, :queue.new())

    case :queue.out(queue) do
      {{:value, %{message: message, source: origin}}, remaining}
      when origin.index < source.index ->
        state = put_in(state.received[source.pid], remaining)
        state = tls_exact(state, source, :tls_event_copy, Enum.at(arguments, 3), message)

        machine_message(state, source.pid, message, origin.index)

      _ ->
        tls_failure(state, source, :tls_event_origin)
    end
  end

  defp machine_message(state, pid, {:timeout, ref, type} = message, origin)
       when is_reference(ref) do
    root = state.machine_states[pid]
    timers = elem(root.state, 3)

    case Map.get(timers, type) do
      {^ref, content} ->
        expected = put_elem(root.state, 3, Map.delete(timers, type))

        state
        |> put_in([:machine_states, pid], %{root | state: expected, origin: origin})
        |> put_in([:messages, pid], %{value: {type, content}, origin: origin})

      _ ->
        if Map.has_key?(timers, ref) do
          expected = put_elem(root.state, 3, Map.delete(timers, ref))

          state
          |> put_in([:machine_states, pid], %{root | state: expected, origin: origin})
          |> Map.update!(:messages, &Map.delete(&1, pid))
        else
          machine_message(state, pid, {:info, message}, origin, :converted)
        end
    end
  end

  defp machine_message(state, pid, message, origin),
    do: machine_message(state, pid, callback_message(message), origin, :converted)

  defp machine_message(state, pid, event, origin, :converted),
    do: put_in(state.messages[pid], %{value: event, origin: origin})

  # Receive tracing records mailbox arrivals. Selective native helpers consume
  # only their independently bound receipts; every other arrival stays FIFO for
  # loop_msg. Receipt selection never grants an observation allowance.
  defp call_receipts(events, pairs) do
    pairs
    |> Map.values()
    |> Enum.flat_map(fn
      %{
        source: %{event: {pid, :call, {module, :call, [target, request | _]}}} = source,
        returned: %{event: {_, :return_from, _, result}} = returned
      }
      when module in [:gen_statem, :gen_server] and is_pid(target) ->
        call_receipt(events, pairs, source, returned, pid, target, request, result)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp call_receipt(events, pairs, source, returned, pid, target, request, result) do
    requests =
      Enum.filter(events, fn
        %{event: {^pid, :send, {:"$gen_call", {^pid, _tag}, ^request}, ^target}} = sent ->
          sent.index > source.index and sent.index < returned.index

        _ ->
          false
      end)

    case requests do
      [%{event: {_, :send, {_, {_, tag}, _}, _}} = sent] ->
        if call_monitor?(pairs, source, sent, pid, target, tag) do
          call_reply(events, sent, returned, pid, target, tag, result)
        else
          []
        end

      _ ->
        []
    end
  end

  defp call_monitor?(pairs, source, sent, pid, target, tag) do
    Enum.any?(pairs, fn
      {_,
       %{
         source: %{event: {^pid, :call, {:erlang, :monitor, arguments}}} = monitor,
         returned: %{event: {_, :return_from, _, ref}} = returned
       }}
      when is_reference(ref) ->
        expected =
          case tag do
            ^ref -> [:process, target]
            [:alias | ^ref] -> [:process, target, [alias: :demonitor]]
            _ -> :invalid_monitor_tag
          end

        arguments === expected and monitor.index > source.index and returned.index < sent.index

      _ ->
        false
    end)
  end

  defp call_reply(events, sent, returned, pid, target, tag, result) do
    destination =
      case tag do
        [:alias | ref] -> ref
        _ -> pid
      end

    replies =
      Enum.filter(events, fn
        %{event: {^target, :send, {^tag, _reply}, ^destination}} = reply ->
          reply.index > sent.index and reply.index < returned.index

        _ ->
          false
      end)

    case replies do
      [reply] ->
        call_reply_received(events, reply, returned, pid, tag, result)

      _ ->
        []
    end
  end

  defp call_reply_received(events, reply, returned, pid, tag, result) do
    {_, :send, message, _} = reply.event

    receipts =
      for %{event: {^pid, :receive, {^tag, _value}}} = received <- events,
          received.index > reply.index and received.index < returned.index,
          do: received

    case receipts do
      [%{event: {_, :receive, ^message}, index: index}] when elem(message, 1) === result ->
        [index]

      _ ->
        []
    end
  end

  defp callback_message({:"$gen_call", from, message}), do: {{:call, from}, message}
  defp callback_message({:"$gen_cast", message}), do: {:cast, message}
  defp callback_message(message), do: {:info, message}

  defp worker_call(state, source, arguments, position) do
    frames = Map.get(state.frames, source.pid, [])
    {state, version} = worker_input(state, source, arguments, frames)
    state = worker_copy(state, source, [2, 2, position], version.data, version.origin)
    state = hibernate_input(state, source, arguments, frames, version)
    frame = %{source: source, input: version, current: version, arguments: arguments}
    frame = Map.put(frame, :event, Map.get(state.messages, source.pid))
    put_in(state.frames[source.pid], [frame | frames])
  end

  defp hibernate_input(
         state,
         %{mfa: {:tls_sender, :hibernate_after, 3}} = source,
         [name, _data, actions],
         [%{source: %{mfa: {:tls_sender, :send_application_data, 4}}} | _],
         version
       ) do
    state
    |> tls_exact(source, :tls_callback_input, name, version.name)
    |> tls_exact(source, :tls_callback_input, actions, [])
  end

  defp hibernate_input(
         state,
         %{mfa: {:tls_sender, :hibernate_after, 3}} = source,
         _arguments,
         _frames,
         _version
       ),
       do: tls_failure(state, source, :tls_callback_input_origin)

  defp hibernate_input(state, _source, _arguments, _frames, _version), do: state

  defp worker_input(state, source, arguments, []) do
    version = state.owners[source.pid].version

    state =
      case Map.get(state.messages, source.pid) do
        %{value: {type, message}} ->
          state
          |> tls_exact(source, :tls_event_copy, Enum.at(arguments, 0), type)
          |> tls_exact(source, :tls_event_copy, Enum.at(arguments, 1), message)

        nil ->
          tls_failure(state, source, :tls_event_origin)
      end

    {state, version}
  end

  defp worker_input(state, source, arguments, [parent | _]) do
    case source.mfa do
      {:ssl_gen_statem, :passive_receive, 3} ->
        recv_input(state, source, parent)

      {:tls_sender, :send_or_buffer, 5} ->
        {state, version} = sender_constructed(state, source, parent)
        {sender_forward_copies(state, source, arguments, parent), version}

      {:tls_gen_connection, :next_event, 4} ->
        buffered_input(state, source, parent)

      {:tls_gen_connection, :next_event, 3} ->
        passive_input(state, source, parent)

      _ ->
        _ = arguments
        {state, parent.current}
    end
  end

  defp passive_input(
         state,
         source,
         %{source: %{mfa: {:tls_gen_connection, :gen_info, 3}}} = parent
       ) do
    family = state.owners[source.pid].family

    case parent.event do
      %{value: {:info, {:tcp_passive, port}}, origin: origin} when port == family.port ->
        bound? = Enum.any?(state.transport.passive, &(&1.received.index == origin))
        state = tls_exact(state, source, :tls_passive_origin, bound?, true)
        passive_transition(state, source, parent)

      _ ->
        {state, parent.current}
    end
  end

  defp passive_input(state, _source, parent), do: {state, parent.current}

  defp passive_transition(state, source, parent) do
    version = parent.current
    data = version.data
    receiving? = elem(elem(data, 9), 1) != :undefined
    empty? = elem(elem(data, 11), 3) == []
    options = active_options(state, parent.source.index, source)

    if receiving? and empty? do
      state = tls_exact(state, source, :tls_passive_option, length(options), 1)
      {state, version}
    else
      state = tls_exact(state, source, :tls_passive_option, options, [])
      specific = Map.put(elem(data, 7), :active_n_toggle, true)

      version = %{
        version
        | data: put_elem(data, 7, specific),
          origin: {:tls_passive, parent.source.index, parent.event.origin, version.origin}
      }

      {state, version}
    end
  end

  defp active_options(state, first, source) do
    port = state.owners[source.pid].family.port

    Enum.filter(state.transport.options, fn option ->
      option.port == port and option.source.pid == source.pid and
        option.source.index > first and option.returned.index < source.index and
        is_integer(option.mode)
    end)
  end

  defp active_option_return(state, %{mfa: {:prim_inet, :setopts, 2}} = source) do
    family = state.owners[source.pid].family

    options =
      Enum.filter(state.transport.options, &(&1.returned.index == source.index))

    case {options, Map.get(state.frames, source.pid, [])} do
      {[%{mode: mode} = option], [frame | rest]}
      when is_integer(mode) and source.pid == family.owner ->
        version = frame.current
        specific = elem(version.data, 7)
        expected = Map.fetch!(specific, :active_n)
        state = tls_exact(state, source, :tls_active_option_copy, mode, expected)

        specific =
          specific |> Map.put(:active_n_toggle, false) |> Map.put(:socket_active, expected)

        version = %{
          version
          | data: put_elem(version.data, 7, specific),
            origin: {:tls_active_option, option.source.index, source.index}
        }

        put_in(state.frames[source.pid], [%{frame | current: version} | rest])

      _ ->
        state
    end
  end

  defp active_option_return(state, _source), do: state

  defp recv_input(state, source, parent) do
    case parent.event do
      %{value: {{:call, from}, {:recv, length, _timeout}}} ->
        version = parent.current
        recv = elem(version.data, 9) |> put_elem(1, from) |> put_elem(2, length)
        origin = {:tls_recv, parent.source.index, parent.event.origin}
        {state, %{version | data: put_elem(version.data, 9, recv), origin: origin}}

      _ ->
        {tls_failure(state, source, :tls_recv_origin), parent.current}
    end
  end

  defp sender_constructed(state, source, parent) do
    case Map.get(state.encoded, source.pid) do
      %{result: {_bytes, states}, origin: origin, plaintext: plaintext} ->
        data = parent.input.data

        data =
          data |> put_elem(2, states) |> put_elem(3, elem(data, 3) + IO.iodata_length(plaintext))

        {state, %{parent.input | data: data, origin: origin}}

      nil ->
        {tls_failure(state, source, :tls_encode_origin), parent.current}
    end
  end

  defp sender_forward_copies(state, source, arguments, parent) do
    [transport, socket, records, from, _data] = arguments
    family = state.owners[source.pid].family
    environment = elem(parent.input.data, 1)
    expected = {elem(environment, 5), family.port, Enum.at(parent.arguments, 1)}
    actual = {transport, socket, from}
    state = tls_exact(state, source, :tls_forward_copy, actual, expected)

    case Map.get(state.encoded, source.pid) do
      %{result: {expected, _states}, origin: origin} ->
        state = tls_exact(state, source, :tls_record_copy, records, expected)
        copy = %{index: source.index, path: [2, 2, 2], origin: origin}
        Map.update!(state, :terms, &[copy | &1])

      nil ->
        tls_failure(state, source, :tls_encode_origin)
    end
  end

  defp buffered_input(
         state,
         source,
         %{source: %{mfa: {:ssl_gen_statem, :passive_receive, 3}}} = parent
       ) do
    if elem(elem(parent.current.data, 12), 1) > 0,
      do: consume_buffer(state, source, parent.current, elem(parent.current.data, 12)),
      else: {state, parent.current}
  end

  defp buffered_input(state, _source, parent), do: {state, parent.current}

  defp worker_copy(state, source, path, expected, origin) do
    if MapSet.member?(state.covered, {source.index, path}) do
      state
    else
      actual = native_term(source.event, path)
      state = tls_exact(state, source, :tls_worker_state_copy, actual, expected)

      copy = %{index: source.index, path: path, origin: origin}
      Map.update!(state, :terms, &[copy | &1])
    end
  end

  defp native_term(value, []), do: value

  defp native_term(value, [position | path]) when is_tuple(value),
    do: native_term(elem(value, position), path)

  defp native_term(value, [position | path]) when is_list(value),
    do: native_term(Enum.at(value, position), path)

  defp result_data_path({:next_state, _, _}), do: [2]
  defp result_data_path({:next_state, _, _, _}), do: [2]
  defp result_data_path({:stop_and_reply, _, _, _}), do: [3]
  defp result_data_path({:stop, _, _}), do: [2]
  defp result_data_path({:keep_state, _}), do: [1]
  defp result_data_path({:keep_state, _, _}), do: [1]
  defp result_data_path({:ok, _}), do: [1]
  defp result_data_path({:no_record, _}), do: [1]
  defp result_data_path({:data, _, _, _, _}), do: []
  defp result_data_path(_result), do: nil

  defp record_call(state, source, :tls_sender, :send_reply, arguments) do
    frame = List.first(Map.get(state.frames, source.pid, []))
    family = state.owners[source.pid].family

    case {frame, Map.get(state.messages, source.pid)} do
      {%{source: parent}, %{value: {{:call, from}, {:application_data, _data}}} = message} ->
        writes =
          Enum.filter(state.transport.writes, fn write ->
            write.port == family.port and write.source.pid == source.pid and
              write.source.index > parent.index and write.returned.index < source.index
          end)

        case writes do
          [write] ->
            {_, :return_from, {:gen_tcp, :send, 2}, reply} = write.returned.event
            state = tls_exact(state, source, :tls_reply_copy, arguments, [from, reply])
            origin = {:tls_reply, message.origin, write.returned.index}
            copy = %{index: source.index, path: [2, 2], origin: origin}
            Map.update!(state, :terms, &[copy | &1])

          _ ->
            tls_failure(state, source, :tls_reply_origin)
        end

      _ ->
        tls_failure(state, source, :tls_reply_origin)
    end
  end

  defp record_call(state, source, module, :encode_data, arguments)
       when module in [:tls_record, :tls_record_1_3] do
    case sender_plaintext(state, source) do
      {:ok, plaintext} ->
        frame = hd(state.frames[source.pid])
        data = frame.input.data
        version = elem(elem(data, 1), 6)
        states = elem(data, 2)

        expected_args =
          if module == :tls_record, do: [plaintext, version, states], else: [plaintext, states]

        expected = :tls_record.encode_data(plaintext, version, states)

        state
        |> tls_exact(source, :tls_record_input, arguments, expected_args)
        |> put_in([:records, source.index], %{
          result: expected,
          kind: :encode,
          plaintext: plaintext
        })

      :error ->
        tls_failure(state, source, :tls_plaintext_origin)
    end
  end

  defp record_call(state, source, :tls_record, :get_tls_records, arguments) do
    frame = hd(state.frames[source.pid])
    version = frame.input
    data = version.data
    family = state.owners[source.pid].family

    case frame.event do
      %{value: {:info, {:tcp, port, bytes}}} when port == family.port ->
        buffers = elem(data, 11)
        environment = elem(data, 3)

        expected_args = [
          bytes,
          elem(environment, 5),
          elem(buffers, 1),
          Map.get(elem(data, 10), :max_fragment_length, :undefined),
          elem(environment, 2)
        ]

        {records, buffer} = expected = apply(:tls_record, :get_tls_records, expected_args)

        parsed = %{
          input: version,
          buffer: buffer,
          remaining: elem(buffers, 3) ++ records,
          states: elem(data, 10),
          fragments: [],
          origin: source.index
        }

        state
        |> tls_exact(source, :tls_record_input, arguments, expected_args)
        |> put_in([:records, source.index], %{result: expected, kind: :records, parsed: parsed})

      _ ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp record_call(state, source, module, :decode_cipher_text, arguments)
       when module in [:tls_record, :tls_record_1_3] do
    case Map.get(state.parsed, source.pid) do
      %{remaining: [record | _], states: states, input: input} ->
        expected_args =
          if module == :tls_record_1_3,
            do: [record, states],
            else: [
              elem(elem(input.data, 3), 5),
              record,
              states,
              Map.get(elem(input.data, 4), :padding_check, true)
            ]

        expected = apply(module, :decode_cipher_text, expected_args)

        nested? =
          Enum.any?(state.records, fn {_index, record} ->
            Map.get(record, :pid) == source.pid and record.kind == :decode
          end)

        kind = if nested?, do: :decode_copy, else: :decode

        state
        |> tls_exact(source, :tls_record_input, arguments, expected_args)
        |> put_in([:records, source.index], %{result: expected, kind: kind, pid: source.pid})

      _ ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp record_call(state, _source, _module, _function, _arguments), do: state

  defp sender_plaintext(state, source) do
    case Map.get(state.messages, source.pid) do
      %{value: {{:call, {caller, _tag}}, {:application_data, _data}}} ->
        socket = state.owners[source.pid].family.socket

        writes =
          Enum.filter(Map.values(state.pairs), fn pair ->
            pair.source.pid == caller and pair.source.mfa == {:ssl, :send, 2} and
              pair.source.index < source.index and pair.returned.index > source.index
          end)

        case writes do
          [%{source: %{event: {_, :call, {:ssl, :send, [^socket, data]}}}}] ->
            {:ok, :erlang.iolist_to_iovec(data)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp worker_return(state, source, result) do
    call = Map.get(state.returns, source.index)

    case Map.pop(state.records, call) do
      {nil, _records} ->
        worker_frame_return(state, source, result)

      {record, records} ->
        state
        |> Map.put(:records, records)
        |> tls_exact(source, :tls_record_output, result, record.result)
        |> record_return(source, record)
    end
  end

  defp record_return(state, source, %{kind: :encode} = record),
    do: put_in(state.encoded[source.pid], Map.put(record, :origin, {:tls_record, source.index}))

  defp record_return(state, source, %{kind: :records, parsed: parsed}) do
    parsed = %{parsed | origin: source.index}
    state = put_in(state.parsed[source.pid], parsed)
    decoded_state(state, source, parsed)
  end

  defp record_return(state, source, %{kind: :decode, result: {record, states}}) do
    parsed = Map.fetch!(state.parsed, source.pid)
    [_cipher | remaining] = parsed.remaining

    case record do
      {:ssl_tls, 23, _version, fragment, _early_data} ->
        parsed = %{
          parsed
          | remaining: remaining,
            states: states,
            fragments: parsed.fragments ++ [fragment],
            origin: source.index
        }

        state = put_in(state.parsed[source.pid], parsed)
        decoded_state(state, source, parsed)

      _ ->
        tls_failure(state, source, :tls_application_record_origin)
    end
  end

  defp record_return(state, _source, _record), do: state

  defp decoded_state(state, source, %{remaining: []} = parsed) do
    data = parsed.input.data
    buffers = elem(data, 11) |> put_elem(1, parsed.buffer) |> put_elem(3, [])
    data = data |> put_elem(10, parsed.states) |> put_elem(11, buffers)
    version = %{parsed.input | data: data, origin: {:tls_decode, source.index}}
    [frame | rest] = state.frames[source.pid]
    put_in(state.frames[source.pid], [%{frame | current: version} | rest])
  end

  defp decoded_state(state, _source, _parsed), do: state

  defp worker_frame_return(state, source, result) do
    case Map.get(state.frames, source.pid, []) do
      [%{source: %{mfa: mfa}} = frame | rest] when mfa == source.mfa ->
        {state, version} = worker_output(state, source, frame)
        state = callback_result(state, source, frame, version, result)
        path = result_data_path(result)

        state =
          if path,
            do: worker_copy(state, source, [3 | path], version.data, version.origin),
            else: state

        state = put_in(state.frames[source.pid], rest)

        state =
          if rest == [],
            do:
              put_in(state.machine_callbacks[source.pid], %{
                source: source,
                result: result,
                fresh?: true
              }),
            else: state

        advance_worker(state, source, version, rest)

      _ ->
        state
    end
  end

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :hibernate_after, 3}} = source,
         _frame,
         version,
         actual
       ) do
    timeout = elem(elem(version.data, 1), 11)

    expected =
      if version.name == :connection and timeout != :infinity do
        {:next_state, :connection, version.data, [{:timeout, timeout, :hibernate}]}
      else
        {:next_state, version.name, version.data}
      end

    tls_exact(state, source, :tls_callback_result, actual, expected)
  end

  defp callback_result(state, _source, _frame, _version, _actual), do: state

  defp advance_worker(state, source, version, []) do
    version = %{version | origin: {:tls_callback_return, source.index}}
    put_in(state.pending[source.pid], version)
  end

  defp advance_worker(state, source, version, [parent | rest]),
    do: put_in(state.frames[source.pid], [%{parent | current: version} | rest])

  defp worker_output(state, source, %{source: %{mfa: {:tls_sender, :send_tls_alert, 2}}} = frame) do
    case sender_alert(frame.event) do
      {:ok, alert} ->
        state = tls_exact(state, frame.source, :tls_alert_copy, hd(frame.arguments), alert)
        data = frame.input.data

        {_bytes, states} =
          :tls_record.encode_alert_record(alert, elem(elem(data, 1), 6), elem(data, 2))

        {state,
         %{frame.input | data: put_elem(data, 2, states), origin: {:tls_alert, source.index}}}

      :error ->
        {tls_failure(state, source, :tls_alert_origin), frame.current}
    end
  end

  defp worker_output(
         state,
         source,
         %{source: %{mfa: {:ssl_gen_statem, :read_application_data, 2}}} = frame
       ) do
    case Map.get(state.parsed, source.pid) do
      %{fragments: fragments, remaining: []} ->
        expected = IO.iodata_to_binary(fragments)
        state = tls_exact(state, frame.source, :tls_plaintext_copy, hd(frame.arguments), expected)
        delivered_state(state, source, frame.input, expected)

      _ ->
        {tls_failure(state, source, :tls_plaintext_origin), frame.current}
    end
  end

  defp worker_output(state, source, frame) do
    case {frame.source.mfa, frame.event} do
      {{:ssl_gen_statem, :connection, 3}, %{value: {{:call, _}, {:close, _}}}} ->
        data = frame.input.data
        environment = put_elem(elem(data, 3), 3, true)

        {state,
         %{frame.input | data: put_elem(data, 3, environment), origin: {:tls_close, source.index}}}

      _ ->
        {state, frame.current}
    end
  end

  defp sender_alert(%{value: {{:call, _from}, {:ack_alert, alert}}}), do: {:ok, alert}
  defp sender_alert(%{value: {:cast, alert}}), do: {:ok, alert}
  defp sender_alert(_event), do: :error

  defp delivered_state(state, source, version, plaintext) do
    data = version.data
    {:socket_options, :binary, packet, _max_packet, 0, false} = elem(data, 5)
    true = packet in [0, :raw]
    {front, size, rear} = elem(data, 12)

    consume_buffer(
      state,
      source,
      version,
      {front, size + byte_size(plaintext), [plaintext | rear]}
    )
  end

  defp consume_buffer(state, source, version, {_front, 0, _rear}) do
    data = put_elem(version.data, 12, {[], 0, []})
    {state, %{version | data: data, origin: {:tls_empty_buffer, source.index}}}
  end

  defp consume_buffer(state, source, version, {front, size, rear}) do
    {front, rear, bytes} = queued_binary(front, rear)
    recv = elem(version.data, 9)
    required = elem(recv, 2)
    buffer = {[bytes | front], size, rear}

    case required do
      :undefined -> buffered_state(state, source, version, buffer, recv)
      count when count > size -> buffered_state(state, source, version, buffer, recv)
      count -> consume_requested(state, source, version, bytes, front, rear, size, count)
    end
  end

  defp consume_requested(state, source, version, bytes, front, rear, size, required) do
    count = if required == 0, do: byte_size(bytes), else: required

    {front, rear, remaining} =
      if byte_size(bytes) >= count do
        <<_delivered::binary-size(^count), remaining::binary>> = bytes
        {front, rear, remaining}
      else
        {front, rear} = consume_queue(count - byte_size(bytes), front, rear)
        {front, rear, <<>>}
      end

    recv = elem(version.data, 9) |> put_elem(1, :undefined) |> put_elem(2, :undefined)
    buffered_state(state, source, version, {[remaining | front], size - count, rear}, recv)
  end

  defp buffered_state(state, source, version, buffer, recv) do
    data = version.data |> put_elem(9, recv) |> put_elem(12, buffer)
    {state, %{version | data: data, origin: {:tls_user_buffer, source.index}}}
  end

  defp queued_binary([<<>> | front], rear), do: queued_binary(front, rear)
  defp queued_binary([bytes | front], rear), do: {front, rear, bytes}
  defp queued_binary([], rear), do: queued_binary(Enum.reverse(rear), [])

  defp consume_queue(0, front, rear), do: {front, rear}
  defp consume_queue(count, [], rear), do: consume_queue(count, Enum.reverse(rear), [])

  defp consume_queue(count, [bytes | front], rear) when byte_size(bytes) <= count,
    do: consume_queue(count - byte_size(bytes), front, rear)

  defp consume_queue(count, [bytes | front], rear) do
    <<_consumed::binary-size(^count), rest::binary>> = bytes
    {[rest | front], rear}
  end

  defp sender_copies(events, pairs, binding) do
    Enum.reduce(events, %{terms: [], errors: []}, fn
      %{event: {pid, :call, {:tls_sender, :send_application_data, arguments}}} = source, state
      when pid == binding.sender ->
        sender_copy(state, source, arguments, pairs)

      _source, state ->
        state
    end)
  end

  defp sender_copy(state, source, [data, from, :connection, actual], pairs) do
    parent =
      pairs
      |> Map.values()
      |> Enum.filter(fn pair ->
        pair.source.pid == source.pid and pair.source.mfa == {:tls_sender, :connection, 3} and
          pair.source.index < source.index and pair.returned.index > source.index
      end)
      |> Enum.max_by(& &1.source.index, fn -> nil end)

    case parent do
      %{
        source:
          %{
            event:
              {_, :call,
               {_, _, [{:call, expected_from}, {:application_data, expected_data}, expected]}}
          } = origin
      } ->
        state
        |> tls_copy(source, [2, 2, 0], data, expected_data, origin.index)
        |> tls_copy(source, [2, 2, 1], from, expected_from, origin.index)
        |> tls_copy(source, [2, 2, 3], actual, expected, origin.index)

      _ ->
        tls_failure(state, source, :tls_state_origin)
    end
  end

  defp sender_copy(state, source, _arguments, _pairs),
    do: tls_failure(state, source, :tls_state_origin)

  defp tls_copy(state, source, path, actual, expected, origin) do
    state = tls_exact(state, source, :tls_state_copy, actual, expected)
    copy = %{index: source.index, path: path, origin: {:tls_callback, origin}}
    Map.update!(state, :terms, &[copy | &1])
  end

  defp tls_exact(state, _source, _rule, actual, expected) when actual === expected, do: state

  defp tls_exact(state, source, rule, actual, expected) do
    state = tls_failure(state, source, rule)
    [error | errors] = state.errors
    differences = tls_difference_paths(actual, expected)
    %{state | errors: [Map.put(error, :differences, differences) | errors]}
  end

  defp tls_difference_paths(actual, expected)
       when is_tuple(actual) and is_tuple(expected) and tuple_size(actual) == tuple_size(expected) do
    for position <- 0..(tuple_size(expected) - 1),
        elem(actual, position) !== elem(expected, position),
        do: %{path: [position]}
  end

  defp tls_difference_paths(_actual, _expected), do: []

  defp tls_failure(state, source, rule) do
    error = %{
      index: source.index,
      at: Map.take(source, [:mfa, :role, :stack]),
      rule: rule,
      actual: false,
      expected: true
    }

    Map.update!(state, :errors, &[error | &1])
  end

  defp write(state, source, port, bytes) do
    case Map.fetch(state.pairs, source.index) do
      {:ok, %{returned: %{event: {_, :return_from, {:ssl, :send, 2}, :ok}} = returned}} ->
        write = %{
          source: source,
          command: source,
          returned: returned,
          port: port,
          bytes: bytes,
          header_size: 0,
          copies: [copy(source, [2, 2, 1], bytes)]
        }

        %{state | writes: [write | state.writes]}

      _ ->
        %{state | errors: [{source.index, :tls_write_return} | state.errors]}
    end
  end

  defp read(state, source, port, length, timeout) do
    case Map.fetch(state.pairs, source.index) do
      {:ok, %{returned: %{event: {_, :return_from, {:ssl, :recv, 3}, {:ok, bytes}}} = returned}}
      when is_binary(bytes) ->
        read = %{
          source: source,
          returned: returned,
          delivered: returned,
          port: port,
          length: length,
          timeout: timeout,
          result: {:ok, bytes},
          bytes: bytes,
          provenance: source.index,
          copies: [copy(returned, [3, 1], bytes)]
        }

        %{state | reads: [read | state.reads]}

      _ ->
        %{state | errors: [{source.index, :tls_read_return} | state.errors]}
    end
  end

  defp copy(source, path, bytes),
    do: %{index: source.index, path: path, offset: 0, length: byte_size(bytes)}

  defp mismatch(errors, _rule, true), do: errors
  defp mismatch(errors, rule, false), do: errors ++ [rule]
end
