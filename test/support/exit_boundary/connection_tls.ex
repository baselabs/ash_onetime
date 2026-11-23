defmodule AshOnetime.Test.ExitBoundary.ConnectionTls do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.Diagnostics
  alias AshOnetime.Test.ExitBoundary.NativeTransport

  # Local formatter metadata must be frozen while a native owner mutant is
  # loaded. Its expected identity comes from that owner's independent BEAM.
  def freeze_debug(events, binding) do
    formatters =
      for %{event: {_, :call, {:sys, :handle_debug, [_, formatter, _, _]}}} <- events,
          is_function(formatter),
          do: formatter

    observations = Map.new(formatters, &{&1, formatter_observation(&1)})

    identity =
      if formatters != [], do: Compiled.identity(:gen_statem, :print_event, 3), else: nil

    binding
    |> Map.put(:debug_observations, observations)
    |> Map.put(:debug_formatter, {:compiled_formatter, identity, []})
  end

  defp formatter_observation(formatter) do
    info = Map.new(Function.info(formatter))

    if info.type == :local do
      identity = {info.module, info.name, info.arity, info.new_uniq, info.index}
      {:compiled_formatter, identity, info.env}
    else
      {:external_formatter, info.module, info.name, info.arity}
    end
  end

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

  # Pool workers predate a caller's observation. Bind their public socket and
  # native machine roots before arming, and trace their actual callbacks as
  # persistent services rather than waiting for shared processes to exit.
  def pooled_services do
    sockets =
      for table <- :ets.all(),
          :ets.info(table, :name) == DBConnection.Holder,
          {:conn, _owner, Postgrex.Protocol, %{sock: {:ssl, socket}}, _, _, _, _} <-
            :ets.lookup(table, :conn),
          do: socket

    bindings = Enum.map(Enum.uniq(sockets), &bind/1)

    services =
      for binding <- bindings,
          {worker, pid} <- [receiver: binding.owner, sender: binding.sender],
          into: %{} do
        root = Map.fetch!(binding.machines, pid)
        :state_functions = elem(root.params, 1)
        [module | _] = elem(root.params, 4)
        {state, _data} = Map.fetch!(binding.states, pid)

        {{:tls_worker, binding.port, worker},
         %{
           kind: :state_machine,
           pid: pid,
           port: binding.port,
           owner: binding.owner,
           sender: binding.sender,
           worker: worker,
           callback: {module, state, 3}
         }}
      end

    %{bindings: bindings, services: services}
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

  # Born workers acquire their roots at their native entry, never at a later
  # system-state read. A public socket is a copy of this exact constructor.
  def births(indexed) do
    pairs = NativeTransport.pairs(indexed.events)

    connects =
      for {_index, pair} <- pairs,
          {_, :call, {:ssl, :connect, [port, _options, _timeout]}} <- [pair.source.event],
          is_port(port),
          {_, :return_from, _, {:ok, _socket}} <- [pair.returned.event],
          do: pair

    Enum.reduce(connects, %{bindings: [], errors: []}, fn connect, result ->
      case birth_binding(indexed.events, pairs, connect) do
        {:ok, binding} ->
          %{result | bindings: result.bindings ++ [binding]}

        :error ->
          error = %{
            index: connect.source.index,
            at: Map.take(connect.source, [:mfa, :role, :stack]),
            rule: :tls_birth_origin,
            actual: :unbound_constructor_chain,
            expected: :same_native_socket_workers_and_entries
          }

          %{result | errors: result.errors ++ [error]}
      end
    end)
  end

  defp birth_binding(events, pairs, connect) do
    {caller, :call, {:ssl, :connect, [port, _options, _timeout]}} = connect.source.event
    {_, :return_from, _, {:ok, socket}} = connect.returned.event
    interval = birth_calls(pairs, connect.source.index, connect.returned.index)

    with [tcp] <- Enum.filter(Map.values(pairs), &birth_tcp?(&1, caller, port)),
         true <- tcp.returned.index < connect.source.index,
         [constructed] <- Enum.filter(interval, &birth_socket?(&1, port, socket)),
         {receiver, :call,
          {:tls_socket, :socket,
           [[receiver, sender], :gen_tcp, ^port, :tls_gen_connection, table, _trackers]}} <-
           constructed.source.event,
         [created] <- Enum.filter(interval, &birth_constructor?(&1, receiver, sender, table, port)),
         {^receiver, :call,
          {constructor, :initial_state,
           [:client, ^sender, ^table, host, remote_port, ^port, options, ^caller, callbacks]}} <-
           created.source.event,
         {^receiver, :return_from, _, initial} <- created.returned.event,
         [table_origin] <- Enum.filter(interval, &birth_table?(&1, receiver, table)),
         true <- table_origin.returned.index < created.source.index,
         true <- created.source.index < constructed.source.index,
         true <- constructed.returned.index < created.returned.index,
         true <-
           birth_initial?(initial, {table, host, remote_port, port, options, callbacks, socket, sender}),
         client = birth_client(options),
         true <- constructor == elem(client, 1),
         true <- birth_client_init?(events, created, elem(client, 0)),
         [configured] <- Enum.filter(interval, &birth_configuration?(&1, receiver, initial)),
         true <- created.returned.index < configured.source.index,
         [entry] <- birth_entries(events, receiver, elem(client, 0), :initial_hello),
         before_entry = Enum.filter(interval, &(&1.returned.index < entry.index)),
         {:ok, entered} <- birth_client_state(before_entry, receiver, elem(client, 0), configured),
         true <- Enum.at(elem(elem(entry.event, 2), 2), 6) === entered,
         {^receiver, :call, {_, _, [supervisor | _]}} <- entry.event,
         true <- configured.returned.index < entry.index,
         [tree] <- Enum.filter(interval, &birth_supervisor?(&1, supervisor)),
         [sender_init] <- Enum.filter(interval, &(&1.source.mfa == {:tls_sender, :init, 1})),
         {^sender, :return_from, _, {:ok, :init, sender_data}} <- sender_init.returned.event,
         [sender_entry] <- birth_entries(events, sender, :tls_sender, :init, sender_data),
         {^sender, :call, {_, _, [^supervisor | _]}} <- sender_entry.event,
         true <- sender_init.returned.index < sender_entry.index,
         true <- birth_spawn?(events, supervisor, receiver) and birth_spawn?(events, supervisor, sender),
         true <- tree.source.index < entry.index,
         [factory] <- Enum.filter(interval, &birth_factory?(&1, caller, host, remote_port, port, options, callbacks)),
         true <- factory.source.index < created.source.index and entry.index < factory.returned.index,
         true <- birth_options?(interval, receiver, factory, options, created),
         {:ok, options_receipt} <- birth_options_receipt(events, tree, factory, receiver, supervisor),
         [handoff] <- Enum.filter(interval, &birth_handoff?(&1, caller, port, receiver)),
         true <- constructed.returned.index < handoff.source.index,
         {:ok, receiver_machine} <- birth_machine(interval, entry, elem(client, 0), entered),
         {:ok, sender_machine} <- birth_machine(interval, sender_entry, :tls_sender, sender_data) do
      {:ok,
       %{
         socket: socket,
         port: port,
         owner: receiver,
         sender: sender,
         supervisor: supervisor,
         upgrade_index: connect.source.index,
         transport: %{port: port, active: false, owner: receiver},
         states: %{receiver => {:initial_hello, entered}, sender => {:init, sender_data}},
         machines: %{receiver => receiver_machine, sender => sender_machine},
         receipts: [options_receipt.index],
         born?: true
       }}
    else
      _ -> :error
    end
  end

  defp birth_calls(pairs, first, last) do
    for {_index, pair} <- pairs,
        pair.source.index > first and pair.returned.index < last,
        do: pair
  end

  defp birth_socket?(pair, port, socket) do
    match?(
      {_, :call, {:tls_socket, :socket, [[_, _], :gen_tcp, ^port, :tls_gen_connection, _, _]}},
      pair.source.event
    ) and match?({_, :return_from, _, ^socket}, pair.returned.event)
  end

  defp birth_tcp?(pair, caller, port) do
    case {pair.source.event, pair.returned.event} do
      {{^caller, :call, {:gen_tcp, :connect, [_, _, options, _]}},
       {^caller, :return_from, _, {:ok, ^port}}} ->
        Keyword.fetch(options, :active) == {:ok, false}

      _ ->
        false
    end
  end

  defp birth_constructor?(pair, receiver, sender, table, port) do
    pair.source.mfa in [
      {:tls_gen_connection_1_3, :initial_state, 9},
      {:tls_dtls_gen_connection, :initial_state, 9}
    ] and
      match?(
        {^receiver, :call, {_, _, [:client, ^sender, ^table, _, _, ^port, _, _, _]}},
        pair.source.event
      )
  end

  defp birth_table?(pair, receiver, table),
    do:
      pair.source.event == {receiver, :call, {:ets, :new, [:tls_socket, []]}} and
        pair.returned.event == {receiver, :return_from, {:ets, :new, 2}, table}

  defp birth_client(options) do
    if Map.fetch!(elem(options, 0), :versions) == [{3, 4}],
      do: {:tls_client_connection_1_3, :tls_gen_connection_1_3},
      else: {:tls_client_connection, :tls_dtls_gen_connection}
  end

  defp birth_initial?(initial, {table, host, remote_port, port, options, callbacks, socket, sender})
       when is_tuple(initial) and tuple_size(initial) == 13 do
    environment = elem(initial, 2)

    Enum.all?(
      [
        {elem(initial, 0), :state},
        {elem(initial, 1), table},
        {elem(initial, 4), elem(options, 0)},
        {elem(initial, 5), elem(options, 1)},
        {elem(environment, 1), :client},
        {elem(environment, 2), socket},
        {elem(environment, 3), elem(callbacks, 0)},
        {elem(environment, 4), :tls_gen_connection},
        {elem(environment, 9), host},
        {elem(environment, 10), remote_port},
        {elem(environment, 11), port},
        {Map.fetch!(elem(initial, 7), :sender), sender}
      ],
      fn {actual, expected} -> actual === expected end
    )
  end

  defp birth_initial?(_initial, _context), do: false

  defp birth_client_init?(events, created, client) do
    {pid, :call, {_, _, arguments}} = created.source.event

    Enum.any?(events, fn source ->
      source.event == {pid, :call, {client, :init, [arguments]}} and
        source.index < created.source.index
    end)
  end

  defp birth_configuration?(pair, receiver, initial),
    do:
      pair.source.event ==
        {receiver, :call, {:ssl_gen_statem, :init_ssl_config, [elem(initial, 4), :client, initial]}}

  defp birth_client_state(_calls, _receiver, :tls_client_connection_1_3, configured) do
    {_, :return_from, _, state} = configured.returned.event
    {:ok, state}
  end

  defp birth_client_state(calls, receiver, :tls_client_connection, configured) do
    {_, :return_from, _, state} = configured.returned.event
    environment = elem(state, 2)
    alternatives = elem(elem(state, 3), 7)

    with [certificates] <-
           Enum.filter(calls, &(&1.source.event == {receiver, :call, {:ssl_certificate, :available_cert_key_pairs, [alternatives]}})),
         {_, :return_from, _, certificate_pairs} <- certificates.returned.event,
         [selection] <-
           Enum.filter(calls, fn pair ->
             pair.source.event ==
               {receiver, :call,
                {:ssl_session, :client_select_session,
                 [{elem(environment, 9), elem(environment, 10), elem(state, 4)}, elem(environment, 13),
                  elem(environment, 14), elem(state, 8), certificate_pairs]}}
           end),
         true <- configured.returned.index < certificates.source.index,
         true <- certificates.returned.index < selection.source.index,
         {_, :return_from, _, session} <- selection.returned.event do
      {:ok, put_elem(state, 8, session)}
    else
      _ -> :error
    end
  end

  defp birth_entries(events, pid, module, name, data) do
    for %{event: {^pid, :call, {:gen_statem, :enter, [_, [], ^module, ^pid, :infinity, ^name, ^data, []]}}} = source <- events,
        do: source
  end

  defp birth_entries(events, pid, module, name) do
    for %{event: {^pid, :call, {:gen_statem, :enter, [_, [], ^module, ^pid, :infinity, ^name, _, []]}}} = source <- events,
        do: source
  end

  defp birth_supervisor?(pair, supervisor),
    do:
      pair.source.mfa == {:tls_dyn_connection_sup, :start_link, 2} and
        match?({_, :return_from, _, {:ok, ^supervisor}}, pair.returned.event)

  defp birth_spawn?(events, parent, child),
    do: Enum.any?(events, &match?(%{event: {^parent, :spawn, ^child, _}}, &1))

  defp birth_factory?(pair, caller, host, remote_port, port, options, callbacks) do
    case pair.source.event do
      {^caller, :call,
       {:tls_gen_connection, :start_fsm,
        [^host, ^remote_port, ^port, {ssl, _emulated, trackers}, ^caller, ^callbacks, _]}} ->
        ssl === elem(options, 0) and trackers === elem(options, 2)

      _ ->
        false
    end
  end

  defp birth_options?(calls, receiver, factory, options, created) do
    {_, :call, {_, _, [_, _, _, {_ssl, emulated, _trackers} | _]}} = factory.source.event
    initial = {:socket_options, :list, 0, 0, 0, true}
    expected = :tls_socket.emulated_socket_options(emulated, initial)

    case Enum.filter(calls, fn pair ->
           pair.source.event ==
             {receiver, :call, {:tls_socket, :emulated_socket_options, [emulated, initial]}} and
             factory.source.index < pair.source.index and pair.returned.index < created.source.index
         end) do
      [%{returned: %{event: {_, :return_from, _, ^expected}}}] ->
        elem(options, 1) === expected

      _ ->
        false
    end
  end

  defp birth_options_receipt(events, tree, factory, receiver, supervisor) do
    {caller, :call,
     {_, _, [host, port, socket, options, caller, callbacks, _timeout]}} = factory.source.event
    sender = tree.source.pid
    arguments = [:client, supervisor, host, port, socket, options, caller, callbacks]
    message = {sender, :options, arguments}

    sends = Enum.filter(events, &(&1.event == {sender, :send, message, receiver}))
    receives = Enum.filter(events, &(&1.event == {receiver, :receive, message}))

    with [sent] <- sends,
         [received] <- receives,
         [initial] <-
           Enum.filter(events, &(&1.event == {receiver, :call, {:ssl_gen_statem, :init, [sender]}})),
         [initialized] <-
           Enum.filter(events, &(&1.event == {receiver, :call, {:ssl_gen_statem, :init_statem, [arguments]}})),
         true <- sent.index < received.index,
         true <- initial.index < received.index and received.index < initialized.index do
      {:ok, received}
    else
      _ -> :error
    end
  end

  defp birth_handoff?(pair, caller, port, receiver),
    do:
      pair.source.event == {caller, :call, {:gen_tcp, :controlling_process, [port, receiver]}} and
        pair.returned.event == {caller, :return_from, {:gen_tcp, :controlling_process, 2}, :ok}

  defp birth_machine(calls, entry, module, data) do
    pid = entry.pid
    {^pid, :call, {_, _, [parent, [], ^module, ^pid, :infinity, name, ^data, []]}} = entry.event
    before = {:params, :state_functions, false, parent, [:gen_statem], pid, :infinity}
    params = {:params, :state_functions, module == :tls_client_connection_1_3, parent, [module], pid, :infinity}

    with [mode] <- Enum.filter(calls, &(&1.source.event == {pid, :call, {:gen_statem, :get_callback_mode, [before, [module]]}})),
         true <- entry.index < mode.source.index,
         {^pid, :return_from, _, ^params} <- mode.returned.event do
      {:ok,
       %{
         params: params,
         state: {:state, {name, data}, [], %{}, [], false},
         debug: [],
         origin: {:tls_birth_machine, mode.returned.index},
         debug_origin: {:tls_birth_debug, entry.index},
         birth_index: mode.returned.index
       }}
    else
      _ -> :error
    end
  end

  # Only the public SSL send/recv arguments and returns are PostgreSQL bytes.
  # Encrypted port data never enters the framing or protocol association machine.
  # This ledger grants no event allowance; native interior/copy qualification and
  # the main comparator's consumption remain separate obligations.
  def build(indexed, binding, profile \\ nil) do
    bindings = if is_list(binding), do: binding, else: [binding]
    families = Enum.flat_map(bindings, &Map.get(&1, :families, [&1]))
    sockets = Map.new(bindings, &{&1.socket, &1})

    transport =
      profile_component(profile, :native_transport, fn ->
        Map.get_lazy(indexed, :native_transport, fn ->
          NativeTransport.build(
            Map.put(indexed, :profile, profile),
            %{},
            Enum.map(families, & &1.transport)
          )
        end)
      end)

    pairs = transport.pairs

    state =
      Enum.reduce(indexed.events, %{pairs: pairs, writes: [], reads: [], errors: []}, fn
        %{event: {_, :call, {:ssl, :send, [socket, data]}}} = source, state ->
          case Map.fetch(sockets, socket) do
            {:ok, binding} -> write(state, source, binding.port, IO.iodata_to_binary(data))
            :error -> tls_failure(state, source, :tls_socket_source)
          end

        %{event: {_, :call, {:ssl, :recv, [socket, length, timeout]}}} = source, state ->
          case Map.fetch(sockets, socket) do
            {:ok, binding} -> read(state, source, binding.port, length, timeout)
            :error -> tls_failure(state, source, :tls_socket_source)
          end

        %{event: {_, :call, {:ssl, function, _arguments}}} = source, state
        when function in [:send, :recv] ->
          tls_failure(state, source, :tls_socket_source)

        _, state ->
          state
      end)

    helper =
      profile_component(profile, :sender_copies, fn ->
        Enum.reduce(families, %{terms: [], errors: []}, fn family, combined ->
          helper = sender_copies(indexed.events, pairs, family)
          %{terms: helper.terms ++ combined.terms, errors: helper.errors ++ combined.errors}
        end)
      end)

    binding =
      bindings
      |> hd()
      |> Map.put(:families, families)
      |> Map.put(
        :debug_observations,
        Enum.reduce(bindings, %{}, &Map.merge(&2, Map.get(&1, :debug_observations, %{})))
      )

    workers =
      profile_component(profile, :worker_states, fn ->
        worker_states(indexed.events, pairs, binding, helper.terms, transport, profile)
      end)

    %{
      pairs: pairs,
      writes: Enum.reverse(state.writes),
      reads: Enum.reverse(state.reads),
      active: [],
      historical: %{},
      tls_bindings: bindings,
      transport: transport,
      terms: Enum.reverse(helper.terms) ++ Enum.reverse(workers.terms),
      errors:
        Enum.reverse(state.errors) ++
          transport.errors ++
          Enum.reverse(helper.errors) ++
          Enum.reverse(workers.errors)
    }
  end

  # Temporary component probe for native fragmented-reply validation. Only
  # fixed phase/mode names and elapsed durations leave the owning process.
  defp profile_component(nil, _component, callback), do: callback.()

  defp profile_component(profile, component, callback) do
    started = System.monotonic_time(:microsecond)
    value = callback.()
    elapsed = System.monotonic_time(:microsecond) - started

    IO.puts(
      "NATIVE_TLS_COMPONENT: " <>
        Diagnostics.render(Map.merge(profile, %{component: component, length: elapsed}))
    )

    value
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
    :loop_actions_next_event,
    :loop_state_enter,
    :loop_state_change,
    :loop_state_transition,
    :loop_keep_state,
    :loop_next_events,
    :loop_timeouts,
    :loop_timeouts_cancel,
    :loop_timeouts_register,
    :loop_timeouts_update
  ]

  defp pair_occurrences(pairs),
    do: pairs |> Map.values() |> Enum.group_by(&{&1.source.pid, &1.source.mfa})

  # Native sys:get_state roots precede observation. Gen_statem retains its old
  # StateData while a callback's next StateData is carried separately; only
  # loop_done (or the stopping branch) commits that independently built version.
  defp worker_states(events, pairs, binding, covered, transport, profile) do
    families = Map.get(binding, :families, [binding])

    owners =
      for family <- families,
          not Map.get(family, :born?, false),
          {pid, {name, data}} <- family.states,
          into: %{} do
        version = %{name: name, data: data, origin: {:historical_tls, pid}}
        {pid, %{version: version, family: family}}
      end

    initial = %{
      owners: owners,
      birth_candidates:
        families
        |> Enum.filter(&Map.get(&1, :born?, false))
        |> Enum.flat_map(&[&1.owner, &1.sender])
        |> MapSet.new(),
      born_workers: MapSet.new(),
      births:
        for(family <- families,
            Map.get(family, :born?, false),
            {pid, machine} <- family.machines,
            do: {machine.birth_index, {pid, family, machine}})
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
      pending: %{},
      frames: %{},
      received: %{},
      machine_queues: %{},
      machine_states: Map.new(owners, fn {pid, owner} -> {pid, owner.family.machines[pid]} end),
      machine_callbacks: %{},
      machine_zero: %{},
      machine_programs: %{},
      machine_debug: %{},
      debug_frames: %{},
      debug_required: %{},
      debug_observations: Map.get(binding, :debug_observations, %{}),
      debug_formatter: Map.get(binding, :debug_formatter, :missing_debug_formatter),
      direct_replies: %{},
      machine_received: %{},
      messages: %{},
      encoded: %{},
      parsed: %{},
      terms: [],
      errors: [],
      pairs: pairs,
      pair_index: pair_occurrences(pairs),
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
      |> MapSet.union(MapSet.new(Enum.flat_map(families, &Map.get(&1, :receipts, []))))

    debug =
      Map.new(owners, fn {pid, owner} ->
        root = owner.family.machines[pid]

        {pid,
         %{value: expected_debug(root.debug, initial.debug_formatter), origin: root.debug_origin}}
      end)

    initial = initial |> Map.put(:receipts, receipts) |> Map.put(:machine_debug, debug)

    state =
      profile_component(profile, :worker_events, fn ->
        Enum.reduce(events, initial, &worker_owner_event/2)
      end)

    profile_component(profile, :worker_debug_completion, fn ->
      Enum.reduce(state.debug_required, state, fn {_pid, source}, state ->
        tls_failure(state, source, :tls_machine_debug_required)
      end)
    end)
  end

  defp worker_owner_event(source, state) do
    state = worker_spawn(source, state)
    state = Enum.reduce(Map.get(state.births, source.index, []), state, &worker_birth(&1, source, &2))

    cond do
      Map.has_key?(state.owners, source.pid) ->
        worker_event(source, state)

      elem(source.event, 1) == :receive and MapSet.member?(state.born_workers, source.pid) ->
        worker_event(source, state)

      true ->
        state
    end
  end

  defp worker_spawn(%{event: {_, :spawn, child, _}}, state) do
    if MapSet.member?(state.birth_candidates, child),
      do: %{state | born_workers: MapSet.put(state.born_workers, child)},
      else: state
  end

  defp worker_spawn(_source, state), do: state

  defp worker_birth({pid, family, machine}, source, state) do
    {name, data} = elem(machine.state, 1)
    version = %{name: name, data: data, origin: machine.origin}

    state =
      state
      |> put_in([:owners, pid], %{version: version, family: family})
      |> put_in([:machine_states, pid], machine)
      |> put_in([:machine_debug, pid], %{value: [], origin: machine.debug_origin})

    context =
      program_context(state, source, [{:internal, :init_state}], false, machine.birth_index)
      |> Map.put(:call_enter, true)
      |> Map.put(:actions, [{:postpone, false}])

    put_in(state.machine_programs[pid], context)
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

  defp worker_event(%{event: {_, :call, {:sys, function, arguments}}} = source, state)
       when function in [:handle_debug, :nlog_put],
       do: debug_call(state, source, function, arguments)

  defp worker_event(%{event: {_, :call, {module, function, arguments}}} = source, state) do
    case Map.fetch(@worker_inputs, source.mfa) do
      {:ok, position} -> worker_call(state, source, arguments, position)
      :error -> record_call(state, source, module, function, arguments)
    end
  end

  defp worker_event(%{event: {_, :return_from, _, result}} = source, state),
    do:
      state
      |> debug_return(source)
      |> active_option_return(source)
      |> worker_return(source, result)

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

    state = if function == :loop_msg, do: loop_message(state, source, arguments), else: state
    machine_program(state, source, function, arguments)
  end

  # Temporary registers belong to the program that constructs them. The cursor
  # advances from the earlier message, callback return and native timer returns;
  # no checked helper argument is used to advance it.
  defp machine_program(state, source, function, arguments)
       when function in @loop_state_functions or
              function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] do
    debug = Map.fetch!(state.machine_debug, source.pid)
    debug_position = if function in @loop_state_functions, do: 1, else: 4

    context = Map.get(state.machine_programs, source.pid)
    {state, context} = program_before(state, source, function, context)

    case program_fields(function, length(arguments), context, state, source) do
      {:ok, fields} ->
        fields = Enum.map(fields, fn {path, expected} -> {path, expected, context.origin} end)
        fields = [{debug_position, debug.value, debug.origin} | fields]

        state =
          fields
          |> Enum.sort_by(fn {path, _expected, _origin} -> List.wrap(path) end)
          |> Enum.reduce(state, fn {path, expected, origin}, state ->
            program_field(state, source, {path, expected, origin}, debug_position)
          end)

        state = require_debug(state, source, function, length(arguments), context)
        state = program_callback_result(state, source, function, context)
        {state, context} = program_after(state, source, function, length(arguments), context)
        put_in(state.machine_programs[source.pid], context)

      :error ->
        tls_failure(state, source, :tls_machine_program_origin)
    end
  end

  defp machine_program(state, source, :sys_debug, arguments),
    do: debug_call(state, source, :sys_debug, arguments)

  defp machine_program(state, source, :terminate_sys_debug, _arguments) do
    root = state.owners[source.pid].family.machines[source.pid]
    context = Map.fetch!(state.machine_programs, source.pid)
    debug = Map.fetch!(state.machine_debug, source.pid)
    {_class, reason} = context.stop

    state
    |> program_term(source, [2, 2, 0], debug.value, debug.origin, &observed_debug(&1, state))
    |> program_term(source, [2, 2, 1], root.params, root.origin)
    |> program_term(source, [2, 2, 2], elem(context.data, 0), context.origin)
    |> program_term(source, [2, 2, 3], reason, context.origin)
    |> require_debug(source, :terminate_sys_debug, 4, context)
  end

  defp machine_program(state, source, :reply, _arguments) do
    action? =
      case source.stack do
        [{:gen_statem, function, _} | _] ->
          function in [:loop_actions_reply, :do_reply_then_terminate]

        _ ->
          false
      end

    expected =
      if action? do
        case state.machine_programs[source.pid] do
          %{reply: {from, reply}, origin: origin} -> {:ok, from, reply, origin}
          _ -> :error
        end
      else
        direct_reply(state, source)
      end

    case expected do
      {:ok, from, reply, origin} ->
        state
        |> program_term(source, [2, 2, 0], from, origin)
        |> program_term(source, [2, 2, 1], reply, origin)
        |> Map.update!(:direct_replies, &Map.delete(&1, source.pid))

      :error ->
        tls_failure(state, source, :tls_machine_program_reply_origin)
    end
  end

  defp machine_program(state, _source, _function, _arguments), do: state

  defp program_field(state, source, {path, expected, origin}, debug_position) do
    transform =
      if path == debug_position,
        do: &observed_debug(&1, state),
        else: &Function.identity/1

    program_term(state, source, [2, 2 | List.wrap(path)], expected, origin, transform)
  end

  defp debug_call(state, source, function, _arguments) do
    case debug_frame(state, source, function) do
      {:ok, frame} ->
        state = consume_debug(state, source, function)

        state =
          frame.arguments
          |> Enum.with_index()
          |> Enum.reduce(state, fn {expected, position}, state ->
            transform = debug_transform(frame.kind, position, state)

            program_term(
              state,
              source,
              [2, 2, position],
              expected,
              frame.origin,
              transform
            )
          end)

        frame = Map.put(frame, :mfa, source.mfa)
        frames = Map.get(state.debug_frames, source.pid, [])
        put_in(state.debug_frames[source.pid], [frame | frames])

      :error ->
        tls_failure(state, source, :tls_machine_debug_origin)
    end
  end

  defp require_debug(state, source, function, arity, context) do
    required? =
      function in [
        :loop_msg_event,
        :loop_actions_reply,
        :loop_actions_next_event,
        :loop_state_transition,
        :terminate_sys_debug
      ] or (function == :loop_timeouts_register and arity == 17) or
        (function == :do_reply_then_terminate and context.replies != [])

    if required? and state.machine_debug[source.pid].value != [] do
      state =
        case Map.get(state.debug_required, source.pid) do
          nil -> state
          previous -> tls_failure(state, previous, :tls_machine_debug_required)
        end

      put_in(state.debug_required[source.pid], source)
    else
      state
    end
  end

  defp consume_debug(state, source, :sys_debug) do
    parent = List.first(source.stack)

    case Map.get(state.debug_required, source.pid) do
      %{mfa: ^parent} ->
        Map.update!(state, :debug_required, &Map.delete(&1, source.pid))

      _ ->
        tls_failure(state, source, :tls_machine_debug_origin)
    end
  end

  defp consume_debug(state, _source, _function), do: state

  defp debug_frame(state, source, :sys_debug) do
    root = state.owners[source.pid].family.machines[source.pid]
    debug = Map.fetch!(state.machine_debug, source.pid)
    context = Map.get(state.machine_programs, source.pid)
    extra = elem(root.params, 5)

    with {:ok, event} <- debug_event(state, source, context),
         {:ok, result} <- advance_debug(debug.value, event, extra, state.debug_formatter) do
      {:ok,
       %{
         kind: :sys_debug,
         debug: debug.value,
         event: event,
         extra: extra,
         arguments: [debug.value, extra, event],
         result: result,
         origin: debug.origin
       }}
    end
  end

  defp debug_frame(state, source, :handle_debug) do
    with [parent | _] <- Map.get(state.debug_frames, source.pid, []),
         {:ok, debug} <- debug_tail(parent),
         {:ok, result} <- advance_debug(debug, parent.event, parent.extra, state.debug_formatter) do
      {:ok,
       %{
         parent
         | kind: :handle_debug,
           debug: debug,
           arguments: [debug, state.debug_formatter, parent.extra, parent.event],
           result: result
       }}
    else
      _ -> :error
    end
  end

  defp debug_frame(state, source, :nlog_put) do
    case Map.get(state.debug_frames, source.pid, []) do
      [%{kind: :handle_debug, debug: [{:log, log} | _]} = parent | _] ->
        item = {parent.event, parent.extra, state.debug_formatter}

        {:ok, %{parent | kind: :nlog_put, arguments: [item, log], result: advance_log(item, log)}}

      _ ->
        :error
    end
  end

  defp debug_tail(%{kind: :sys_debug, debug: debug}), do: {:ok, debug}
  defp debug_tail(%{kind: :handle_debug, debug: [_ | tail]}), do: {:ok, tail}
  defp debug_tail(_parent), do: :error

  defp debug_transform(:sys_debug, 0, state), do: &observed_debug(&1, state)
  defp debug_transform(:handle_debug, 0, state), do: &observed_debug(&1, state)

  defp debug_transform(:handle_debug, 1, state),
    do: &Map.get(state.debug_observations, &1, :unobserved_debug_formatter)

  defp debug_transform(:nlog_put, 0, state),
    do: &debug_item(&1, fn formatter -> Map.get(state.debug_observations, formatter) end)

  defp debug_transform(:nlog_put, 1, state),
    do: &debug_log(&1, fn formatter -> Map.get(state.debug_observations, formatter) end)

  defp debug_transform(_kind, _position, _state), do: &Function.identity/1

  defp debug_return(state, source) do
    case Map.get(state.debug_frames, source.pid, []) do
      [%{mfa: mfa} = frame | rest] when mfa == source.mfa ->
        transform =
          if frame.kind == :nlog_put,
            do: debug_transform(:nlog_put, 1, state),
            else: &observed_debug(&1, state)

        state = program_term(state, source, [3], frame.result, frame.origin, transform)
        state = put_in(state.debug_frames[source.pid], rest)

        if frame.kind == :sys_debug,
          do:
            put_in(state.machine_debug[source.pid], %{
              value: frame.result,
              origin: {:native_debug_return, source.index}
            }),
          else: state

      _ ->
        state
    end
  end

  defp debug_event(state, source, context) when is_map(context) do
    case List.first(source.stack) do
      {:gen_statem, :loop_msg_event, _} ->
        queue = Map.fetch!(state.machine_queues, source.pid)
        {:ok, {:in, hd(queue.events), state.owners[source.pid].version.name}}

      {:gen_statem, function, _}
      when function in [:loop_actions_reply, :do_reply_then_terminate] ->
        {from, reply} = context.reply
        {:ok, {:out, reply, from}}

      {:gen_statem, :loop_actions_next_event, _} ->
        {:ok, {:in, hd(context.next), elem(context.data, 0)}}

      {:gen_statem, :loop_state_transition, _} ->
        old_name = state.machine_states[source.pid].state |> elem(1) |> elem(0)
        kind = if context.postpone, do: :postpone, else: :consume
        {:ok, {kind, hd(context.q), old_name, elem(context.data, 0)}}

      {:gen_statem, :loop_timeouts_register, _} ->
        {:ok, {:start_timer, context.timeout, elem(context.data, 0)}}

      {:gen_statem, :terminate_sys_debug, _} ->
        {_class, reason} = context.stop
        {:ok, {:terminate, reason, elem(context.data, 0)}}

      _ ->
        :error
    end
  end

  defp debug_event(_state, _source, _context), do: :error

  defp expected_debug(debug, formatter), do: map_debug(debug, fn _actual -> formatter end)

  defp observed_debug(debug, state),
    do: map_debug(debug, &Map.get(state.debug_observations, &1, :unobserved_debug_formatter))

  defp map_debug(debug, formatter) when is_list(debug) do
    Enum.map(debug, fn
      {:log, log} -> {:log, debug_log(log, formatter)}
      option -> option
    end)
  end

  defp map_debug(debug, _formatter), do: debug

  defp debug_log([reverse | forward], formatter) when is_list(reverse),
    do: [
      Enum.map(reverse, &debug_item(&1, formatter))
      | Enum.map(forward, &debug_item(&1, formatter))
    ]

  defp debug_log([remaining | reverse], formatter) when is_integer(remaining),
    do: [remaining | Enum.map(reverse, &debug_item(&1, formatter))]

  defp debug_log(log, _formatter), do: log
  defp debug_item({event, extra, fun}, formatter), do: {event, extra, formatter.(fun)}
  defp debug_item(item, _formatter), do: item

  defp advance_debug(debug, event, extra, formatter) do
    Enum.reduce_while(debug, {:ok, []}, fn
      {:log, log}, {:ok, result} ->
        {:cont, {:ok, result ++ [{:log, advance_log({event, extra, formatter}, log)}]}}

      _option, _result ->
        {:halt, :error}
    end)
  end

  # OTP's ring representation has a filling countdown, then reverse/forward
  # queues. Preserve its exact representation as well as every retained entry.
  defp advance_log(item, [reverse | [_oldest | forward]]) when is_list(reverse),
    do: [[item | reverse] | forward]

  defp advance_log(item, [reverse]) when is_list(reverse) do
    [_oldest | forward] = Enum.reverse(reverse, [item])
    [[] | forward]
  end

  defp advance_log(item, [1 | reverse]), do: [[item | reverse]]
  defp advance_log(item, [remaining | reverse]), do: [remaining - 1, item | reverse]

  defp direct_reply(state, source) do
    case state.direct_replies[source.pid] do
      %{from: from, reply: reply, origin: origin, last: last} when source.index < last ->
        {:ok, from, reply, origin}

      _ ->
        receiver_reply(state, source)
    end
  end

  defp receiver_reply(state, source) do
    with [frame | _] <- Map.get(state.frames, source.pid, []),
         {:ok, version, plaintext} <- receiver_buffer(state, source.pid, frame),
         {:socket_options, :binary, packet, _max_packet, 0, false} <- elem(version.data, 5),
         true <- packet in [0, :raw],
         recv <- elem(version.data, 9),
         from <- elem(recv, 1),
         required <- elem(recv, 2),
         true <- from != :undefined and is_integer(required) and required >= 0,
         {front, size, rear} <- elem(version.data, 12),
         true <- size + byte_size(plaintext) > 0 do
      {front, rear, bytes} = queued_binary(front, [plaintext | rear])
      count = if required == 0, do: byte_size(bytes), else: required
      available = IO.iodata_to_binary([bytes, front, Enum.reverse(rear)])

      if count <= byte_size(available),
        do: {:ok, from, {:ok, binary_part(available, 0, count)}, version.origin},
        else: :error
    else
      _ -> :error
    end
  end

  defp receiver_buffer(
         state,
         pid,
         %{source: %{mfa: {:ssl_gen_statem, :read_application_data, 2}}, input: version}
       ) do
    case state.parsed[pid] do
      %{fragments: fragments, remaining: []} ->
        {:ok, version, IO.iodata_to_binary(fragments)}

      _ ->
        :error
    end
  end

  # passive_receive/3 calls the private four-argument reader directly. It
  # consumes the independently modeled queue without adding decrypted bytes.
  defp receiver_buffer(
         _state,
         _pid,
         %{source: %{mfa: {:ssl_gen_statem, :passive_receive, 3}}, input: version}
       ),
       do: {:ok, version, <<>>}

  defp receiver_buffer(_state, _pid, _frame), do: :error

  defp program_before(state, source, :loop_event, _context) do
    queue = state.machine_queues[source.pid]
    {state, program_context(state, source, queue.events, queue.hibernate, queue.origin)}
  end

  defp program_before(state, source, :loop_msg, nil),
    do: {state, program_context(state, source, [], false, source.index)}

  defp program_before(state, source, :loop_state_callback_result, context) when is_map(context) do
    case state.machine_callbacks[source.pid] do
      %{source: callback, result: result} ->
        {state, %{context | result: result, timer_index: callback.index, origin: callback.index}}

      _ ->
        {tls_failure(state, source, :tls_machine_program_callback_origin), context}
    end
  end

  defp program_before(state, source, function, context)
       when function in [:loop_next_events, :loop_timeouts] and is_map(context) do
    {state, context} = program_cancellations(state, source, context)
    program_pending_timer(state, source, context)
  end

  defp program_before(state, source, :loop_timeouts_register, context) when is_map(context) do
    case context.timeout_ref do
      nil ->
        {type, time, _message, options} = context.timeout
        function = if time == 0, do: :make_ref, else: :start_timer
        arguments = if time == 0, do: [], else: [time, source.pid, type, options]
        {state, ref, context} = program_timer_return(state, source, context, function, arguments)
        zero = if time == 0, do: [{type, ref} | context.zero], else: context.zero
        {state, %{context | timeout_ref: ref, zero: zero}}

      _ref ->
        {state, context}
    end
  end

  defp program_before(state, _source, _function, context), do: {state, context}

  defp program_context(state, source, events, hibernate, origin) do
    root = state.machine_states[source.pid]

    %{
      origin: origin,
      q: events,
      events: [],
      data: elem(root.state, 1),
      callback_event: List.first(events),
      next: [],
      hibernate: hibernate,
      timeouts: [],
      postpone: false,
      call_enter: false,
      state_call: true,
      actions: [],
      action: nil,
      reply: nil,
      result: nil,
      timers: elem(root.state, 3),
      postponed: elem(root.state, 2),
      seen: %{},
      zero: [],
      timeout: nil,
      timeout_ref: nil,
      timer_index: source.index,
      pending_timer: nil,
      cancels: [],
      stop: nil,
      replies: []
    }
  end

  defp program_fields(function, arity, _context, _state, _source)
       when {function, arity} in [
              {:loop, 3},
              {:loop_hibernate, 3},
              {:loop_wakeup, 3},
              {:loop_msg, 4},
              {:loop_msg_event, 4},
              {:loop_msg_event, 5},
              {:loop_event, 5},
              {:loop_t0q, 5}
            ],
       do: {:ok, []}

  defp program_fields(:loop_state_callback, 7, context, _state, _source) when is_map(context),
    do:
      {:ok,
       [
         {3, context.q},
         {[4, 0], elem(context.data, 0)},
         {5, context.callback_event},
         {6, context.hibernate}
       ]}

  defp program_fields(function, 11, context, _state, _source)
       when function in [:loop_state_callback, :loop_state_callback_result] and is_map(context) do
    fields = program_prefix(context, context.q, context.postpone)
    fields = fields ++ [{9, context.state_call}]

    if function == :loop_state_callback,
      do: {:ok, fields ++ [{10, context.callback_event}]},
      else: {:ok, fields}
  end

  defp program_fields(:loop_actions, 10, context, _state, _source) when is_map(context),
    do: {:ok, program_prefix(context, context.q, context.postpone) ++ [{9, context.call_enter}]}

  defp program_fields(function, arity, context, _state, _source)
       when function in [
              :loop_actions,
              :loop_actions_list,
              :loop_actions_reply,
              :loop_actions_next_event
            ] and
              arity in [12, 13, 14] and is_map(context) do
    base =
      program_prefix(context, context.q, context.postpone) ++
        [{9, context.call_enter}, {10, context.state_call}, {11, context.actions}]

    fields =
      case {function, arity} do
        {:loop_actions_list, 13} ->
          base ++ [{12, context.action}]

        {:loop_actions_reply, 14} ->
          {from, reply} = context.reply
          base ++ [{12, from}, {13, reply}]

        {:loop_actions_next_event, 14} ->
          {:next_event, type, content} = context.action
          base ++ [{12, type}, {13, content}]

        {function, 12} when function in [:loop_actions, :loop_actions_list] ->
          base

        _ ->
          []
      end

    if fields == [], do: :error, else: {:ok, fields}
  end

  defp program_fields(function, arity, context, _state, _source)
       when function in [
              :loop_state_enter,
              :loop_state_transition,
              :loop_keep_state,
              :loop_state_change
            ] and
              arity in [8, 9] and is_map(context) do
    events =
      if function in [:loop_state_enter, :loop_state_transition],
        do: context.q,
        else: context.events

    final =
      if function in [:loop_state_enter, :loop_state_transition],
        do: context.postpone,
        else: context.postponed

    fields = program_prefix(context, events, final)

    if arity == 8,
      do: {:ok, Enum.reject(fields, fn {path, _} -> path == 8 end)},
      else: {:ok, fields}
  end

  defp program_fields(:loop_next_events, 10, context, _state, _source) when is_map(context),
    do: {:ok, program_prefix(context, context.events, context.postponed) ++ [{9, context.timers}]}

  defp program_fields(function, arity, context, _state, _source)
       when function in [
              :loop_timeouts,
              :loop_timeouts_register,
              :loop_timeouts_cancel,
              :loop_timeouts_update
            ] and
              is_map(context) do
    base =
      program_prefix(context, context.events, context.postponed) ++
        [{9, context.timers}, {10, context.seen}, {11, context.zero}]

    extra = program_timeout_fields(function, arity, context)

    if extra == :error, do: :error, else: {:ok, base ++ extra}
  end

  defp program_fields(:loop_done, 5, context, _state, _source) when is_map(context),
    do: {:ok, [{3, context.events}, {4, context.next}]}

  defp program_fields(:loop_done, 4, context, _state, _source) when is_map(context),
    do: {:ok, [{3, context.q}]}

  defp program_fields(function, arity, context, state, source)
       when function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] and
              is_map(context) do
    case program_stop(state, source, context) do
      {:ok, class, reason, stack, replies, q} ->
        fields = [{0, class}, {1, reason}, {2, stack}, {6, q}]
        if arity == 8, do: {:ok, fields ++ [{7, replies}]}, else: {:ok, fields}

      :error ->
        :error
    end
  end

  defp program_fields(_function, _arity, _context, _state, _source), do: :error

  defp program_timeout_fields(:loop_timeouts, 12, _context), do: []

  defp program_timeout_fields(:loop_timeouts, 16, %{timeout: {type, time, message, options}}),
    do: [{12, type}, {13, time}, {14, message}, {15, options}]

  defp program_timeout_fields(:loop_timeouts_register, 17, context) do
    {type, time, message, options} = context.timeout
    [{12, type}, {13, time}, {14, message}, {15, options}, {16, context.timeout_ref}]
  end

  defp program_timeout_fields(:loop_timeouts_register, 15, context) do
    {type, _time, message, _options} = context.timeout
    [{12, type}, {13, context.timeout_ref}, {14, message}]
  end

  defp program_timeout_fields(:loop_timeouts_cancel, 13, %{timeout: {type, _, _, _}}),
    do: [{12, type}]

  defp program_timeout_fields(:loop_timeouts_update, 14, %{timeout: {type, _, message, _}}),
    do: [{12, type}, {13, message}]

  defp program_timeout_fields(_function, _arity, _context), do: :error

  defp program_prefix(context, events, postponed),
    do: [
      {3, events},
      {[4, 0], elem(context.data, 0)},
      {5, context.next},
      {6, context.hibernate},
      {7, context.timeouts},
      {8, postponed}
    ]

  defp program_callback_result(state, source, :loop_state_callback_result, context) do
    actual = native_term(source.event, [2, 2, 10])

    case {actual, context.result, result_data_path(context.result)} do
      {actual, expected, [data]}
      when is_tuple(actual) and is_tuple(expected) and
             tuple_size(actual) == tuple_size(expected) and elem(actual, 0) == elem(expected, 0) ->
        Enum.reduce(0..(tuple_size(expected) - 1), state, fn
          ^data, state ->
            state

          position, state ->
            program_term(
              state,
              source,
              [2, 2, 10, position],
              elem(expected, position),
              context.origin
            )
        end)

      _ ->
        program_term(state, source, [2, 2, 10], context.result, context.origin)
    end
  end

  defp program_callback_result(state, _source, _function, _context), do: state

  defp program_after(state, source, :loop_state_callback_result, _arity, context) do
    {name, data} = context.data

    case transition_result(context.result, name, data) do
      {:ok, next_name, next_data, _actions} ->
        repeat? =
          elem_if_tuple(context.result, 0) in [:repeat_state, :repeat_state_and_data] or
            context.result == :repeat_state_and_data

        context = %{
          context
          | data: {next_name, next_data},
            actions: program_actions(context.result),
            call_enter: repeat? or next_name !== name
        }

        {state, context}

      :error ->
        case program_stop_result(context.result, context) do
          {:ok, context} -> {state, context}
          :error -> {tls_failure(state, source, :tls_machine_program_result_origin), context}
        end
    end
  end

  defp program_after(state, source, :loop_state_enter, _arity, context) do
    previous = state.machine_states[source.pid].state |> elem(1) |> elem(0)
    {state, %{context | state_call: false, callback_event: {:enter, previous}}}
  end

  defp program_after(state, _source, :loop_actions, 12, context),
    do: {state, %{context | actions: native_list(context.actions)}}

  defp program_after(state, source, :loop_msg, _arity, context) do
    parent = elem(state.owners[source.pid].family.machines[source.pid].params, 3)

    case state.machine_received[source.pid] do
      %{value: {:EXIT, ^parent, reason}, origin: origin} ->
        {state, %{context | stop: {:exit, reason}, q: [], origin: origin}}

      _ ->
        {state, context}
    end
  end

  defp program_after(state, source, :loop_actions_list, 12, %{actions: [action | rest]} = context) do
    context = %{context | actions: rest, action: action}

    case action do
      :hibernate ->
        {state, %{context | hibernate: true}}

      {:hibernate, value} when is_boolean(value) ->
        {state, %{context | hibernate: value}}

      :postpone ->
        {state, %{context | postpone: true}}

      {:postpone, value} when is_boolean(value) ->
        {state, %{context | postpone: value}}

      {:reply, from, reply} ->
        {state, %{context | reply: {from, reply}}}

      {:next_event, _type, _content} ->
        {state, context}

      _ ->
        if timeout_action(action) == :error,
          do: {tls_failure(state, source, :tls_machine_program_action_origin), context},
          else: {state, context}
    end
  end

  defp program_after(state, source, :loop_actions_list, 13, context) do
    case timeout_action(context.action) do
      {:ok, timeout} -> {state, %{context | timeouts: [timeout | context.timeouts]}}
      :error -> {tls_failure(state, source, :tls_machine_program_timeout_origin), context}
    end
  end

  defp program_after(state, _source, :loop_actions_next_event, 14, context) do
    {:next_event, type, content} = context.action
    {state, %{context | next: [{type, content} | context.next]}}
  end

  defp program_after(state, source, :loop_state_transition, 9, context) do
    [event | events] = context.q
    root = state.machine_states[source.pid]
    postponed = if context.postpone, do: [event | elem(root.state, 2)], else: elem(root.state, 2)
    {state, %{context | events: events, postponed: postponed}}
  end

  defp program_after(state, _source, :loop_keep_state, 9, context),
    do: {state, %{context | cancels: [:timeout]}}

  defp program_after(state, _source, :loop_state_change, 9, context),
    do:
      {state,
       %{context | events: Enum.reverse(context.postponed) ++ context.events, postponed: []}}

  defp program_after(state, _source, :loop_state_change, 8, context),
    do: {state, %{context | cancels: [:state_timeout, :timeout]}}

  defp program_after(state, _source, :loop_timeouts, 12, %{timeouts: [timeout | rest]} = context) do
    type = elem(timeout, 0)
    context = %{context | timeouts: rest}

    if Map.has_key?(context.seen, type),
      do: {state, context},
      else: {state, %{context | timeout: timeout_tuple(timeout), timeout_ref: nil}}
  end

  defp program_after(state, _source, :loop_timeouts_register, 15, context),
    do: {state, %{context | pending_timer: :register}}

  defp program_after(state, _source, :loop_timeouts_cancel, 13, context),
    do: {state, %{context | pending_timer: :cancel}}

  defp program_after(state, _source, :loop_timeouts_update, 14, context),
    do: {state, %{context | pending_timer: :update}}

  defp program_after(state, _source, :loop_done, 5, context),
    do: {state, %{context | q: Enum.reverse(context.next) ++ context.events}}

  defp program_after(state, _source, :reply_then_terminate, 8, context),
    do: {state, %{context | replies: native_list(context.replies)}}

  defp program_after(
         state,
         _source,
         :do_reply_then_terminate,
         8,
         %{replies: [{:reply, from, reply} | rest]} = context
       ),
       do: {state, %{context | reply: {from, reply}, replies: rest}}

  defp program_after(state, _source, _function, _arity, context), do: {state, context}

  defp program_stop_result({:stop_and_reply, reason, replies, next_data}, context) do
    {name, _data} = context.data
    {:ok, %{context | data: {name, next_data}, stop: {:exit, reason}, replies: replies}}
  end

  defp program_stop_result({:stop_and_reply, reason, replies}, context),
    do: {:ok, %{context | stop: {:exit, reason}, replies: replies}}

  defp program_stop_result({:stop, reason, next_data}, context) do
    {name, _data} = context.data
    {:ok, %{context | data: {name, next_data}, stop: {:exit, reason}}}
  end

  defp program_stop_result({:stop, reason}, context),
    do: {:ok, %{context | stop: {:exit, reason}}}

  defp program_stop_result(:stop, context), do: {:ok, %{context | stop: {:exit, :normal}}}
  defp program_stop_result(_result, _context), do: :error

  defp timeout_action({type, time, message, options}) do
    options = native_list(options)

    case Enum.reduce_while(options, false, fn
           {:abs, value}, _ when is_boolean(value) -> {:cont, value}
           _, _ -> {:halt, :error}
         end) do
      true -> {:ok, {type, time, message, options}}
      false -> {:ok, {type, time, message}}
      :error -> :error
    end
  end

  defp timeout_action({type, time, message}), do: {:ok, {type, time, message}}
  defp timeout_action({type, :cancel}), do: {:ok, {type, :infinity, :undefined}}

  defp timeout_action(time) when is_integer(time) or time == :infinity,
    do: {:ok, {:timeout, time, time}}

  defp timeout_action(_action), do: :error

  defp timeout_tuple({type, time, message}), do: {type, time, message, []}
  defp timeout_tuple(timeout), do: timeout
  defp program_actions({:next_state, _name, _data, actions}), do: actions

  defp program_actions({tag, _data, actions}) when tag in [:keep_state, :repeat_state],
    do: actions

  defp program_actions({tag, actions}) when tag in [:keep_state_and_data, :repeat_state_and_data],
    do: actions

  defp program_actions(_result), do: []
  defp native_list(value) when is_list(value), do: value
  defp native_list(value), do: [value]
  defp elem_if_tuple(value, position) when is_tuple(value), do: elem(value, position)
  defp elem_if_tuple(_value, _position), do: nil

  defp program_cancellations(state, source, context) do
    Enum.reduce(context.cancels, {state, %{context | cancels: []}}, fn type, {state, context} ->
      program_cancel_timer(state, source, context, type)
    end)
  end

  defp program_cancel_timer(state, source, context, type) do
    case context.timers[type] do
      {ref, _message} ->
        {state, result, context} =
          program_timer_return(state, source, context, :cancel_timer, [ref])

        timers = Map.delete(context.timers, type)
        timers = if result == false, do: Map.put(timers, ref, []), else: timers
        {state, %{context | timers: timers}}

      nil ->
        {state, context}
    end
  end

  defp program_pending_timer(state, _source, %{pending_timer: nil} = context),
    do: {state, context}

  defp program_pending_timer(state, source, context) do
    {type, _time, message, _options} = context.timeout

    {state, context} =
      case context.pending_timer do
        :cancel ->
          program_cancel_timer(state, source, context, type)

        :register ->
          {state, context} = program_cancel_timer(state, source, context, type)

          {state,
           %{context | timers: Map.put(context.timers, type, {context.timeout_ref, message})}}

        :update ->
          case context.timers[type] do
            {ref, _old} ->
              {state, %{context | timers: Map.put(context.timers, type, {ref, message})}}

            nil ->
              {state, ref, context} = program_timer_return(state, source, context, :make_ref, [])

              {state,
               %{
                 context
                 | timers: Map.put(context.timers, type, {ref, message}),
                   zero: [{type, ref} | context.zero]
               }}
          end
      end

    {state, %{context | seen: Map.put(context.seen, type, true), pending_timer: nil}}
  end

  defp program_timer_return(state, source, context, function, arguments) do
    case machine_timer_pairs(state, source, context.timer_index) do
      [pair | _] ->
        {_, :return_from, _, result} = pair.returned.event

        state =
          tls_exact(
            state,
            pair.source,
            :tls_machine_timer_program,
            pair.source.event,
            {source.pid, :call, {:erlang, function, arguments}}
          )

        {state, result, %{context | timer_index: pair.returned.index}}

      [] ->
        {tls_failure(state, source, :tls_machine_program_timer_origin), :missing_native_timer,
         context}
    end
  end

  defp program_stop(state, source, context) do
    stack =
      state.pair_index
      |> Map.get({source.pid, {:erlang, :process_info, 2}}, [])
      |> Enum.filter(fn pair ->
        pair.source.pid == source.pid and pair.source.index > context.origin and
          pair.returned.index < source.index and
          pair.source.event ==
            {source.pid, :call, {:erlang, :process_info, [source.pid, :current_stacktrace]}}
      end)
      |> Enum.max_by(& &1.returned.index, fn -> nil end)

    case {context.stop, stack} do
      {{class, reason},
       %{returned: %{event: {_, :return_from, _, {:current_stacktrace, frames}}}}} ->
        {:ok, class, reason, frames, context.replies, context.q}

      _ ->
        :error
    end
  end

  defp program_term(state, source, path, expected, origin) do
    program_term(state, source, path, expected, origin, &Function.identity/1)
  end

  defp program_term(state, source, path, expected, origin, transform) do
    actual = source.event |> native_term(path) |> transform.()
    state = tls_exact(state, source, :tls_machine_program_copy, actual, expected)
    state = tls_error_path(state, source, path, :tls_machine_program_copy)

    copy = %{index: source.index, path: path, origin: origin}
    Map.update!(state, :terms, &[copy | &1])
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

    state = tls_error_path(state, source, path, :tls_machine_copy)

    copy = %{index: source.index, path: path, origin: origin}
    Map.update!(state, :terms, &[copy | &1])
  end

  defp tls_error_path(
         %{errors: [%{index: index, rule: rule} = error | rest]} = state,
         %{index: index},
         path,
         rule
       ) do
    if Map.has_key?(error, :path),
      do: state,
      else: %{state | errors: [Map.put(error, :path, path) | rest]}
  end

  defp tls_error_path(state, _source, _path, _rule), do: state

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
    do: {:ok, name, data, native_list(actions)}

  defp transition_result({:keep_state, data}, name, _data), do: {:ok, name, data, []}

  defp transition_result({:keep_state, data, actions}, name, _data),
    do: {:ok, name, data, native_list(actions)}

  defp transition_result(:keep_state_and_data, name, data), do: {:ok, name, data, []}

  defp transition_result({:keep_state_and_data, actions}, name, data),
    do: {:ok, name, data, native_list(actions)}

  defp transition_result({:repeat_state, data}, name, _data), do: {:ok, name, data, []}

  defp transition_result({:repeat_state, data, actions}, name, _data),
    do: {:ok, name, data, native_list(actions)}

  defp transition_result(:repeat_state_and_data, name, data), do: {:ok, name, data, []}

  defp transition_result({:repeat_state_and_data, actions}, name, data),
    do: {:ok, name, data, native_list(actions)}

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

  defp transition_action({type, time, message, options} = action, state) do
    case timeout_action({type, time, message, options}) do
      {:ok, timeout} -> %{state | timeouts: [timeout_tuple(timeout) | state.timeouts]}
      :error -> %{state | unknown: [action | state.unknown]}
    end
  end

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
    [
      {:erlang, :start_timer, 4},
      {:erlang, :cancel_timer, 1},
      {:erlang, :make_ref, 0}
    ]
    |> Enum.flat_map(&Map.get(state.pair_index, {source.pid, &1}, []))
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
    expected =
      case state.machine_programs[source.pid] do
        %{data: {_name, data}} ->
          data

        _ ->
          if function in [:loop_state_callback, :loop_state_callback_result],
            do: version.data,
            else: next.data
      end

    cond do
      function in [:loop_state_callback, :loop_state_callback_result] ->
        worker_copy(state, source, [2, 2, 4, 1], expected, version.origin)

      function in @loop_next_functions ->
        worker_copy(state, source, [2, 2, 4, 1], expected, next.origin)

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

        state =
          put_in(state.machine_received[source.pid], %{value: message, origin: origin.index})

        term = %{index: source.index, path: [2, 2, 3], origin: {:tls_message, origin.index}}
        state = Map.update!(state, :terms, &[term | &1])

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
    occurrences = pair_occurrences(pairs)
    arrivals = Enum.group_by(events, &{&1.pid, elem(&1.event, 1)})

    pairs
    |> Map.values()
    |> Enum.flat_map(fn
      %{
        source: %{event: {pid, :call, {module, :call, [target, request | _]}}} = source,
        returned: %{event: {_, :return_from, _, result}} = returned
      }
      when module in [:gen_statem, :gen_server] and is_pid(target) ->
        call_receipt(arrivals, occurrences, source, returned, pid, target, request, result)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp call_receipt(events, pairs, source, returned, pid, target, request, result) do
    requests =
      Enum.filter(Map.get(events, {pid, :send}, []), fn
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
    candidates =
      Map.get(pairs, {pid, {:erlang, :monitor, 2}}, []) ++
        Map.get(pairs, {pid, {:erlang, :monitor, 3}}, [])

    Enum.any?(candidates, fn
      %{
        source: %{event: {^pid, :call, {:erlang, :monitor, arguments}}} = monitor,
        returned: %{event: {_, :return_from, _, ref}} = returned
      }
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
      Enum.filter(Map.get(events, {target, :send}, []), fn
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
      for %{event: {^pid, :receive, {^tag, _value}}} = received <-
            Map.get(events, {pid, :receive}, []),
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

            state
            |> Map.update!(:terms, &[copy | &1])
            |> put_in([:direct_replies, source.pid], %{
              from: from,
              reply: reply,
              origin: origin,
              last: state.pairs[source.index].returned.index
            })

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
          Enum.filter(Map.get(state.pair_index, {caller, {:ssl, :send, 2}}, []), fn pair ->
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
    parents =
      Map.get(pair_occurrences(pairs), {binding.sender, {:tls_sender, :connection, 3}}, [])

    Enum.reduce(events, %{terms: [], errors: []}, fn
      %{event: {pid, :call, {:tls_sender, :send_application_data, arguments}}} = source, state
      when pid == binding.sender ->
        sender_copy(state, source, arguments, parents)

      _source, state ->
        state
    end)
  end

  defp sender_copy(state, source, [data, from, :connection, actual], pairs) do
    parent =
      pairs
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
        tls_failure(state, source, :tls_write_return)
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
        tls_failure(state, source, :tls_read_return)
    end
  end

  defp copy(source, path, bytes),
    do: %{index: source.index, path: path, offset: 0, length: byte_size(bytes)}

  defp mismatch(errors, _rule, true), do: errors
  defp mismatch(errors, rule, false), do: errors ++ [rule]
end
