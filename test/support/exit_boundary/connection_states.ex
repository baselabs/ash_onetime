defmodule AshOnetime.Test.ExitBoundary.ConnectionStates do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.ConnectionTypes
  alias AshOnetime.Test.ExitBoundary.NativeTransport
  alias AshOnetime.Test.ExitBoundary.Root

  import Postgrex.Messages,
    only: [
      msg_ready: 1,
      msg_parameter: 1,
      msg_notice: 1,
      msg_notify: 1,
      msg_error: 1,
      msg_bind: 1,
      msg_execute: 1,
      msg_close: 1,
      msg_parse: 1,
      msg_describe: 1,
      msg_flush: 0,
      msg_sync: 0,
      msg_query: 1
    ]

  @callbacks [
    :handle_prepare,
    :handle_execute,
    :handle_close,
    :handle_declare,
    :handle_fetch,
    :handle_deallocate,
    :handle_begin,
    :handle_commit,
    :handle_rollback,
    :handle_status,
    :handle_info,
    :disconnect,
    :checkin,
    :checkout,
    :ping
  ]
  @constructors [
    :parse_describe,
    :parse_describe_close,
    :close_parse_describe,
    :parse_describe_flush,
    :close_parse_describe_flush,
    :recv_ready,
    :recv_strict_ready,
    :done,
    :describe,
    :describe_params,
    :describe_result,
    :recv_describe,
    :handle_msg,
    :activate,
    :recv_buffer,
    :ping_recv
  ]
  @scopes [
    :handle_prepare_execute,
    :reload_describe_result,
    :recv_transaction,
    :error_ready,
    :error_flushed,
    :rollback_flushed,
    :reload_ready,
    :reload_transaction,
    :reload_closed,
    :reload_flushed,
    :reload_spawn,
    :reload_init
  ]
  @copies [
    :msg_send,
    :msg_recv,
    :rows_recv,
    :redescribe,
    :cancel_request,
    :cancel_send_recv,
    :cancel_recv,
    :terminate,
    :sock_close,
    :delete_parameters,
    :queries_delete
  ]
  @owners @callbacks ++ @constructors ++ @scopes ++ @copies
  @last_state @callbacks ++ [:handle_prepare_execute]
  @status_consumers [
    :parse_describe,
    :parse_describe_close,
    :close_parse_describe,
    :parse_describe_flush,
    :close_parse_describe_flush,
    :recv_ready,
    :recv_strict_ready,
    :handle_msg,
    :ping_recv,
    :recv_transaction,
    :error_ready,
    :error_flushed,
    :rollback_flushed,
    :reload_ready,
    :reload_transaction,
    :reload_closed,
    :reload_flushed,
    :recv_describe
  ]
  @cursor_buffers %{
    msg_recv: 2,
    rows_recv: 3,
    redescribe: 5,
    describe: 6,
    recv_describe: -1,
    reload_describe_result: 3,
    recv_ready: 2,
    recv_strict_ready: 3,
    recv_transaction: -1,
    error_ready: 3,
    error_flushed: 3,
    rollback_flushed: 3,
    reload_ready: 4,
    reload_transaction: 4,
    reload_closed: 4,
    reload_flushed: 4,
    reload_spawn: 4,
    reload_init: 4,
    ping_recv: 3,
    activate: 1
  }
  @owner_loop_current [
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
  @owner_loop_next @owner_loop_current --
                     [
                       :loop,
                       :loop_hibernate,
                       :loop_wakeup,
                       :loop_msg,
                       :loop_msg_event,
                       :loop_event,
                       :loop_t0q,
                       :loop_done
                     ]

  # An owner version is a native return, or the pre-observation holder state.
  # Copies must bind to that version before a buffer can leave exact comparison.
  # This ledger grants no event allowance or projection.
  def build(indexed, native, decoders, historical, fixture \\ :unavailable) do
    holders =
      for {holder, %{protocol: protocol}} <- historical, into: %{} do
        {holder, %{origin: {:historical, holder}, protocol: protocol, holder: holder}}
      end

    ports = for {_holder, version} <- holders, into: %{}, do: {version.protocol.sock, version}

    rows =
      for {holder,
           %{
             owner: owner,
             protocol: protocol,
             lock: lock,
             clock: clock,
             deadline: deadline,
             status: status
           }} <- historical,
          into: %{},
          do: {holder, {:conn, owner, Postgrex.Protocol, protocol, lock, clock, deadline, status}}

    tables = initial_tables(indexed, historical)
    machines = Map.get(indexed, :connection_owners, owner_machines(historical))
    births = owner_births(indexed.events, native.pairs)

    {type_roots, type_events} =
      ConnectionTypes.program(Map.get(indexed, :connection_type_roots, %{}))

    initial = %{
      holders: holders,
      holder_origins: Map.get(indexed, :connection_holder_origins, historical),
      owner_machines: machines,
      owner_births: births.entries,
      owner_commits:
        Enum.map(machines, fn {owner, machine} ->
          %{owner: owner, index: -1, machine: machine}
        end),
      owner_pending: %{},
      owner_messages: %{},
      owner_received: %{},
      owner_factories: %{},
      owner_results: %{},
      starting: %{},
      type_roots: type_roots,
      service_roots: Map.get(indexed, :connection_services, %{}),
      ports: ports,
      rows: rows,
      commits:
        for(
          {holder, row} <- rows,
          do: %{holder: holder, index: -1, origin: {:historical, holder}, row: row}
        ),
      tables: tables,
      table_commits:
        for(
          {table, rows} <- tables,
          do: %{table: table, index: -1, origin: {:historical, table}, rows: rows, present?: true}
        ),
      lookups: %{},
      completed: %{},
      frames: %{},
      pending: %{},
      described: %{},
      factories: %{},
      type_models: %{},
      type_locations: %{},
      type_locks: %{},
      type_owners: %{},
      type_services:
        MapSet.union(
          native_type_services(native.pairs),
          MapSet.new(Map.keys(Map.get(indexed, :connection_type_roots, %{})))
        ),
      service_queues: %{},
      service_current: %{},
      events: Map.get(indexed, :connection_program_events, indexed.events),
      reload_spawns: %{},
      reload_children: %{},
      versions: Map.values(holders),
      copies: [],
      buffers: [],
      terms: [],
      buffer_values: %{},
      term_values: %{},
      errors: births.errors,
      pairs: native.pairs,
      returns: Map.new(native.pairs, fn {_index, pair} -> {pair.returned.index, pair} end),
      decoders: decoders,
      native: native,
      fixture: fixture
    }

    initial =
      initial
      |> Map.merge(Map.get(indexed, :connection_state_program, %{}))
      |> Map.put(:type_events, type_events)

    continuation = %{initial: initial, events: indexed.events}

    state = Enum.reduce(indexed.events, initial, &event/2)
    state = unbound_copies(state, indexed)

    %{
      commits: Enum.reverse(state.commits),
      table_commits: Enum.reverse(state.table_commits),
      holder_origins: state.holder_origins,
      owner_machines: state.owner_machines,
      owner_commits: Enum.reverse(state.owner_commits),
      versions: Enum.reverse(state.versions),
      copies: Enum.reverse(state.copies),
      buffers: Enum.reverse(state.buffers),
      terms: Enum.reverse(state.terms),
      continuation: continuation,
      errors: Enum.reverse(state.errors)
    }
  end

  def checkpoint(%{continuation: input}, before) do
    input.events
    |> Enum.take_while(&(&1.index < before))
    |> Enum.reduce(input.initial, &event/2)
    |> Map.drop([
      :native,
      :events,
      :pairs,
      :returns,
      :decoders,
      :fixture,
      :type_services,
      :type_events
    ])
  end

  defp initial_tables(indexed, historical) do
    tables =
      for {_holder, %{query_cache: %{table: table, rows: rows}}} <- historical,
          not is_nil(table),
          into: %{},
          do: {table, rows}

    case Map.get(indexed, :query_cache) do
      %{table: table, rows: rows} -> Map.put(tables, table, rows)
      _ -> tables
    end
  end

  defp unbound_copies(state, indexed) do
    covered = MapSet.new(state.copies, &{&1.index, &1.path})
    sources = Map.new(indexed.events, &{&1.index, &1})

    Enum.reduce(state.decoders.protocol_copies, state, fn copy, state ->
      if MapSet.member?(covered, {copy.index, copy.path}) do
        state
      else
        source = Map.fetch!(sources, copy.index)
        state = failure(state, source, :state_copy_origin)
        [error | errors] = state.errors
        %{state | errors: [Map.put(error, :path, copy.path) | errors]}
      end
    end)
  end

  defp event(source, state) do
    state =
      %{state | type_roots: ConnectionTypes.advance(state.type_roots, state.type_events, source)}

    state = committed_row(source, state)
    state = committed_table(source, state)
    state = commit(source, state)
    state = holder_event(source, state)
    state = fixture_event(source, state)
    state = reload_event(source, state)
    state = startup_event(source, state)
    state = factory_event(source, state)
    state = type_service_event(source, state)
    state = owner_birth_event(source, state)
    state = owner_event(source, state)
    callback_event(source, state)
  end

  # The constructor starts from its original options. Every subsequent field
  # comes from a native socket fact, a decoded server message, a pre-observation
  # service root, or an already validated child factory. No checked Protocol
  # argument or eventual connect return supplies an expected field.
  defp startup_event(
         %{event: {pid, :call, {Postgrex.Protocol, :connect, [options]}}} = source,
         state
       ) do
    timeout = options[:timeout] || 15_000

    protocol = %Postgrex.Protocol{
      timeout: timeout,
      ping_timeout: Keyword.get(options, :ping_timeout, timeout),
      postgres: :idle,
      transactions: options[:transactions] || :naive,
      disconnect_on_error_codes: options[:disconnect_on_error_codes] || [],
      disable_composite_types: options[:disable_composite_types] || false
    }

    holder = get_in(state.owner_machines, [pid, :version, :holder])
    version = %{holder: holder, protocol: protocol, origin: {:protocol_constructor, source.index}}

    context = %{
      source: source,
      options: options,
      version: version,
      password_message: nil,
      authenticated?: false,
      endpoint: nil,
      phase: startup_phase(options)
    }

    put_in(state.starting[pid], context)
  end

  defp startup_event(%{event: {pid, :return_from, mfa, result}} = source, state) do
    case state.starting[pid] do
      nil -> state
      context -> startup_return(state, source, context, mfa, result)
    end
  end

  defp startup_event(_source, state), do: state

  defp startup_phase(options) do
    if options[:ssl] not in [nil, false] and
         Keyword.get(options, :ssl_negotiation, :postgres) == :postgres,
       do: :ssl_negotiation,
       else: :startup
  end

  defp startup_return(state, source, context, {:gen_tcp, :connect, 4}, {:ok, socket}) do
    case pair_returned(state, source) do
      %{
        source: %{
          stack: stack,
          event: {_, :call, {_, _, [host, port, _socket_options, _timeout]}}
        }
      } ->
        if {Postgrex.Protocol, :connect, 1} in stack do
          context = %{
            context
            | endpoint: {host, port, Keyword.fetch!(context.options, :database)}
          }

          startup_protocol(state, source, context, %{
            context.version.protocol
            | sock: {:gen_tcp, socket}
          })
        else
          state
        end

      _ ->
        state
    end
  end

  defp startup_return(state, source, context, {:prim_inet, :peername, 1}, {:ok, peer}) do
    %{source: call} = pair_returned(state, source)
    {_, socket} = context.version.protocol.sock

    state =
      exact(
        state,
        call,
        :state_constructor_socket,
        call.event,
        {source.pid, :call, {:prim_inet, :peername, [socket]}}
      )

    startup_protocol(state, source, context, %{context.version.protocol | peer: peer})
  end

  defp startup_return(state, source, context, {:ssl, :connect, 3}, {:ok, socket}) do
    with %{source: call} <- pair_returned(state, source),
         {_, :call, {:ssl, :connect, [port, _options, _timeout]}} <- call.event,
         {:gen_tcp, ^port} <- context.version.protocol.sock,
         true <- context.options[:ssl] not in [nil, false],
         true <-
           {context.phase, Keyword.get(context.options, :ssl_negotiation, :postgres)} in [
             {:ssl_upgrade, :postgres},
             {:startup, :direct}
           ],
         [binding] <-
           Enum.filter(Map.get(state.native, :tls_bindings, []), fn binding ->
             binding.port === port and binding.socket === socket and
               Map.get(binding, :upgrade_index) == call.index
           end) do
      context = %{context | phase: :startup}

      startup_protocol(state, source, context, %{
        context.version.protocol
        | sock: {:ssl, binding.socket}
      })
    else
      _ -> failure(state, source, :state_constructor_tls_origin)
    end
  end

  defp startup_return(state, source, context, {Postgrex.Protocol, :msg_decode, 1}, _result) do
    case Enum.find(state.decoders.instances, &(&1.returned.index == source.index)) do
      %{expected: {:ok, {:msg_backend_key, backend, key}, _}} ->
        startup_protocol(state, source, context, %{
          context.version.protocol
          | connection_id: backend,
            connection_key: key
        })

      %{expected: {:ok, {:msg_auth, :ok, _}, _}} ->
        put_in(state.starting[source.pid], %{context | authenticated?: true})

      _ ->
        state
    end
  end

  defp startup_return(
         state,
         source,
         context,
         {Postgrex.SCRAM, :negotiate_channel_binding, 3},
         actual
       ) do
    %{source: call} = pair_returned(state, source)
    protocol = context.version.protocol

    case native_message(state, source, protocol) do
      {:msg_auth, :sasl, mechanisms} ->
        mode = context.options[:channel_binding] || :prefer
        arguments = [mechanisms, protocol.sock, mode]
        {_, :call, {_, _, actual_arguments}} = call.event

        state =
          type_input_copies(
            state,
            call,
            actual_arguments,
            arguments,
            {:constructor_scram, context.source.index}
          )

        expected = startup_binding(state, call, mechanisms, protocol.sock, mode)

        state =
          helper_copy(state, source, [3], actual, expected, {:constructor_scram, call.index})

        case expected do
          {:ok, binding} ->
            startup_protocol(state, source, context, %{protocol | scram_cb: binding})

          _ ->
            state
        end

      _ ->
        failure(state, source, :state_constructor_auth_origin)
    end
  end

  defp startup_return(state, source, context, {Postgrex.SCRAM, :client_first, 1}, actual) do
    %{source: call} = pair_returned(state, source)
    pair = Map.fetch!(state.pairs, call.index)

    with {mechanism, header, _binding} <- context.version.protocol.scram_cb,
         [random] <-
           native_type_calls(state, call, pair.returned, {:crypto, :strong_rand_bytes, 1}),
         {_, :call, {_, _, [18]}} <- random.source.event,
         {_, :return_from, _, bytes} <- random.returned.event,
         true <- is_binary(bytes) and byte_size(bytes) == 18 do
      sasl = [header, "n=,r=", Base.encode64(bytes)]
      message = [mechanism, 0, <<IO.iodata_length(sasl)::signed-32>>, sasl]
      {_, :call, {_, _, arguments}} = call.event

      state =
        type_input_copies(
          state,
          call,
          arguments,
          [context.version.protocol.scram_cb],
          {:constructor_scram, context.source.index}
        )

      state =
        helper_copy(
          state,
          source,
          [3],
          actual,
          message,
          {:constructor_nonce, random.returned.index}
        )

      put_in(state.starting[source.pid], %{context | password_message: message})
    else
      nil -> failure(state, source, :state_constructor_auth_origin)
      _ -> failure(state, source, :state_constructor_nonce_origin)
    end
  end

  defp startup_return(state, source, context, {Postgrex.SCRAM, :client_final, 3}, actual) do
    case native_message(state, source, context.version.protocol) do
      {:msg_auth, :sasl_cont, data} ->
        {message, scram} = startup_scram(data, context.version.protocol.scram_cb, context.options)
        %{source: call} = pair_returned(state, source)
        {_, :call, {_, _, arguments}} = call.event

        expected_arguments = [
          data,
          context.version.protocol.scram_cb,
          startup_options(context.options)
        ]

        state =
          type_input_copies(
            state,
            call,
            arguments,
            expected_arguments,
            {:constructor_scram, context.source.index}
          )

        state =
          helper_copy(
            state,
            source,
            [3],
            actual,
            {message, scram},
            {:constructor_scram, call.index}
          )

        context = %{context | password_message: message}
        startup_protocol(state, source, context, %{context.version.protocol | scram: scram})

      _ ->
        failure(state, source, :state_constructor_auth_origin)
    end
  end

  defp startup_return(state, source, context, {Postgrex.SCRAM, :verify_server, 3}, actual) do
    case native_message(state, source, context.version.protocol) do
      {:msg_auth, :sasl_fin, data} ->
        %{source: call} = pair_returned(state, source)
        {_, :call, {_, _, arguments}} = call.event

        expected_arguments = [
          data,
          context.version.protocol.scram,
          startup_options(context.options)
        ]

        state =
          type_input_copies(
            state,
            call,
            arguments,
            expected_arguments,
            {:constructor_scram, context.source.index}
          )

        expected = startup_verify(data, context.version.protocol.scram, context.options)
        helper_copy(state, source, [3], actual, expected, {:constructor_scram, call.index})

      _ ->
        failure(state, source, :state_constructor_auth_origin)
    end
  end

  defp startup_return(state, source, context, {Postgrex.TypeServer, :fetch, 1}, _result) do
    with %{source: call} <- pair_returned(state, source),
         %{result: {:lock, _ref, types}} <- state.type_models[call.index] do
      startup_protocol(state, source, %{context | phase: :bootstrap}, %{
        context.version.protocol
        | types: types
      })
    else
      _ -> failure(state, source, :state_constructor_type_origin)
    end
  end

  defp startup_return(state, source, context, {:ets, :new, 2}, table) do
    case pair_returned(state, source) do
      %{source: %{event: {_, :call, {:ets, :new, [Postgrex.Protocol, [:set, :public]]}}}} ->
        startup_protocol(state, source, context, %{context.version.protocol | queries: table})

      _ ->
        state
    end
  end

  defp startup_return(state, source, context, {Postgrex.Parameters, :insert, 1}, actual) do
    %{source: call} = pair_returned(state, source)
    parameters = context.version.protocol.parameters
    {_, :call, {_, _, arguments}} = call.event

    state =
      type_input_copies(
        state,
        call,
        arguments,
        [parameters],
        {:constructor_parameters, context.source.index}
      )

    case startup_parameter_reference(state, call, parameters) do
      {:ok, reference, origin} ->
        state = helper_copy(state, source, [3], actual, reference, origin)

        startup_protocol(state, source, context, %{
          context.version.protocol
          | parameters: reference
        })

      :error ->
        failure(state, source, :state_constructor_parameters_origin)
    end
  end

  defp startup_return(state, source, context, {Postgrex.Protocol, :connect, 1}, {:ok, actual}) do
    version = context.version

    state
    |> exact(source, :state_constructor_result, actual, version.protocol)
    |> copy(source, [3, 1], version)
    |> put_in([:ports, version.protocol.sock], version)
    |> put_in([:completed, source.pid], version)
    |> update_in([:starting], &Map.delete(&1, source.pid))
  end

  defp startup_return(state, source, _context, {Postgrex.Protocol, :connect, 1}, {:error, _}) do
    update_in(state.starting, &Map.delete(&1, source.pid))
  end

  defp startup_return(state, _source, _context, _mfa, _result), do: state

  defp startup_protocol(state, source, context, protocol) do
    version = %{context.version | protocol: protocol, origin: {:constructor_field, source.index}}
    put_in(state.starting[source.pid], %{context | version: version})
  end

  defp startup_scram(data, {_mechanism, header, binding}, options) do
    server =
      for <<key, "=", value::binary>> <- :binary.split(data, ",", [:global]),
          into: %{},
          do: {key, value}

    salt = Base.decode64!(server[?s])
    iterations = String.to_integer(server[?i])
    nonce = binary_part(server[?r], 0, 24)

    without_proof = [
      "c=",
      Base.encode64(IO.iodata_to_binary([header, binding])),
      ",r=",
      server[?r]
    ]

    prefix = ["n=,r=", nonce, ",r=", server[?r], ",s=", server[?s], ",i=", server[?i], ?,]
    auth_message = IO.iodata_to_binary([prefix | without_proof])

    salted =
      :crypto.pbkdf2_hmac(:sha256, Keyword.fetch!(options, :password), salt, iterations, 32)

    client_key = :crypto.mac(:hmac, :sha256, salted, "Client Key")
    signature = :crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, client_key), auth_message)
    proof = Base.encode64(:crypto.exor(client_key, signature))

    {[without_proof, ",p=", proof],
     %{salt: salt, iterations: iterations, auth_message: auth_message}}
  end

  defp startup_verify(data, scram, options) do
    server =
      for <<key, "=", value::binary>> <- :binary.split(data, ",", [:global]),
          into: %{},
          do: {key, value}

    case server do
      %{?e => error} ->
        {:error,
         %Postgrex.Error{
           message: "error received in SCRAM server final message: #{inspect(error)}"
         }}

      %{?v => signature} ->
        salted =
          :crypto.pbkdf2_hmac(
            :sha256,
            Keyword.fetch!(options, :password),
            scram.salt,
            scram.iterations,
            32
          )

        key = :crypto.mac(:hmac, :sha256, salted, "Server Key")
        expected = :crypto.mac(:hmac, :sha256, key, scram.auth_message)

        if expected == Base.decode64!(signature),
          do: :ok,
          else: {:error, %Postgrex.Error{message: "cannot verify SCRAM server signature"}}

      _ ->
        {:error,
         %Postgrex.Error{message: "unsupported SCRAM server final message: #{inspect(server)}"}}
    end
  end

  defp startup_options(options) do
    {ssl, options} = Keyword.pop(options, :ssl, false)
    options = if ssl == true, do: Keyword.delete(options, :ssl_opts), else: options
    parameters = options[:parameters] || []

    parameters =
      case options[:search_path] do
        path when is_list(path) ->
          Keyword.put(parameters, :search_path, Enum.intersperse(path, ", "))

        nil ->
          parameters
      end

    Keyword.put(options, :parameters, parameters)
  end

  defp startup_parameter_reference(state, source, parameters) do
    servers = for {pid, %{name: Postgrex.Parameters}} <- state.service_roots, do: pid

    with [server] <- servers,
         {:ok, callback, from, reference, _completion} <-
           type_server_request(state, source, server, {:insert, parameters}, Postgrex.Parameters),
         [{^reference, monitor}] <- type_lock_monitors(state, callback, server, source.pid),
         {:ok, insert} <- startup_parameter_insert(state, callback, from, parameters, reference) do
      {:ok, reference, {:constructor_parameter_monitor, monitor, insert}}
    else
      _ -> :error
    end
  end

  defp startup_parameter_insert(state, callback, from, parameters, reference) do
    with [insert] <-
           native_type_calls(state, callback.source, callback.returned, {:ets, :insert_new, 2}),
         {_, :call, {:ets, :insert_new, [Postgrex.Parameters, {^reference, ^parameters}]}} <-
           insert.source.event,
         {_, :return_from, _, true} <- insert.returned.event,
         {_, :call, {_, _, [{:insert, ^parameters}, ^from, Postgrex.Parameters]}} <-
           callback.source.event,
         {_, :return_from, _, {:reply, ^reference, Postgrex.Parameters}} <-
           callback.returned.event do
      {:ok, insert.source.index}
    else
      _ -> :error
    end
  end

  defp startup_binding(state, call, mechanisms, {:ssl, socket}, mode) when mode != :disable do
    if "SCRAM-SHA-256-PLUS" in :binary.split(mechanisms, <<0>>, [:global]) do
      startup_certificate_binding(state, call, socket, mode)
    else
      # No certificate access occurs in this branch of the owning function.
      Postgrex.SCRAM.negotiate_channel_binding(mechanisms, {:ssl, socket}, mode)
    end
  end

  defp startup_binding(_state, _call, mechanisms, socket, mode),
    do: Postgrex.SCRAM.negotiate_channel_binding(mechanisms, socket, mode)

  defp startup_certificate_binding(state, call, socket, mode) do
    pair = Map.fetch!(state.pairs, call.index)

    with [certificate] <- native_type_calls(state, call, pair.returned, {:ssl, :peercert, 1}),
         {_, :call, {:ssl, :peercert, [^socket]}} <- certificate.source.event,
         {_, :return_from, _, {:ok, der}} <- certificate.returned.event,
         {:Certificate, _tbs, {_tag, oid, _parameters}, _signature} <-
           :public_key.pkix_decode_cert(der, :plain),
         {digest, _sign} when digest != :none <- :public_key.pkix_sign_types(oid) do
      digest = if digest in [:md5, :sha], do: :sha256, else: digest
      {:ok, {"SCRAM-SHA-256-PLUS", "p=tls-server-end-point,,", :crypto.hash(digest, der)}}
    else
      _ when mode != :require ->
        {:ok, {"SCRAM-SHA-256", "n,,", ""}}

      _ ->
        {:error,
         %Postgrex.Error{
           message: "channel binding is required but the server certificate has no usable hash"
         }}
    end
  end

  # A borrowed Holder and the connection process keep independent versions.
  # The process root is a pre-observation sys:get_state result, never the row
  # or callback whose copy is being checked.
  defp owner_machines(historical) do
    for {holder, %{owner: owner, owner_machine: {name, data}}} <- historical,
        %{mod: Postgrex.Protocol, state: %Postgrex.Protocol{} = protocol} <- [data],
        into: %{} do
      version = %{holder: holder, protocol: protocol, origin: {:historical_owner, owner}}
      {owner, %{name: name, data: data, version: version}}
    end
  end

  # A new owner has no historical Holder. Its first machine is constructed
  # forward from its real factory inputs, and becomes available only when the
  # native callback-mode program completes. Neither a later sys state nor an
  # initializer's checked output supplies the expected data.
  defp owner_births(events, pairs) do
    pairs
    |> Map.values()
    |> Enum.filter(&(&1.source.mfa == {DBConnection.Connection, :init, 1}))
    |> Enum.reduce(%{entries: %{}, errors: []}, fn init, births ->
      case owner_birth(events, pairs, init) do
        {:ok, index, machine} ->
          put_in(births.entries[index], {init.source.pid, machine})

        :error ->
          error = %{
            index: init.source.index,
            at: Map.take(init.source, [:mfa, :role, :stack]),
            rule: :state_owner_birth_origin,
            actual: false,
            expected: true
          }

          %{births | errors: [error | births.errors]}
      end
    end)
  end

  defp owner_birth(events, pairs, init) do
    pid = init.source.pid
    calls = Map.values(pairs)

    with [factory] <-
           Enum.filter(calls, fn pair ->
             pair.source.mfa == {DBConnection.Connection, :start_link, 4} and
               pair.source.index < init.source.index and
               init.returned.index < pair.returned.index and
               pair.returned.event ==
                 {pair.source.pid, :return_from, {DBConnection.Connection, :start_link, 4},
                  {:ok, pid}}
           end),
         {parent, :call, {_, _, [Postgrex.Protocol, options, pool, tag]}} <- factory.source.event,
         true <- Enum.any?(events, &match?(%{event: {^parent, :spawn, ^pid, _}}, &1)),
         arguments = {Postgrex.Protocol, %DBConnection.SensitiveData{data: options}, pool, tag},
         [native] <-
           Enum.filter(calls, fn pair ->
             pair.source.index > factory.source.index and
               pair.returned.index < factory.returned.index and
               pair.source.event ===
                 {parent, :call,
                  {:gen_statem, :start_link,
                   [
                     DBConnection.Connection,
                     arguments,
                     Keyword.take(options, [:debug, :spawn_opt])
                   ]}}
           end),
         true <-
           native.returned.event ===
             {parent, :return_from, {:gen_statem, :start_link, 3}, {:ok, pid}},
         true <-
           init.source.event ===
             {pid, :call, {DBConnection.Connection, :init, [arguments]}},
         data = owner_initial_data(options, pool, tag),
         actions = {:next_event, :internal, {:connect, :init}},
         true <-
           init.returned.event ===
             {pid, :return_from, {DBConnection.Connection, :init, 1},
              {:ok, :no_state, data, actions}},
         [entry] <-
           Enum.filter(events, fn source ->
             source.index > init.returned.index and
               source.event ===
                 {pid, :call,
                  {:gen_statem, :enter,
                   [parent, [], DBConnection.Connection, pid, :infinity, :no_state, data, actions]}}
           end),
         before = {:params, :state_functions, false, parent, [:gen_statem], pid, :infinity},
         params =
           before
           |> put_elem(1, &DBConnection.Connection.handle_event/4)
           |> put_elem(4, [DBConnection.Connection]),
         [mode] <-
           Enum.filter(calls, fn pair ->
             pair.source.index > entry.index and
               pair.source.event ===
                 {pid, :call,
                  {:gen_statem, :get_callback_mode, [before, [DBConnection.Connection]]}} and
               pair.returned.event ===
                 {pid, :return_from, {:gen_statem, :get_callback_mode, 2}, params}
           end) do
      version = %{holder: nil, protocol: nil, origin: {:owner_birth, init.source.index}}

      machine = %{
        name: :no_state,
        data: data,
        version: version,
        params: params,
        backoff_timer: nil
      }

      {:ok, mode.returned.index, machine}
    else
      _ -> :error
    end
  end

  defp owner_initial_data(options, pool, tag) do
    %{
      mod: Postgrex.Protocol,
      opts: options,
      state: nil,
      client: :closed,
      pool: pool,
      tag: tag,
      timer: nil,
      connected_at: nil,
      backoff: DBConnection.Backoff.new(options),
      connection_listeners: Keyword.get(options, :connection_listeners, []),
      after_connect: Keyword.get(options, :after_connect),
      after_connect_timeout: Keyword.get(options, :after_connect_timeout, 15_000)
    }
  end

  defp owner_birth_event(source, state) do
    case Map.fetch(state.owner_births, source.index) do
      {:ok, {owner, machine}} ->
        commit = %{owner: owner, index: source.index, machine: machine}

        state
        |> put_in([:owner_machines, owner], machine)
        |> Map.update!(:owner_commits, &[commit | &1])

      :error ->
        state
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Connection, :ping, [{owner, holder}, _protocol]}}} =
           source,
         state
       ),
       do: owner_public_copy(state, source, owner, holder, 1)

  defp owner_event(
         %{
           event:
             {_, :call, {DBConnection.Connection, function, [{owner, holder}, _error, _protocol]}}
         } = source,
         state
       )
       when function in [:disconnect, :stop],
       do: owner_public_copy(state, source, owner, holder, 2)

  defp owner_event(
         %{event: {_, :call, {:gen_statem, :cast, [owner, message]}}} = source,
         state
       )
       when is_tuple(message) and tuple_size(message) in [3, 4] do
    tag = elem(message, 0)
    holder = elem(message, 1)

    version = owner_handoff_version(state, source, holder, tag)

    case {tag, version, Map.get(state.owner_machines, owner)} do
      {tag, version, machine}
      when tag in [:ping, :disconnect, :stop] and
             not is_nil(version) and not is_nil(machine) ->
        expected = put_elem(message, tuple_size(message) - 1, version.protocol)

        state =
          exact(
            state,
            source,
            :state_owner_destination,
            owner,
            state.holder_origins[holder].owner
          )

        state = exact(state, source, :state_owner_message, message, expected)
        pair = Map.fetch!(state.pairs, source.index)

        context = %{
          source: source,
          returned: pair.returned,
          owner: owner,
          version: version,
          message: expected
        }

        state
        |> put_in([:owner_messages, source.index], context)
        |> owner_protocol_copy(source, [2, 2, 1, tuple_size(message) - 1], version)
        |> update_in([:lookups], &Map.delete(&1, source.pid))

      _ ->
        state
    end
  end

  defp owner_event(%{event: {pid, :receive, {:"$gen_cast", message}}} = source, state)
       when is_tuple(message) and tuple_size(message) in [3, 4] do
    context =
      state.owner_messages
      |> Map.values()
      |> Enum.filter(&(&1.owner == pid and &1.source.index < source.index))
      |> Enum.sort_by(& &1.source.index)
      |> Enum.find(&(elem(&1.message, 1) === elem(message, 1)))

    case context do
      nil ->
        state

      context ->
        state
        |> exact(source, :state_owner_message, message, context.message)
        |> owner_protocol_copy(source, [2, 1, tuple_size(message) - 1], context.version)
        |> put_in([:owner_received, pid], context)
        |> update_in([:owner_messages], &Map.delete(&1, context.source.index))
    end
  end

  defp owner_event(
         %{event: {pid, :receive, {:timeout, reference, {:timeout, :backoff}}}} = source,
         state
       ) do
    case state.owner_machines[pid] do
      %{backoff_timer: {expected, _origin}} = machine ->
        state
        |> exact(source, :state_owner_backoff_timer, reference, expected)
        |> put_in([:owner_machines, pid], Map.put(machine, :backoff_received, source.index))

      _ ->
        failure(state, source, :state_owner_backoff_timer_origin)
    end
  end

  defp owner_event(%{event: {_, :call, {:gen_statem, function, _arguments}}} = source, state) do
    case Map.get(state.owner_machines, source.pid) do
      nil -> owner_message_program(state, source)
      machine -> owner_loop(state, source, function, machine)
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Backoff, :backoff, [input]}}} = source,
         state
       ) do
    case state.owner_machines[source.pid] do
      %{data: %{backoff: %DBConnection.Backoff{} = expected}, version: version} ->
        state = exact(state, source, :state_owner_backoff_input, input, expected)
        state = copy_error_path(state, source, [2, 2, 0], :state_owner_backoff_input)
        owner_backoff_term(state, source, [2, 2, 0], expected, version.origin)

      _ ->
        state
    end
  end

  defp owner_event(
         %{event: {_, :return_from, {DBConnection.Backoff, :backoff, 1}, actual}} = source,
         state
       ) do
    case {state.owner_machines[source.pid], pair_returned(state, source)} do
      {%{data: %{backoff: %DBConnection.Backoff{} = backoff}}, retry} when not is_nil(retry) ->
        owner_backoff_result(state, source, retry, backoff, actual)

      _ ->
        state
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Connection, :handle_event, arguments}}} = source,
         state
       ) do
    case Map.get(state.owner_machines, source.pid) do
      nil ->
        state

      machine ->
        state = owner_data_copy(state, source, [2, 2, 3], machine)
        state = owner_protocol_copy(state, source, [2, 2, 3, :state], machine.version)
        state = owner_task_event(state, source, machine, arguments)

        case {arguments, state.owner_received[source.pid]} do
          {[:cast, message, :no_state, _data], %{message: expected, version: version}}
          when elem(message, 0) in [:ping, :disconnect, :stop] ->
            state
            |> exact(source, :state_owner_message, message, expected)
            |> owner_protocol_copy(source, [2, 2, 1, tuple_size(message) - 1], version)

          _ ->
            state
        end
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Connection, :pool_update, [_protocol, _data]}}} =
           source,
         state
       ) do
    case {owner_pool_machine(state, source), state.completed[source.pid]} do
      {{:ok, machine}, version} when not is_nil(version) ->
        state
        |> owner_data_copy(source, [2, 2, 1], machine)
        |> owner_protocol_copy(source, [2, 2, 0], version)
        |> owner_protocol_copy(source, [2, 2, 1, :state], machine.version)

      _ ->
        failure(state, source, :state_owner_update_origin)
    end
  end

  defp owner_event(
         %{
           event:
             {pid, :return_from, {DBConnection.Holder, :delete, 1},
              {Postgrex.Protocol, _protocol}}
         } = source,
         state
       ) do
    with %{holder: holder, origin: {lookup, _}} = version <- state.lookups[pid],
         %{source: %{event: {^pid, :call, {_, _, [^holder]}}} = call} <-
           pair_returned(state, source),
         true <- is_integer(lookup) and call.index < lookup and lookup < source.index,
         %{holder: ^holder, row: nil, index: deleted} <-
           Enum.find(state.commits, &(&1.holder == holder)),
         true <- lookup < deleted and deleted < source.index do
      state
      |> owner_protocol_copy(source, [3, 1], version)
      |> put_in([:completed, pid], version)
    else
      _ -> state
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Task, :run_child, arguments}}} = source,
         state
       ) do
    case {state.owner_machines[source.pid], state.completed[source.pid]} do
      {machine, version} when not is_nil(machine) and not is_nil(version) ->
        expected = [
          Postgrex.Protocol,
          version.protocol,
          machine.data.after_connect,
          [timeout: machine.data.after_connect_timeout] ++ machine.data.opts
        ]

        state
        |> exact(
          source,
          :state_owner_task_factory,
          List.delete_at(arguments, 1),
          List.delete_at(expected, 1)
        )
        |> owner_protocol_copy(source, [2, 2, 1], version)

      _ ->
        failure(state, source, :state_owner_task_origin)
    end
  end

  defp owner_event(
         %{event: {_, :return_from, {DBConnection.Task, :run_child, 4}, actual}} = source,
         state
       ) do
    with machine when not is_nil(machine) <- state.owner_machines[source.pid],
         task when not is_nil(task) <- pair_returned(state, source),
         {:ok, child, reference} <- owner_task_origin(state, task, machine),
         [started] <- native_type_calls(state, task.source, source, {Task.Supervisor, :start_child, 4}) do
      state
      |> exact(source, :state_owner_task_return, actual, {child, reference})
      |> exact(started.returned, :state_owner_task_child, elem(started.returned.event, 3), {:ok, child})
    else
      _ -> failure(state, source, :state_owner_task_origin)
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Task, :init, actual}}} = source,
         state
       ) do
    contexts =
      for {_index, task} <- state.pairs,
          task.source.mfa == {DBConnection.Task, :run_child, 4},
          task.source.index < source.index,
          machine when not is_nil(machine) <- [state.owner_machines[task.source.pid]],
          {:ok, child, _reference} <- [owner_task_origin(state, task, machine)],
          child == source.pid,
          do: {task.source.pid, machine}

    case contexts do
      [{owner, machine}] ->
        options = [timeout: machine.data.after_connect_timeout] ++ machine.data.opts
        expected = [machine.data.after_connect, owner, %DBConnection.SensitiveData{data: options}]
        exact(state, source, :state_owner_task_initial, actual, expected)

      _ ->
        failure(state, source, :state_owner_task_origin)
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Holder, :update, [_, _, _, _protocol]}}} = source,
         state
       ) do
    case state.completed[source.pid] do
      nil ->
        state

      version ->
        state
        |> owner_protocol_copy(source, [2, 2, 3], version)
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Holder, function, arguments}}} = source,
         state
       )
       when function in [:new, :update] and length(arguments) == 5 do
    case owner_holder_factory(state, source) do
      {:ok, machine, version, pool, tag, connected_at} ->
        expected = [pool, tag, Postgrex.Protocol, version.protocol, connected_at]

        state =
          exact(
            state,
            source,
            :state_holder_factory,
            List.delete_at(arguments, 3),
            List.delete_at(expected, 3)
          )

        state = owner_protocol_copy(state, source, [2, 2, 3], version)

        if function == :new do
          context = %{
            source: source,
            machine: machine,
            version: version,
            holder: nil,
            pool: pool,
            tag: tag,
            connected_at: connected_at
          }

          put_in(state.owner_factories[source.pid], context)
        else
          state
        end

      _ ->
        state
    end
  end

  defp owner_event(%{event: {_, :return_from, {:ets, :new, 2}, holder}} = source, state) do
    case {state.owner_factories[source.pid], pair_returned(state, source)} do
      {%{holder: nil} = factory, %{source: call}} ->
        expected =
          {source.pid, :call,
           {:ets, :new,
            [DBConnection.Holder, [:public, :ordered_set, decentralized_counters: true]]}}

        state
        |> exact(source, :state_holder_factory_table, call.event, expected)
        |> put_in([:owner_factories, source.pid], %{factory | holder: holder})

      _ ->
        state
    end
  end

  defp owner_event(
         %{event: {_, :call, {:ets, :setopts, [holder, options]}}} = source,
         state
       ) do
    case state.owner_factories[source.pid] do
      %{holder: ^holder, pool: pool, tag: tag} ->
        expected = {:heir, pool, tag}
        exact(state, source, :state_holder_factory_heir, options, expected)

      _ ->
        state
    end
  end

  defp owner_event(
         %{event: {_, :call, {:ets, :give_away, [holder, pool, message]}}} = source,
         state
       ) do
    case state.owner_factories[source.pid] do
      %{holder: ^holder, pool: expected_pool, tag: tag, source: factory} ->
        clock =
          state.pairs
          |> Map.values()
          |> Enum.filter(fn pair ->
            pair.source.pid == source.pid and
              pair.source.mfa == {:erlang, :monotonic_time, 0} and
              pair.source.index > factory.index and pair.returned.index < source.index
          end)
          |> Enum.max_by(& &1.returned.index, fn -> nil end)

        case clock do
          %{returned: %{event: {_, :return_from, _, value}}} ->
            state
            |> exact(source, :state_holder_factory_pool, pool, expected_pool)
            |> exact(
              source,
              :state_holder_factory_checkin,
              message,
              {:checkin, tag, value}
            )

          _ ->
            failure(state, source, :state_holder_factory_clock_origin)
        end

      _ ->
        state
    end
  end

  defp owner_event(
         %{event: {_, :return_from, {DBConnection.Holder, :new, 5}, holder}} = source,
         state
       ) do
    case state.owner_factories[source.pid] do
      %{holder: expected} -> exact(state, source, :state_holder_factory_return, holder, expected)
      _ -> state
    end
  end

  defp owner_event(
         %{event: {_, :call, {:ets, :insert_new, [holder, row]}}} = source,
         state
       ) do
    case state.owner_factories[source.pid] do
      %{holder: ^holder, connected_at: connected_at, version: version} ->
        expected =
          {:conn, source.pid, Postgrex.Protocol, version.protocol, nil, connected_at, nil, :ok}

        state
        |> exact(
          source,
          :state_holder_factory_row,
          owner_holder_fields(row),
          owner_holder_fields(expected)
        )
        |> owner_protocol_copy(source, [2, 2, 1, 3], version)

      _ ->
        state
    end
  end

  defp owner_event(
         %{event: {_, :return_from, {:ets, :insert_new, 2}, true}} = source,
         state
       ) do
    case {state.owner_factories[source.pid], pair_returned(state, source)} do
      {%{holder: holder, machine: machine, version: version, pool: pool},
       %{source: %{event: {_, :call, {:ets, :insert_new, [holder, _row]}}}}} ->
        version = %{version | holder: holder}
        previous = Map.get(state.holder_origins, machine.version.holder, %{})

        case renewed_transport(state, source, version.protocol, previous) do
          {:ok, transport} ->
            origin =
              previous
              |> Map.drop([:tls])
              |> Map.merge(transport)
              |> Map.merge(%{
                owner: source.pid,
                pool: pool,
                protocol: version.protocol,
                owner_machine: {machine.name, machine.data},
                holder_origin_index: source.index
              })

            state
            |> put_in([:holders, holder], version)
            |> put_in([:holder_origins, holder], origin)

          :error ->
            failure(state, source, :state_holder_transport_origin)
        end

      _ ->
        state
    end
  end

  defp owner_event(
         %{event: {_, :return_from, {DBConnection.Connection, :pool_update, 2}, result}} = source,
         state
       ) do
    case {state.owner_machines[source.pid], state.owner_factories[source.pid]} do
      {current, %{holder: holder, version: version, machine: machine}} when not is_nil(current) ->
        data = %{machine.data | client: {holder, :pool}, state: version.protocol}
        expected = {:keep_state, data, :hibernate}
        version = %{version | holder: holder, origin: {source.index, [3, 1, :state]}}
        pending = %{machine | data: data, version: version}

        state
        |> owner_result_copy(source, result, expected)
        |> owner_protocol_copy(source, [3, 1, :state], version)
        |> put_in([:owner_pending, source.pid], pending)
        |> put_in([:owner_results, source.pid], expected)

      _ ->
        failure(state, source, :state_owner_result_origin)
    end
  end

  defp owner_event(
         %{event: {_, :return_from, {DBConnection.Connection, :handle_event, 4}, result}} = source,
         state
       ) do
    case state.owner_pending[source.pid] do
      nil ->
        owner_callback_transition(state, source, result)

      pending ->
        state
        |> owner_result_copy(source, result, state.owner_results[source.pid])
        |> owner_protocol_copy(source, [3, owner_result_data(state.owner_results[source.pid]), :state], pending.version)
    end
  end

  defp owner_event(
         %{event: {_, :call, {DBConnection.Connection, :terminate, [reason, name, _data]}}} = source,
         state
       ) do
    case {state.owner_machines[source.pid], state.owner_results[source.pid]} do
      {machine, {:stop, expected, _}} when not is_nil(machine) ->
        state
        |> exact(source, :state_owner_stop, {reason, name}, {expected, machine.name})
        |> owner_data_copy(source, [2, 2, 2], machine)
        |> owner_protocol_copy(source, [2, 2, 2, :state], machine.version)

      _ ->
        state
    end
  end

  defp owner_event(%{event: {pid, :exit, _reason}} = source, state) do
    if Map.has_key?(state.owner_machines, pid) do
      commit = %{owner: pid, index: source.index, machine: nil}

      state
      |> update_in([:owner_machines], &Map.delete(&1, pid))
      |> update_in([:owner_pending], &Map.delete(&1, pid))
      |> update_in([:owner_results], &Map.delete(&1, pid))
      |> update_in([:owner_factories], &Map.delete(&1, pid))
      |> Map.update!(:owner_commits, &[commit | &1])
    else
      state
    end
  end

  defp owner_event(source, state), do: owner_message_program(state, source)

  defp owner_callback_transition(state, source, actual) do
    with machine when not is_nil(machine) <- state.owner_machines[source.pid],
         %{source: call} <- pair_returned(state, source),
         {:ok, next, expected} <- owner_transition(state, call, source, machine) do
      state
      |> owner_result_copy(source, actual, expected)
      |> owner_protocol_copy(source, [3, owner_result_data(expected), :state], next.version)
      |> put_in([:owner_pending, source.pid], next)
      |> put_in([:owner_results, source.pid], expected)
    else
      _ -> state
    end
  end

  defp owner_transition(
         state,
         %{event: {pid, :call, {_, _, [:cast, {:disconnect, holder, error, _}, :no_state, _]}}},
         _returned,
         machine
       ) do
    with %{message: {:disconnect, ^holder, ^error, _}, version: version} <-
           state.owner_received[pid],
         {^holder, _} <- machine.data.client do
      data = %{machine.data | state: version.protocol}
      next = %{machine | data: data, version: version}
      {:ok, next, {:keep_state, data, {:next_event, :internal, {:disconnect, {:log, error}}}}}
    else
      _ -> :error
    end
  end

  defp owner_transition(
         state,
         %{event: {_, :call, {_, _, [:internal, {:disconnect, {_, error}}, :no_state, _]}}} = call,
         returned,
         machine
       ) do
    with {_, phase} <- machine.data.client,
         true <- owner_task_timer_cancelled?(state, call, returned, machine.data.timer),
         error = owner_disconnect_error(machine, error),
         true <- owner_disconnect_call?(state, call, returned, error) do
      data = %{machine.data | state: nil, client: :closed, timer: nil, connected_at: nil}
      version = %{machine.version | protocol: nil, origin: {:owner_disconnected, returned.index}}
      next = machine |> Map.merge(%{data: data, version: version}) |> owner_task_clear()
      owner_disconnect_result(state, call, returned, next, phase, error)
    else
      _ -> :error
    end
  end

  defp owner_transition(
         state,
         %{event: {_, :call, {_, _, [:info, {:DOWN, _, _, _, _}, :no_state, _]}}} = call,
         _returned,
         machine
       ) do
    with {:ok, _message, reason, origin} <- owner_task_down(state, call, machine) do
      task = machine.after_connect_task.pid
      message = "client #{inspect(task)} exited: " <> Exception.format_exit(reason)
      error = %DBConnection.ConnectionError{message: message}
      log = owner_down_log(reason)
      data = %{machine.data | client: {nil, :after_connect}}
      next = Map.put(%{machine | data: data}, :task_failure, %{error: error, log: log, origin: origin})
      {:ok, next, {:keep_state, data, {:next_event, :internal, {:disconnect, {log, error}}}}}
    else
      _ -> :error
    end
  end

  defp owner_transition(
         state,
         %{event: {pid, :call, {_, _, [:cast, {:after_connect, ref}, :no_state, _]}}} = call,
         returned,
         machine
       ) do
    with {^ref, :connect} <- machine.data.client,
         version when not is_nil(version) <- state.completed[pid],
         [task] <- native_type_calls(state, call, returned, {DBConnection.Task, :run_child, 4}),
         {^pid, :call, {DBConnection.Task, :run_child, task_arguments}} <- task.source.event,
         true <-
           List.delete_at(task_arguments, 1) ===
             [
               Postgrex.Protocol,
               machine.data.after_connect,
               [timeout: machine.data.after_connect_timeout] ++ machine.data.opts
             ],
         {:ok, child, reference} <- owner_task_origin(state, task, machine),
         {:ok, timer} <-
           owner_task_timer(
             state,
             task.returned,
             returned,
             child,
             machine.data.after_connect_timeout
           ) do
      data = %{
        machine.data
        | state: version.protocol,
          client: {reference, :after_connect},
          timer: timer
      }

      next =
        Map.put(%{machine | data: data, version: version}, :after_connect_task, %{
          pid: child,
          reference: reference,
          factory: task.source.index
        })

      {:ok, next, {:keep_state, data}}
    else
      _ -> :error
    end
  end

  defp owner_transition(
         _state,
         %{event: {_, :call, {_, _, [{:timeout, :backoff}, nil, :no_state, _]}}},
         _returned,
         machine
       ) do
    {:ok, machine, {:keep_state, machine.data, {:next_event, :internal, {:connect, :backoff}}}}
  end

  defp owner_transition(
         state,
         %{event: {_, :call, {_, _, [:internal, {:connect, _}, :no_state, _]}}} = call,
         returned,
         machine
       ) do
    owner_connect_transition(state, call, returned, machine)
  end

  defp owner_transition(_state, _call, _returned, _machine), do: :error

  defp owner_task_event(state, source, machine, [:info, {:DOWN, _, _, _, _} = actual, :no_state, _]) do
    case owner_task_down(state, source, machine) do
      {:ok, expected, _reason, _origin} -> exact(state, source, :state_owner_task_down, actual, expected)
      :error -> state
    end
  end

  defp owner_task_event(state, source, %{task_failure: failure}, [
         :internal,
         {:disconnect, actual},
         :no_state,
         _
       ]),
       do: exact(state, source, :state_owner_task_error, actual, {failure.log, failure.error})

  defp owner_task_event(state, _source, _machine, _arguments), do: state

  defp owner_disconnect_error(%{task_failure: failure}, _copy), do: failure.error
  defp owner_disconnect_error(_machine, error), do: error

  defp owner_task_clear(machine), do: Map.drop(machine, [:after_connect_task, :task_failure])

  # DOWN is justified by the Task's own primitive death and the monitor retained
  # by its validated factory, then by that exact receipt in this owner's mailbox.
  # The process is already dead, so Util.inspect_pid's label/name/initial-call
  # reads all return undefined; no live process inspection supplies the message.
  defp owner_task_down(state, source, %{after_connect_task: task, data: data}) do
    with {reference, :after_connect} <- data.client,
         true <- reference === task.reference,
         [death] <- Enum.filter(state.events, fn event ->
           event.pid == task.pid and elem(event.event, 1) == :exit and event.index < source.index
         end),
         {_, :exit, reason} <- death.event,
         message = {:DOWN, reference, :process, task.pid, reason},
         [receipt] <- Enum.filter(state.events, fn event ->
           event.event === {source.pid, :receive, message} and
             death.index < event.index and event.index < source.index
         end) do
      {:ok, message, reason, receipt.index}
    else
      _ -> :error
    end
  end

  defp owner_task_down(_state, _source, _machine), do: :error

  defp owner_down_log(reason) when reason in [:normal, :shutdown], do: :nolog
  defp owner_down_log({:shutdown, _}), do: :nolog
  defp owner_down_log(_reason), do: :log

  defp owner_disconnect_call?(state, call, returned, error) do
    case native_type_calls(state, call, returned, {Postgrex.Protocol, :disconnect, 2}) do
      [%{source: %{event: {_, :call, {_, _, [^error, _]}}}, returned: %{event: {_, :return_from, _, :ok}}}] -> true
      _ -> false
    end
  end

  defp owner_disconnect_result(_state, _call, _returned, %{data: %{backoff: nil}} = next, _phase, error),
    do: {:ok, next, {:stop, {:shutdown, error}, next.data}}

  defp owner_disconnect_result(state, call, returned, next, :after_connect, _error) do
    with [retry] <- native_type_calls(state, call, returned, {DBConnection.Backoff, :backoff, 1}),
         {:ok, timeout, backoff} <- owner_backoff(state, retry, next.data.backoff) do
      data = %{next.data | backoff: backoff}
      next = Map.put(%{next | data: data}, :backoff_program, {returned.index, timeout})
      {:ok, next, {:keep_state, data, {{:timeout, :backoff}, timeout, nil}}}
    else
      _ -> :error
    end
  end

  defp owner_disconnect_result(_state, _call, _returned, next, _phase, _error),
    do: {:ok, next, {:keep_state, next.data, {:next_event, :internal, {:connect, :disconnect}}}}

  defp owner_task_timer(_state, _source, _returned, _child, :infinity), do: {:ok, nil}

  defp owner_task_timer(state, source, returned, child, timeout) do
    with [timer] <- native_type_calls(state, source, returned, {:erlang, :start_timer, 3}),
         true <-
           timer.source.event ===
             {source.pid, :call,
              {:erlang, :start_timer,
               [timeout, source.pid, {DBConnection.Connection, child, timeout}]}},
         {_, :return_from, _, reference} when is_reference(reference) <- timer.returned.event do
      {:ok, reference}
    else
      _ -> :error
    end
  end

  defp owner_connect_transition(state, call, returned, machine) do
    with [connect] <- native_type_calls(state, call, returned, {Postgrex.Protocol, :connect, 1}),
         {:ok, expected_options} <- owner_connect_options(state, call, connect, machine.data.opts),
         {_, :call, {_, _, [options]}} <- connect.source.event,
         true <- options === expected_options do
      owner_connect_result(state, connect, returned, machine)
    else
      _ -> :error
    end
  end

  defp owner_connect_result(
         state,
         %{returned: %{event: {_, :return_from, _, {:error, _}}}} = connect,
         returned,
         machine
       ) do
    with backoff when not is_nil(backoff) <- machine.data.backoff,
         [retry] <-
           native_type_calls(
             state,
             connect.returned,
             returned,
             {DBConnection.Backoff, :backoff, 1}
           ),
         {:ok, timeout, next_backoff} <- owner_backoff(state, retry, backoff) do
      data = %{machine.data | backoff: next_backoff}
      next = Map.put(%{machine | data: data}, :backoff_program, {returned.index, timeout})
      {:ok, next, {:keep_state, data, {{:timeout, :backoff}, timeout, nil}}}
    else
      _ -> :error
    end
  end

  defp owner_connect_result(
         state,
         %{returned: %{event: {_, :return_from, _, {:ok, _}}}} = connect,
         returned,
         machine
       ) do
    with [reference] <-
           native_type_calls(state, connect.returned, returned, {:erlang, :make_ref, 0}),
         {_, :return_from, _, ref} <- reference.returned.event,
         [clock] <-
           native_type_calls(state, reference.returned, returned, {:erlang, :monotonic_time, 0}),
         {_, :return_from, _, connected_at} <- clock.returned.event,
         version when not is_nil(version) <- state.completed[returned.pid] do
      backoff =
        if is_nil(machine.data.after_connect),
          do: machine.data.backoff && DBConnection.Backoff.reset(machine.data.backoff),
          else: machine.data.backoff

      data = %{
        machine.data
        | state: version.protocol,
          client: {ref, :connect},
          connected_at: connected_at,
          backoff: backoff
      }

      next = machine |> Map.merge(%{data: data, version: version}) |> owner_task_clear()
      {:ok, next, {:keep_state, data}}
    else
      _ -> :error
    end
  end

  defp owner_connect_result(_state, _connect, _returned, _machine), do: :error

  defp owner_backoff_result(state, source, retry, backoff, actual) do
    case owner_backoff(state, retry, backoff) do
      {:ok, timeout, next_backoff} ->
        expected = {timeout, next_backoff}
        state = exact(state, source, :state_owner_backoff_result, actual, expected)
        state = copy_error_path(state, source, [3], :state_owner_backoff_result)
        owner_backoff_term(state, source, [3], expected, {:native_backoff, retry.source.index})

      :error ->
        failure(state, source, :state_owner_backoff_result_origin)
    end
  end

  defp owner_backoff_term(state, source, path, expected, origin) do
    copy = %{index: source.index, path: path, origin: origin}

    state
    |> Map.update!(:terms, &[copy | &1])
    |> put_in([:term_values, {source.index, path}], %{value: expected, origin: origin})
  end

  # Derive the retry from its original struct and its own native random return.
  # Calling Backoff.backoff/1 here would draw fresh entropy and prove nothing.
  defp owner_backoff(state, retry, %DBConnection.Backoff{type: :rand} = backoff) do
    with {:ok, timeout} <- owner_backoff_random(state, retry, backoff.min, backoff.max) do
      {:ok, timeout, backoff}
    end
  end

  defp owner_backoff(_state, _retry, %DBConnection.Backoff{type: :exp} = backoff) do
    timeout = if is_nil(backoff.state), do: backoff.min, else: min(backoff.state * 2, backoff.max)
    {:ok, timeout, %{backoff | state: timeout}}
  end

  defp owner_backoff(
         state,
         retry,
         %DBConnection.Backoff{type: :rand_exp, state: {previous, lower}} = backoff
       ) do
    with {:ok, timeout} <-
           owner_backoff_random(
             state,
             retry,
             min(previous, lower),
             min(previous * 3, backoff.max)
           ) do
      {:ok, timeout, %{backoff | state: {timeout, lower}}}
    end
  end

  defp owner_backoff_random(state, retry, minimum, maximum) do
    with [random] <- native_type_calls(state, retry.source, retry.returned, {:rand, :uniform, 1}),
         true <-
           random.source.event ===
             {retry.source.pid, :call, {:rand, :uniform, [maximum - minimum + 1]}},
         {_, :return_from, _, draw}
         when is_integer(draw) and draw > 0 and draw <= maximum - minimum + 1 <-
           random.returned.event do
      {:ok, draw + minimum - 1}
    else
      _ -> :error
    end
  end

  defp owner_pool_machine(state, source) do
    case state.owner_machines[source.pid] do
      nil ->
        :error

      machine ->
        owner_pool_machine(state, source, machine, owner_callback(state, source))
    end
  end

  defp owner_pool_machine(
         state,
         source,
         machine,
         %{source: %{event: {_, :call, {_, _, [:info, message, :no_state, _]}}}} = callback
       )
       when is_tuple(message) and tuple_size(message) == 4 and
              elem(message, 0) == :"ETS-TRANSFER" do
    with {:"ETS-TRANSFER", holder, _task, {:checkin, ref, _}} <- message,
         {^ref, :after_connect} <- machine.data.client,
         %{holder: ^holder} <- state.lookups[source.pid],
         true <- owner_task_timer_cancelled?(state, callback.source, source, machine.data.timer) do
      backoff = machine.data.backoff && DBConnection.Backoff.reset(machine.data.backoff)
      data = %{machine.data | timer: nil, client: nil, backoff: backoff}
      {:ok, machine |> Map.put(:data, data) |> owner_task_clear()}
    else
      _ -> :error
    end
  end

  defp owner_pool_machine(_state, _source, machine, _callback), do: {:ok, machine}

  defp owner_callback(state, source) do
    state.pairs
    |> Map.values()
    |> Enum.find(fn pair ->
      pair.source.pid == source.pid and
        pair.source.mfa == {DBConnection.Connection, :handle_event, 4} and
        pair.source.index < source.index and source.index < pair.returned.index
    end)
  end

  defp owner_task_timer_cancelled?(_state, _call, _source, nil), do: true

  defp owner_task_timer_cancelled?(state, call, source, timer) do
    with [cancel] <- native_type_calls(state, call, source, {:erlang, :cancel_timer, 1}),
         {_, :call, {_, _, [^timer]}} <- cancel.source.event,
         {_, :return_from, _, result} <- cancel.returned.event do
      case result do
        remaining when is_integer(remaining) and remaining >= 0 -> true
        false -> owner_task_timer_flushed?(state, cancel, source, timer)
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp owner_task_timer_flushed?(state, cancel, source, timer) do
    starts =
      for {_index, pair} <- state.pairs,
          pair.source.pid == source.pid and pair.returned.index < cancel.source.index,
          pair.source.mfa == {:erlang, :start_timer, 3},
          pair.returned.event === {source.pid, :return_from, {:erlang, :start_timer, 3}, timer},
          {_, :call, {_, _, [_timeout, owner, message]}} <- [pair.source.event],
          owner == source.pid,
          do: message

    case starts do
      [message] ->
        Enum.count(state.events, fn event ->
          cancel.returned.index < event.index and event.index < source.index and
            event.event === {source.pid, :receive, {:timeout, timer, message}}
        end) == 1

      _ ->
        false
    end
  end

  defp owner_holder_factory(state, source) do
    with machine when not is_nil(machine) <- state.owner_machines[source.pid],
         version when not is_nil(version) <- state.completed[source.pid] do
      if {DBConnection.Task, :run_child, 4} in source.stack do
        owner_task_holder(state, source, machine, version)
      else
        owner_pool_holder(state, source, version)
      end
    else
      _ -> :error
    end
  end

  defp owner_pool_holder(state, source, version) do
    with {:ok, machine} <- owner_pool_machine(state, source) do
      {:ok, machine, version, machine.data.pool, machine.data.tag, machine.data.connected_at}
    end
  end

  # The after-connect Task is a distinct Holder borrower. Its destination and
  # tag come from the real child and monitor; update/4 reads its own clock.
  defp owner_task_holder(state, source, machine, version) do
    tasks =
      for {_index, pair} <- state.pairs,
          pair.source.pid == source.pid and pair.source.mfa == {DBConnection.Task, :run_child, 4},
          pair.source.index < source.index and source.index < pair.returned.index,
          do: pair

    with [task] <- tasks,
         arguments = [timeout: machine.data.after_connect_timeout] ++ machine.data.opts,
         function = machine.data.after_connect,
         {_, :call, {DBConnection.Task, :run_child, task_arguments}} <- task.source.event,
         true <- List.delete_at(task_arguments, 1) === [Postgrex.Protocol, function, arguments],
         {:ok, child, reference} <- owner_task_origin(state, task, machine),
         [monitor] <- native_type_calls(state, task.source, source, {:erlang, :monitor, 2}),
         [update] <-
           native_type_calls(
             state,
             monitor.returned,
             task.returned,
             {DBConnection.Holder, :update, 4}
           ),
         {_, :call, {DBConnection.Holder, :update, [^child, ^reference, Postgrex.Protocol, _]}} <-
           update.source.event,
         [clock] <- native_type_calls(state, update.source, source, {:erlang, :monotonic_time, 0}),
         {_, :return_from, _, connected_at} <- clock.returned.event do
      {:ok, machine, version, child, reference, connected_at}
    else
      _ -> :error
    end
  end

  # The child comes from the primitive spawn and the owner's actual startup
  # message; the monitor reference comes from its own primitive return. Neither
  # helper's checked return is an origin for the owner's client identity.
  defp owner_task_origin(state, task, machine) do
    owner = task.source.pid
    options = [timeout: machine.data.after_connect_timeout] ++ machine.data.opts
    initial = [machine.data.after_connect, owner, %DBConnection.SensitiveData{data: options}]

    with [started] <- native_type_calls(state, task.source, task.returned, {Task.Supervisor, :start_child, 4}),
         true <- started.source.event ===
           {owner, :call, {Task.Supervisor, :start_child, [DBConnection.Task, DBConnection.Task, :init, initial]}},
         [identity] <- native_type_calls(state, started.source, started.returned, {:erlang, :make_ref, 0}),
         {_, :return_from, _, startup_ref} when is_reference(startup_ref) <- identity.returned.event,
         [birth] <- Enum.filter(state.events, fn
           %{event: {_, :spawn, _, {Task.Supervised, :reply, [{_, _, ^owner}, _, :monitor]}}, index: index} ->
             started.source.index < index and index < identity.source.index
           _ -> false
         end),
         {_, :spawn, child, _} <- birth.event,
         [sent] <- Enum.filter(state.events, fn
           %{event: {^owner, :send, {^owner, ^startup_ref, ^startup_ref, _, {DBConnection.Task, :init, ^initial}}, ^child}, index: index} ->
             identity.returned.index < index and index < started.returned.index
           _ -> false
         end),
         {_, :send, message, _} <- sent.event,
         [_receipt] <- Enum.filter(state.events, fn event ->
           sent.index < event.index and event.event === {child, :receive, message}
         end),
         [monitor] <- native_type_calls(state, started.returned, task.returned, {:erlang, :monitor, 2}),
         true <- monitor.source.event === {owner, :call, {:erlang, :monitor, [:process, child]}},
         {_, :return_from, _, reference} when is_reference(reference) <- monitor.returned.event do
      {:ok, child, reference}
    else
      _ -> :error
    end
  end

  defp owner_connect_options(state, call, connect, options) do
    case Keyword.get(options, :configure) do
      nil ->
        {:ok, options}

      {module, function, arguments} ->
        owner_configure_result(state, call, connect, module, function, [options | arguments])

      callback when is_function(callback, 1) ->
        {:module, module} = Function.info(callback, :module)
        {:name, function} = Function.info(callback, :name)
        owner_configure_result(state, call, connect, module, function, [options])
    end
  end

  defp owner_configure_result(state, call, connect, module, function, arguments) do
    callbacks =
      for pair <-
            native_type_calls(state, call, connect.source, {module, function, length(arguments)}),
          pair.source.event === {call.pid, :call, {module, function, arguments}},
          {_, :return_from, _, configured} <- [pair.returned.event],
          is_list(configured),
          do: configured

    case callbacks do
      [configured] -> {:ok, configured}
      _ -> :error
    end
  end

  defp renewed_transport(
         _state,
         _source,
         %{sock: socket},
         %{protocol: %{sock: socket}} = previous
       ),
       do: {:ok, Map.take(previous, [:port, :port_owner, :tls])}

  defp renewed_transport(state, source, %{sock: {:gen_tcp, port}}, _previous) do
    connections =
      for {_index, pair} <- state.pairs,
          pair.source.pid == source.pid and pair.returned.index < source.index,
          pair.source.mfa == {:gen_tcp, :connect, 4},
          {_, :return_from, _, {:ok, ^port}} <- [pair.returned.event],
          do: pair

    case connections do
      [connection] -> {:ok, %{port: port, port_owner: connection.source.pid}}
      _ -> :error
    end
  end

  defp renewed_transport(state, _source, %{sock: {:ssl, socket}}, _previous) do
    case Enum.find(Map.get(state.native, :tls_bindings, []), &(&1.socket === socket)) do
      nil -> :error
      binding -> {:ok, %{port: binding.port, port_owner: binding.owner, tls: binding}}
    end
  end

  defp owner_public_copy(state, source, owner, holder, argument) do
    {_module, kind, _arity} = source.mfa

    case {owner_handoff_version(state, source, holder, kind), state.holder_origins[holder]} do
      {version, %{owner: expected}} when not is_nil(version) ->
        state
        |> exact(source, :state_owner_destination, owner, expected)
        |> owner_protocol_copy(source, [2, 2, argument], version)

      _ ->
        failure(state, source, :state_owner_public_origin)
    end
  end

  # handle_done reads the last committed row, deletes the holder, then sends
  # that row's Protocol to its owner. The lookup and successful deletion must
  # belong to this same pool process; the cast consumes that lookup once.
  defp owner_handoff_version(state, source, holder, kind) do
    case state.holders[holder] do
      nil when kind in [:disconnect, :stop] ->
        with %{holder: ^holder, origin: {lookup, _path}} = version <- state.lookups[source.pid],
             %{row: nil, index: deleted, origin: deletion} <-
               Enum.find(state.commits, &(&1.holder == holder)),
             %{source: %{pid: pid}} <- state.returns[deleted],
             %{pool: ^pid} <- state.holder_origins[holder],
             true <- pid == source.pid and lookup < deletion and deleted < source.index do
          version
        else
          _ -> nil
        end

      version ->
        version
    end
  end

  defp owner_loop(state, source, function, machine) do
    {state, machine} = owner_loop_commit(state, source, function, machine)
    {state, machine} = owner_backoff_message(state, source, function, machine)

    next = Map.get(state.owner_pending, source.pid, machine)

    state =
      cond do
        function in @owner_loop_current ->
          state
          |> owner_data_copy(source, [2, 2, 2, 1, 1], machine)
          |> owner_protocol_copy(source, [2, 2, 2, 1, 1, :state], machine.version)

        function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] ->
          state
          |> owner_data_copy(source, [2, 2, 5, 1, 1], machine)
          |> owner_protocol_copy(source, [2, 2, 5, 1, 1, :state], machine.version)

        true ->
          state
      end

    state = owner_loop_next_copy(state, source, function, machine, next)

    state =
      if function == :loop_state_callback_result and state.owner_pending[source.pid] do
        slot = owner_result_data(state.owner_results[source.pid])

        state
        |> owner_data_copy(source, [2, 2, 10, slot], next)
        |> owner_protocol_copy(source, [2, 2, 10, slot, :state], next.version)
        |> owner_result_copy(
          source,
          owner_term(source.event, [2, 2, 10]),
          state.owner_results[source.pid]
        )
      else
        state
      end

    state =
      if Map.has_key?(machine, :params) and function in @owner_loop_current do
        exact(
          state,
          source,
          :state_owner_params,
          owner_term(source.event, [2, 2, 0]),
          machine.params
        )
      else
        state
      end

    state
    |> owner_backoff_loop(source, function, machine, next)
    |> owner_loop_message(source, function)
  end

  defp owner_loop_next_copy(state, source, function, machine, next)
       when function in @owner_loop_next do
    expected =
      if function in [:loop_state_callback, :loop_state_callback_result],
        do: machine,
        else: next

    state
    |> owner_data_copy(source, [2, 2, 4, 1], expected)
    |> owner_protocol_copy(source, [2, 2, 4, 1, :state], expected.version)
  end

  defp owner_loop_next_copy(state, _source, _function, _machine, _next), do: state

  defp owner_backoff_message(state, source, :loop_msg_event, machine) do
    case machine do
      %{backoff_timer: {reference, _}, backoff_received: received} ->
        message = {{:timeout, :backoff}, nil}

        state =
          exact(
            state,
            source,
            :state_owner_backoff_event,
            owner_term(source.event, [2, 2, 3]),
            message
          )

        machine =
          machine
          |> Map.put(:backoff_timer, nil)
          |> Map.delete(:backoff_received)
          |> Map.delete(:backoff_program)

        if received < source.index and is_reference(reference),
          do: {put_in(state.owner_machines[source.pid], machine), machine},
          else: {failure(state, source, :state_owner_backoff_timer_origin), machine}

      _ ->
        {state, machine}
    end
  end

  defp owner_backoff_message(state, _source, _function, machine), do: {state, machine}

  defp owner_backoff_loop(state, source, function, machine, next) do
    state =
      if Map.has_key?(machine, :backoff_timer) and function in @owner_loop_current do
        timers =
          case machine.backoff_timer do
            nil -> %{}
            {reference, _} -> %{{:timeout, :backoff} => {reference, nil}}
          end

        exact(
          state,
          source,
          :state_owner_backoff_timers,
          owner_term(source.event, [2, 2, 2, 3]),
          timers
        )
      else
        state
      end

    case {state.owner_pending[source.pid], state.owner_results[source.pid]} do
      {pending, {:keep_state, _, action}} when not is_nil(pending) ->
        owner_action_copy(state, source, function, action, next)

      _ ->
        state
    end
  end

  defp owner_action_copy(state, source, :loop_actions, action, _next)
       when elem(source.mfa, 2) == 12,
       do:
         exact(state, source, :state_owner_actions, owner_term(source.event, [2, 2, 11]), action)

  defp owner_action_copy(state, source, :loop_actions_list, action, _next)
       when elem(source.mfa, 2) == 12 do
    callback = owner_callback_return(state, source)
    previous = owner_program_calls(state, source, callback, {:gen_statem, :loop_actions_list, 12})
    actions = if previous == [], do: [action], else: []
    exact(state, source, :state_owner_actions, owner_term(source.event, [2, 2, 11]), actions)
  end

  defp owner_action_copy(
         state,
         source,
         :loop_actions_next_event,
         {:next_event, type, content},
         _next
       ) do
    state
    |> exact(source, :state_owner_actions, owner_term(source.event, [2, 2, 11]), [])
    |> exact(source, :state_owner_actions, owner_term(source.event, [2, 2, 12]), type)
    |> exact(source, :state_owner_actions, owner_term(source.event, [2, 2, 13]), content)
  end

  defp owner_action_copy(
         state,
         source,
         function,
         {{:timeout, :backoff}, timeout, nil} = action,
         next
       )
       when function in [:loop_timeouts, :loop_timeouts_register] do
    {epoch, ^timeout} = next.backoff_program

    registered =
      owner_program_calls(state, source, epoch, {:gen_statem, :loop_timeouts_register, 15}) != []

    timers = owner_backoff_timer_map(state, source, next, registered)

    state =
      exact(
        state,
        source,
        :state_owner_backoff_timers,
        owner_term(source.event, [2, 2, 9]),
        timers
      )

    case {function, elem(source.mfa, 2)} do
      {:loop_timeouts, 12} ->
        actions = if registered, do: [], else: [action]
        exact(state, source, :state_owner_actions, owner_term(source.event, [2, 2, 7]), actions)

      {:loop_timeouts, 16} ->
        owner_backoff_fields(state, source, [12, 13, 14, 15], [
          {:timeout, :backoff},
          timeout,
          nil,
          []
        ])

      {:loop_timeouts_register, arity} when arity in [15, 17] ->
        owner_backoff_register_fields(state, source, next, arity, timeout)

      _ ->
        state
    end
  end

  defp owner_action_copy(state, _source, _function, _action, _next), do: state

  defp owner_backoff_timer_map(_state, _source, _next, false), do: %{}

  defp owner_backoff_timer_map(state, source, next, true) do
    case owner_backoff_timer(state, source, next) do
      {:ok, reference} -> %{{:timeout, :backoff} => {reference, nil}}
      :error -> :missing_native_backoff_timer
    end
  end

  defp owner_backoff_register_fields(state, source, next, arity, timeout) do
    case owner_backoff_timer(state, source, next) do
      {:ok, reference} ->
        {positions, values} = owner_backoff_register_values(arity, timeout, reference)
        owner_backoff_fields(state, source, positions, values)

      :error ->
        failure(state, source, :state_owner_backoff_timer_origin)
    end
  end

  defp owner_backoff_register_values(17, timeout, reference),
    do: {[12, 13, 14, 15, 16], [{:timeout, :backoff}, timeout, nil, [], reference]}

  defp owner_backoff_register_values(15, _timeout, reference),
    do: {[12, 13, 14], [{:timeout, :backoff}, reference, nil]}

  defp owner_backoff_fields(state, source, positions, values) do
    Enum.zip(positions, values)
    |> Enum.reduce(state, fn {position, value}, state ->
      exact(
        state,
        source,
        :state_owner_actions,
        owner_term(source.event, [2, 2, position]),
        value
      )
    end)
  end

  defp owner_program_calls(state, source, after_index, mfa) do
    Enum.filter(
      state.events,
      &(&1.pid == source.pid and &1.index > after_index and &1.index < source.index and
          &1.mfa == mfa and elem(&1.event, 1) == :call)
    )
  end

  defp owner_callback_return(state, source) do
    state.pairs
    |> Map.values()
    |> Enum.filter(
      &(&1.source.pid == source.pid and
          &1.source.mfa == {DBConnection.Connection, :handle_event, 4} and
          &1.returned.index < source.index)
    )
    |> Enum.map(& &1.returned.index)
    |> Enum.max(fn -> -1 end)
  end

  defp owner_backoff_timer(state, source, %{backoff_program: {epoch, timeout}}) do
    timers =
      for {_index, pair} <- state.pairs,
          pair.source.pid == source.pid and pair.source.index > epoch and
            pair.returned.index < source.index,
          pair.source.event ===
            {source.pid, :call,
             {:erlang, :start_timer, [timeout, source.pid, {:timeout, :backoff}, []]}},
          {_, :return_from, {:erlang, :start_timer, 4}, reference} <- [pair.returned.event],
          is_reference(reference),
          do: reference

    case timers do
      [reference] -> {:ok, reference}
      _ -> :error
    end
  end

  defp owner_data_copy(state, source, path, machine) do
    case owner_term(source.event, path) do
      actual when is_map(actual) ->
        # The Protocol field has its own sole-catcher copy proof below. Check
        # every other machine field here without duplicating that obligation.
        exact(
          state,
          source,
          :state_owner_machine,
          owner_data_fields(actual),
          owner_data_fields(machine.data)
        )

      _ ->
        failure(state, source, :state_owner_machine)
    end
  end

  defp owner_holder_fields(row) when is_tuple(row) and tuple_size(row) == 8,
    do: Tuple.delete_at(row, 3)

  defp owner_holder_fields(row), do: {:invalid_native_holder_row, row}

  defp owner_data_fields(data), do: {Map.has_key?(data, :state), Map.delete(data, :state)}

  defp owner_result_copy(state, source, actual, expected) do
    slot = owner_result_data(expected)

    case actual do
      value
      when is_tuple(value) and tuple_size(value) == tuple_size(expected) and
             is_map(elem(value, slot)) ->
        actual = put_elem(actual, slot, owner_data_fields(elem(actual, slot)))
        expected = put_elem(expected, slot, owner_data_fields(elem(expected, slot)))
        exact(state, source, :state_owner_result, actual, expected)

      _ ->
        failure(state, source, :state_owner_result)
    end
  end

  defp owner_result_data({:stop, _, _}), do: 2
  defp owner_result_data({:stop_and_reply, _, _, _}), do: 3
  defp owner_result_data(_result), do: 1

  defp owner_loop_commit(state, source, function, machine)
       when function in [:loop_done, :reply_then_terminate, :do_reply_then_terminate, :terminate] do
    case Map.pop(state.owner_pending, source.pid) do
      {nil, _pending} ->
        {state, machine}

      {next, pending} ->
        state = %{state | owner_pending: pending}
        {state, next} = owner_backoff_commit(state, source, next)
        commit = %{owner: source.pid, index: source.index, machine: next}
        state = Map.update!(state, :owner_commits, &[commit | &1])
        state = update_in(state.owner_received, &Map.delete(&1, source.pid))
        {put_in(state.owner_machines[source.pid], next), next}
    end
  end

  defp owner_loop_commit(state, _source, _function, machine), do: {state, machine}

  defp owner_backoff_commit(state, source, %{backoff_program: {epoch, _}} = next) do
    case next.backoff_timer do
      {_reference, ^epoch} ->
        {state, next}

      _ ->
        case owner_backoff_timer(state, source, next) do
          {:ok, reference} -> {state, %{next | backoff_timer: {reference, epoch}}}
          :error -> {failure(state, source, :state_owner_backoff_timer_origin), next}
        end
    end
  end

  defp owner_backoff_commit(state, _source, next), do: {state, next}

  defp owner_loop_message(state, source, function) do
    case state.owner_received[source.pid] do
      nil ->
        state

      context ->
        base =
          case function do
            function when function in [:loop_msg, :loop_msg_event] ->
              [2, 2, 3, 1]

            function
            when function in [
                   :loop_event,
                   :loop_state_callback,
                   :loop_state_callback_result,
                   :loop_actions,
                   :loop_actions_list,
                   :loop_actions_reply,
                   :loop_actions_next_event,
                   :loop_state_enter,
                   :loop_state_change,
                   :loop_state_transition
                 ] ->
              [2, 2, 3, 0, 1]

            _ ->
              nil
          end

        state =
          if base do
            path = base ++ [tuple_size(context.message) - 1]
            owner_protocol_copy(state, source, path, context.version)
          else
            state
          end

        if source.mfa == {:gen_statem, :loop_state_callback, 11} do
          owner_protocol_copy(
            state,
            source,
            [2, 2, 10, 1, tuple_size(context.message) - 1],
            context.version
          )
        else
          state
        end
    end
  end

  defp owner_message_program(state, source) do
    context =
      Enum.find_value(state.owner_messages, fn {_index, context} ->
        if source.pid == context.source.pid and source.index > context.source.index and
             source.index < context.returned.index,
           do: context
      end)

    case {context, source.event} do
      {nil, _} ->
        state

      {context, {_, :call, {module, :send, [_owner, _message]}}}
      when module in [:gen_statem, :erlang] ->
        owner_protocol_copy(
          state,
          source,
          [2, 2, 1, 1, tuple_size(context.message) - 1],
          context.version
        )

      {context, {_, :send, _message, _owner}} ->
        owner_protocol_copy(
          state,
          source,
          [2, 1, tuple_size(context.message) - 1],
          context.version
        )

      {context, {_, :return_from, {:erlang, :send, 2}, _message}} ->
        owner_protocol_copy(
          state,
          source,
          [3, 1, tuple_size(context.message) - 1],
          context.version
        )

      _ ->
        state
    end
  end

  defp owner_protocol_copy(state, source, path, version) do
    actual = owner_term(source.event, path)

    state
    |> exact(source, :state_owner_copy, actual, version.protocol)
    |> copy(source, path, version)
  end

  defp owner_term(value, []), do: value

  defp owner_term(value, [key | path])
       when is_tuple(value) and is_integer(key) and
              key >= 0 and key < tuple_size(value),
       do: owner_term(elem(value, key), path)

  defp owner_term(value, [key | path]) when is_list(value) and is_integer(key),
    do: owner_term(Enum.at(value, key), path)

  defp owner_term(value, [key | path]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, value} -> owner_term(value, path)
      :error -> :missing_native_owner_term
    end
  end

  defp owner_term(_value, _path), do: :missing_native_owner_term

  # Callback returns can be valid temporary versions without ever reaching ETS.
  # A committed row changes only at a successful native mutation's own return.
  # Preserve all seven fields together, including writes without a Protocol.
  defp committed_row(%{event: {_, :return_from, {:ets, function, _}, true}} = source, state)
       when function in [:insert, :insert_new, :update_element, :delete] do
    case pair_returned(state, source) do
      %{source: %{event: {_, :call, {:ets, ^function, arguments}}} = call} ->
        row_write(state, source.index, call.index, function, arguments)

      _ ->
        state
    end
  end

  defp committed_row(_source, state), do: state

  defp row_write(
         state,
         index,
         origin,
         function,
         [holder, {:conn, _, Postgrex.Protocol, %Postgrex.Protocol{}, _, _, _, _} = row]
       )
       when function in [:insert, :insert_new],
       do: retain_row(state, holder, row, index, origin)

  defp row_write(state, index, origin, :update_element, [holder, :conn, updates]) do
    case Map.fetch(state.rows, holder) do
      {:ok, row} -> retain_row(state, holder, update_elements(row, updates), index, origin)
      :error -> state
    end
  end

  defp row_write(state, index, origin, :delete, [holder]) do
    if Map.has_key?(state.rows, holder),
      do: retain_row(state, holder, nil, index, origin),
      else: state
  end

  defp row_write(state, _index, _origin, _function, _arguments), do: state

  defp retain_row(state, holder, row, index, origin) do
    rows =
      if is_nil(row), do: Map.delete(state.rows, holder), else: Map.put(state.rows, holder, row)

    commit = %{holder: holder, index: index, origin: origin, row: row}
    holders = if is_nil(row), do: Map.delete(state.holders, holder), else: state.holders
    %{state | rows: rows, holders: holders, commits: [commit | state.commits]}
  end

  # The cache is an ETS set. Keep complete rows from the initial native table,
  # then apply only the writes whose own BIF returned successfully. A helper
  # return or a failed insert_new cannot advance this committed history.
  defp committed_table(%{event: {_, :return_from, {:ets, :new, 2}, table}} = source, state) do
    case pair_returned(state, source) do
      %{
        source: %{event: {_, :call, {:ets, :new, [Postgrex.Protocol, [:set, :public]]}}} = call
      } ->
        retain_table(state, table, [], source.index, call.index)

      _ ->
        state
    end
  end

  defp committed_table(%{event: {_, :return_from, {:ets, function, _}, true}} = source, state)
       when function in [
              :insert,
              :insert_new,
              :update_element,
              :delete,
              :delete_object,
              :delete_all_objects
            ] do
    with %{source: %{event: {_, :call, {:ets, ^function, [table | arguments]}}} = call} <-
           pair_returned(state, source),
         {:ok, rows} <- Map.fetch(state.tables, table) do
      rows = table_write(function, arguments, rows)
      present? = function != :delete or arguments != []
      retain_table(state, table, rows, source.index, call.index, present?)
    else
      _ -> state
    end
  end

  defp committed_table(_source, state), do: state

  defp table_write(function, [objects], rows) when function in [:insert, :insert_new] do
    objects = if is_list(objects), do: objects, else: [objects]
    keys = MapSet.new(objects, &elem(&1, 0))
    Enum.reject(rows, &MapSet.member?(keys, elem(&1, 0))) ++ objects
  end

  defp table_write(:update_element, [key, updates], rows) do
    Enum.map(rows, &update_cache_row(&1, key, updates))
  end

  defp table_write(:delete, [key], rows), do: Enum.reject(rows, &(elem(&1, 0) === key))
  defp table_write(:delete_object, [object], rows), do: Enum.reject(rows, &(&1 === object))
  defp table_write(function, [], _rows) when function in [:delete, :delete_all_objects], do: []

  defp update_cache_row(row, key, updates) when elem(row, 0) === key,
    do: update_elements(row, updates)

  defp update_cache_row(row, _key, _updates), do: row

  defp update_elements(row, updates) do
    updates = if is_list(updates), do: updates, else: [updates]
    Enum.reduce(updates, row, fn {field, value}, row -> put_elem(row, field - 1, value) end)
  end

  defp retain_table(state, table, rows, index, origin, present? \\ true) do
    commit = %{table: table, index: index, origin: origin, rows: rows, present?: present?}

    tables =
      if present?, do: Map.put(state.tables, table, rows), else: Map.delete(state.tables, table)

    %{
      state
      | tables: tables,
        table_commits: [commit | state.table_commits]
    }
  end

  # The true table-owner BIF identifies shared services without making them
  # root descendants. Their receive trace is mailbox ingress; decode_msg/6
  # consumes the FIFO receipt before any dispatch copy is qualified.
  defp native_type_services(pairs) do
    for {_index, pair} <- pairs,
        pair.source.mfa == {:ets, :info, 2},
        {Postgrex.Types, :owner, 1} in pair.source.stack,
        {_, :call, {:ets, :info, [_table, :owner]}} <- [pair.source.event],
        {_, :return_from, _, owner} <- [pair.returned.event],
        is_pid(owner),
        into: MapSet.new(),
        do: owner
  end

  defp type_service_event(%{event: {pid, :receive, message}} = source, state) do
    if MapSet.member?(state.type_services, pid) do
      queue = Map.get(state.service_queues, pid, :queue.new())
      state = put_in(state.service_queues[pid], :queue.in(source, queue))
      terminal_service_copy(state, source, message, [2], service_terminal(state, pid, message))
    else
      state
    end
  end

  defp type_service_event(
         %{event: {pid, :call, {:gen_server, :decode_msg, [_, _, _, _, _, message]}}} = source,
         state
       ) do
    if MapSet.member?(state.type_services, pid) do
      queue = Map.get(state.service_queues, pid, :queue.new())

      case :queue.out(queue) do
        {{:value, receipt}, remaining} ->
          {^pid, :receive, expected} = receipt.event
          state = exact(state, source, :state_service_receive, message, expected)
          context = service_terminal(state, pid, expected)

          state
          |> put_in([:service_queues, pid], remaining)
          |> put_in([:service_current, pid], context)
          |> terminal_service_copy(source, message, [2, 2, 5], context)

        {:empty, _} ->
          # The native relative-timeout branch synthesizes this atom; it has
          # no Protocol copy. Every ordinary message requires its real receipt.
          state = exact(state, source, :state_service_receive, message, :timeout)
          put_in(state.service_current[pid], nil)
      end
    else
      state
    end
  end

  defp type_service_event(
         %{event: {pid, :call, {Postgrex.TypeServer, :handle_info, [message, _state]}}} =
           source,
         state
       ) do
    terminal_service_copy(state, source, message, [2, 2, 0], state.service_current[pid])
  end

  defp type_service_event(
         %{event: {pid, :call, {:gen_server, function, arguments}}} = source,
         state
       )
       when (function == :decode_msg and length(arguments) == 4) or
              (function == :handle_msg and length(arguments) in [3, 4]) or
              (function == :try_handle_info and length(arguments) == 3) or
              (function == :handle_common_reply and length(arguments) in [5, 6]) do
    terminal_service_copy(
      state,
      source,
      Enum.at(arguments, 2),
      [2, 2, 2],
      state.service_current[pid]
    )
  end

  defp type_service_event(_source, state), do: state

  defp service_terminal(state, server, {:EXIT, child, _reason}) do
    case {state.type_owners[child], state.reload_children[child]} do
      {%{server: ^server}, %{terminal: terminal, terminal_version: version}} ->
        %{message: {:EXIT, child, terminal}, version: version}

      _ ->
        nil
    end
  end

  defp service_terminal(_state, _server, _message), do: nil

  defp terminal_service_copy(state, _source, _message, _path, nil), do: state

  defp terminal_service_copy(state, source, message, path, context) do
    state =
      helper_copy(
        state,
        source,
        path,
        message,
        context.message,
        {:reload_service_exit, context.version.origin}
      )

    copy(state, source, path ++ [2, 1], context.version)
  end

  defp factory_event(
         %{event: {pid, :return_from, {Postgrex.Protocol, function, 1}, value}} = source,
         state
       )
       when function in [:notify, :mode] do
    with %{source: callback} = frame <- status_callback(state, pid),
         {:ok, options} <- status_options(frame),
         %{source: %{event: {^pid, :call, {Postgrex.Protocol, ^function, [actual]}}}} <-
           pair_returned(state, source) do
      state = exact(state, source, :state_status_factory_input, actual, options)
      state = factory_value(state, source, function, value, options)

      put_in(state.factories[{callback.index, function}], %{
        value: factory_expected(state, function, options),
        native: value,
        index: source.index
      })
    else
      _ -> failure(state, source, :state_status_factory_origin)
    end
  end

  defp factory_event(%{event: {_, :call, {module, function, arguments}}} = source, state)
       when (module == Postgrex.Protocol and function == :fetch_type_info) or
              (module == Postgrex.Types and function == :fetch) do
    case type_context(state, source) do
      {:ok, input, first} ->
        progress = type_progress(state, source, input, first)

        expected = type_arguments(module, length(arguments), input, progress)
        origin = {:type_factory, first, progress.origins}
        type_input_copies(state, source, arguments, expected, origin)

      :error ->
        failure(state, source, :state_type_factory_origin)
    end
  end

  defp factory_event(
         %{event: {_, :return_from, {Postgrex.Protocol, :fetch_type_info, _}, actual}} = source,
         state
       ) do
    case type_context(state, source) do
      {:ok, input, first} ->
        progress = type_progress(state, source, input, first)

        expected = type_result(progress)

        origin = {:type_factory_result, first, progress.origins}

        case {actual, expected} do
          {_, :no_type_origin} ->
            failure(state, source, :state_type_factory_origin)

          {{tag, payload}, {expected_tag, expected_payload}} ->
            state
            |> helper_copy(source, [3, 0], tag, expected_tag, origin)
            |> helper_copy(source, [3, 1], payload, expected_payload, origin)

          _ ->
            helper_copy(state, source, [3], actual, expected, origin)
        end

      :error ->
        failure(state, source, :state_type_factory_origin)
    end
  end

  defp factory_event(
         %{event: {_, :call, {Postgrex.Protocol, :columns, [actual]}}} = source,
         state
       ) do
    case Map.fetch(state.decoders.query_inputs, source.index) do
      {:ok, input} ->
        helper_copy(
          state,
          source,
          [2, 2, 0],
          actual,
          input.fields,
          {:row_description, input.origin}
        )

      :error ->
        failure(state, source, :state_helper_query_origin)
    end
  end

  defp factory_event(
         %{event: {_, :return_from, {Postgrex.Protocol, :columns, 1}, actual}} = source,
         state
       ) do
    with %{source: call} <- pair_returned(state, source),
         {:ok, input} <- Map.fetch(state.decoders.query_inputs, call.index) do
      expected = {input.result_oids, input.columns, input.result_mods}
      origin = {:column_factory, input.origin}

      column_result_copies(state, source, actual, expected, origin)
    else
      _ -> failure(state, source, :state_helper_query_origin)
    end
  end

  defp factory_event(
         %{event: {_, :return_from, {Postgrex.Types, :fetch, 2}, actual}} = source,
         state
       ) do
    with %{source: call} = pair <- pair_returned(state, source),
         {:ok, input, first} <- type_context(state, source),
         %{remaining: [oid | _]} <- type_progress(state, source, input, first),
         {:ok, expected, origins} <- ConnectionTypes.fetch(state.pairs, pair, oid, input.types) do
      origin = {:native_type_lookup, call.index, origins}
      type_return_copies(state, source, actual, expected, origin)
    else
      _ -> failure(state, source, :state_type_native_origin)
    end
  end

  defp factory_event(%{event: {_, :call, {module, function, arguments}}} = source, state)
       when (module == Postgrex.Types and function in [:owner, :build_type_info]) or
              (module == Postgrex.TypeServer and function in [:fetch, :update]) do
    case native_type_model(state, source) do
      {:ok, expected_arguments, result, origin} ->
        state = type_input_copies(state, source, arguments, expected_arguments, origin)

        put_in(state.type_models[source.index], %{
          result: result,
          origin: origin,
          arguments: expected_arguments
        })

      :error ->
        failure(state, source, :state_type_native_origin)
    end
  end

  defp factory_event(
         %{event: {pid, :call, {Postgrex.TypeSupervisor, :locate, arguments}}} = source,
         state
       ) do
    case state.starting[pid] do
      nil ->
        failure(state, source, :state_type_location_origin)

      context ->
        expected = [Keyword.fetch!(context.options, :types), context.endpoint]

        type_input_copies(
          state,
          source,
          arguments,
          expected,
          {:type_location, context.source.index}
        )
    end
  end

  defp factory_event(
         %{event: {pid, :return_from, {Postgrex.TypeSupervisor, :locate, 2}, actual}} = source,
         state
       ) do
    with context when not is_nil(context) <- state.starting[pid],
         module <- Keyword.fetch!(context.options, :types),
         [{owner, root}] <-
           Enum.filter(state.type_roots, fn {_owner, root} ->
             {module, context.endpoint} in root.registration_keys and root.index < source.index and
               is_integer(root.initialized) and root.initialized < source.index and
               (is_nil(Map.get(root, :retired)) or root.retired > source.index)
           end) do
      origin = {:type_location, context.source.index, root.index}

      state
      |> helper_copy(source, [3], actual, owner, origin)
      |> put_in([:type_locations, pid], %{
        owner: owner,
        types: root.types,
        constructor: context.source.index,
        index: source.index
      })
    else
      _ -> failure(state, source, :state_type_location_origin)
    end
  end

  defp factory_event(%{event: {pid, :return_from, {module, function, _}, actual}} = source, state)
       when (module == Postgrex.Types and function in [:owner, :build_type_info]) or
              (module == Postgrex.TypeServer and function in [:fetch, :update]) do
    with %{source: call} <- pair_returned(state, source),
         %{result: expected, origin: origin, arguments: arguments} <-
           state.type_models[call.index] do
      state = type_return_copies(state, source, actual, expected, origin)

      case {module, function, expected} do
        {Postgrex.Types, :owner, {:ok, server}} ->
          put_in(state.type_owners[pid], %{server: server, origin: origin})

        {Postgrex.TypeServer, :fetch, {:lock, ref, types}} ->
          [server] = arguments
          lock = %{server: server, ref: ref, types: types, origin: origin}
          put_in(state.type_locks[pid], lock)

        _ ->
          state
      end
    else
      _ -> failure(state, source, :state_type_native_origin)
    end
  end

  defp factory_event(_source, state), do: state

  defp type_return_copies(state, source, actual, expected, origin)
       when is_tuple(actual) and is_tuple(expected) and
              tuple_size(actual) == tuple_size(expected) do
    Enum.reduce(0..(tuple_size(expected) - 1), state, fn position, state ->
      helper_copy(
        state,
        source,
        [3, position],
        elem(actual, position),
        elem(expected, position),
        origin
      )
    end)
  end

  defp type_return_copies(state, source, actual, expected, origin),
    do: helper_copy(state, source, [3], actual, expected, origin)

  defp native_type_model(state, %{mfa: {Postgrex.Types, :owner, 1}} = source) do
    with {:ok, {_, table} = types} <- native_type_state(state, source),
         %{returned: returned} <- state.pairs[source.index],
         [lookup] <- native_type_calls(state, source, returned, {:ets, :info, 2}),
         {_, :call, {:ets, :info, [^table, :owner]}} <- lookup.source.event,
         {_, :return_from, _, owner} <- lookup.returned.event do
      case owner do
        owner when is_pid(owner) ->
          {:ok, [types], {:ok, owner}, {:type_table_owner, lookup.source.index}}

        :undefined ->
          {:ok, [types], :error, {:type_table_owner, lookup.source.index}}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp native_type_model(state, %{mfa: {Postgrex.Types, :build_type_info, 1}} = source) do
    case List.last(reload_catalog_rows(state, source)) do
      {instance, info} ->
        {:ok, {:msg_data_row, values}, _} = instance.expected
        {:ok, [values], info, {:native_catalog, instance.returned.index}}

      nil ->
        :error
    end
  end

  defp native_type_model(state, %{pid: pid, mfa: {Postgrex.TypeServer, :fetch, 1}} = source) do
    with {:ok, server, types} <- type_server_origin(state, source, pid),
         {:ok, callback, from, reply, completion} <-
           type_server_request(state, source, server, :fetch),
         {^server, :call, {_, _, [:fetch, ^from, %{types: ^types}]}} <- callback.source.event,
         [{ref, monitor}] <- type_lock_monitors(state, callback, server, pid),
         {:lock, ^ref, ^types} <- reply do
      {:ok, [server], reply, {:native_type_lock, callback.source.index, monitor, completion}}
    else
      _ -> :error
    end
  end

  defp native_type_model(state, %{pid: pid, mfa: {Postgrex.TypeServer, :update, 3}} = source) do
    with %{server: server, ref: ref, types: types} <- state.type_locks[pid],
         infos when infos != [] <- Enum.map(reload_catalog_rows(state, source), &elem(&1, 1)),
         infos <-
           if(is_map_key(state.starting, pid), do: infos, else: Enum.sort_by(infos, & &1.oid)),
         request <- {:update, ref, infos},
         {:ok, callback, from, :go, completion} <-
           type_server_request(state, source, server, request),
         {^server, :call, {_, _, [^request, ^from, %{types: ^types, lock: ^ref}]}} <-
           callback.source.event do
      {:ok, [server, ref, infos], :go, {:native_type_update, callback.source.index, completion}}
    else
      _ -> :error
    end
  end

  defp type_server_origin(state, source, pid) do
    case state.starting[pid] do
      nil ->
        with %{server: server} <- state.type_owners[pid],
             {:ok, types} <- native_type_state(state, source) do
          {:ok, server, types}
        else
          _ -> :error
        end

      context ->
        constructor_type_server_origin(state, source, context)
    end
  end

  defp constructor_type_server_origin(state, source, context) do
    with %{owner: server, types: types, constructor: constructor, index: index} <-
           state.type_locations[source.pid],
         true <- constructor == context.source.index and index < source.index do
      {:ok, server, types}
    else
      _ -> :error
    end
  end

  defp native_type_state(state, %{pid: pid}) do
    case {state.reload_children[pid], Map.get(state.frames, pid, [])} do
      {%{version: %{protocol: %{types: types}}}, _} -> {:ok, types}
      {_, [%{current: %{types: types}} | _]} -> {:ok, types}
      _ -> :error
    end
  end

  defp native_type_calls(state, source, returned, mfa) do
    state.pairs
    |> Map.values()
    |> Enum.filter(fn pair ->
      pair.source.pid == source.pid and pair.source.index > source.index and
        pair.returned.index < returned.index and pair.source.mfa == mfa
    end)
    |> Enum.sort_by(& &1.source.index)
  end

  defp type_lock_monitors(state, callback, server, pid) do
    for pair <-
          native_type_calls(state, callback.source, callback.returned, {:erlang, :monitor, 2}),
        pair.source.event == {server, :call, {:erlang, :monitor, [:process, pid]}},
        {_, :return_from, _, ref} <- [pair.returned.event],
        is_reference(ref),
        do: {ref, pair.source.index}
  end

  defp type_server_request(state, source, server, request, module \\ Postgrex.TypeServer) do
    pair = Map.fetch!(state.pairs, source.index)
    caller = source.pid

    requests =
      for %{event: {^caller, :send, envelope, ^server}} = sent <- state.events,
          {:"$gen_call", {^caller, _} = from, ^request} <- [envelope],
          sent.index > source.index and sent.index < pair.returned.index,
          do: {sent, from, envelope}

    with [{sent, from, envelope}] <- requests,
         [received] <- Enum.filter(state.events, &(&1.event === {server, :receive, envelope})),
         true <- sent.index < received.index,
         [callback] <- type_server_callbacks(state, pair, received, server, request, from, module),
         {_, tag} <- from,
         [{reply_event, result}] <-
           for(
             %{event: {^caller, :receive, {^tag, result}}} = reply <- state.events,
             reply.index > callback.source.index and reply.index < pair.returned.index,
             do: {reply, result}
           ),
         [sent_reply] <-
           for(
             %{event: {^server, :send, {^tag, ^result}, _}} = reply <- state.events,
             reply.index > callback.source.index and reply.index < reply_event.index,
             do: reply
           ),
         true <- sent_reply.index < reply_event.index,
         :return_from <- elem(callback.returned.event, 1) do
      {:ok, callback, from, result, callback.returned.index}
    else
      _ -> :error
    end
  end

  defp type_server_callbacks(state, pair, received, server, request, from, module) do
    for {_index, callback} <- state.pairs,
        callback.source.index > received.index and callback.source.index < pair.returned.index,
        {^server, :call, {^module, :handle_call, [^request, ^from, _]}} <-
          [callback.source.event],
        do: callback
  end

  defp type_context(state, source) do
    frame =
      Enum.find(Map.get(state.frames, source.pid, []), fn frame ->
        elem(frame.source.mfa, 1) in [
          :describe_params,
          :describe_result,
          :reload_describe_result
        ]
      end)

    with %{source: owner} <- frame,
         {:ok, input} <- Map.fetch(state.decoders.query_inputs, owner.index) do
      oids = type_oids(elem(owner.mfa, 1), input)
      {:ok, %{oids: oids, types: input.types}, owner.index}
    else
      _ -> reload_type_context(state, source)
    end
  end

  defp reload_type_context(state, source) do
    case active_reload(state, source.pid, source.index) do
      %{source: owner, oids: oids, version: version} ->
        {:ok, %{oids: Enum.to_list(oids), types: version.protocol.types}, owner.index}

      _ ->
        reload_dependency_context(state, source)
    end
  end

  defp reload_dependency_context(state, source) do
    with %{version: version} <- state.reload_children[source.pid],
         rows when rows != [] <- reload_catalog_rows(state, source),
         {row, info} <- List.last(rows) do
      new = rows |> Enum.drop(-1) |> MapSet.new(fn {_row, info} -> info.oid end)

      dependencies =
        Enum.reject(
          [info.array_elem, info.base_type | info.comp_elems],
          &(&1 == 0 or MapSet.member?(new, &1))
        )

      earlier =
        Enum.count(state.pairs, fn {_index, pair} ->
          pair.source.pid == source.pid and pair.source.mfa == {Postgrex.Types, :fetch, 2} and
            pair.source.index > row.returned.index and pair.returned.index < source.index
        end)

      case Enum.fetch(dependencies, earlier) do
        {:ok, oid} -> {:ok, %{oids: [oid], types: version.protocol.types}, source.index}
        :error -> :error
      end
    else
      _ -> :error
    end
  end

  defp reload_catalog_rows(state, source) do
    for instance <- state.decoders.instances,
        instance.returned.pid == source.pid and instance.returned.index < source.index,
        {:ok, {:msg_data_row, values}, _buffer} <- [instance.expected],
        do: {instance, ConnectionTypes.catalog(values)}
  end

  defp type_oids(:describe_params, input), do: input.param_oids
  defp type_oids(:describe_result, input), do: input.result_oids
  defp type_oids(:reload_describe_result, input), do: input.result_oids

  defp type_arguments(Postgrex.Types, 2, input, %{remaining: [oid | _]}),
    do: [oid, input.types]

  defp type_arguments(Postgrex.Protocol, 2, input, _progress), do: [input.oids, input.types]
  defp type_arguments(Postgrex.Protocol, 3, input, _progress), do: [input.oids, input.types, []]

  defp type_arguments(Postgrex.Protocol, 4, input, progress),
    do: [progress.remaining, input.types, progress.infos, progress.reloads]

  defp type_arguments(_module, _arity, _input, _progress), do: :no_type_origin

  defp type_input_copies(state, source, _arguments, :no_type_origin, _origin),
    do: failure(state, source, :state_type_factory_origin)

  defp type_input_copies(state, source, arguments, expected, origin) do
    expected
    |> Enum.with_index()
    |> Enum.reduce(state, fn {value, position}, state ->
      helper_copy(state, source, [2, 2, position], Enum.at(arguments, position), value, origin)
    end)
  end

  defp type_result(%{error: {%Postgrex.TypeInfo{} = info, module}}),
    do: {:error, Postgrex.QueryError.exception(Postgrex.Utils.type_msg(info, module))}

  defp type_result(%{error: nil} = progress) do
    if MapSet.size(progress.reloads) == 0,
      do: {:ok, Enum.reverse(progress.infos)},
      else: {:reload, progress.reloads}
  end

  defp type_result(%{error: :invalid}), do: :no_type_origin

  defp column_result_copies(state, source, actual, expected, origin)
       when is_tuple(actual) and tuple_size(actual) == 3 do
    Enum.reduce(0..2, state, fn position, state ->
      helper_copy(
        state,
        source,
        [3, position],
        elem(actual, position),
        elem(expected, position),
        origin
      )
    end)
  end

  defp column_result_copies(state, source, actual, expected, origin),
    do: helper_copy(state, source, [3], actual, expected, origin)

  defp type_progress(state, source, input, first) do
    initial = %{remaining: input.oids, infos: [], reloads: MapSet.new(), origins: [], error: nil}

    state.pairs
    |> Map.values()
    |> Enum.filter(
      &(&1.source.pid == source.pid and &1.source.index > first and
          &1.returned.index < source.index and &1.source.mfa == {Postgrex.Types, :fetch, 2})
    )
    |> Enum.sort_by(& &1.source.index)
    |> Enum.reduce(initial, &type_progress_step(&1, &2, state.pairs, input.types))
  end

  defp type_progress_step(pair, %{remaining: [oid | remaining]} = progress, pairs, types) do
    case ConnectionTypes.fetch(pairs, pair, oid, types) do
      {:ok, result, origins} ->
        progress = %{progress | remaining: remaining, origins: progress.origins ++ origins}
        type_progress_result(result, oid, progress)

      :error ->
        %{progress | error: :invalid}
    end
  end

  defp type_progress_step(_pair, progress, _pairs, _types),
    do: %{progress | error: :invalid}

  defp type_progress_result({:ok, info}, _oid, progress),
    do: %{progress | infos: [info | progress.infos]}

  defp type_progress_result({:error, nil, _module}, oid, progress),
    do: %{progress | reloads: MapSet.put(progress.reloads, oid)}

  defp type_progress_result({:error, %Postgrex.TypeInfo{} = info, module}, _oid, progress),
    do: %{progress | error: {info, module}}

  defp type_progress_result(_result, _oid, progress), do: %{progress | error: :invalid}

  defp factory_value(state, source, function, actual, options) do
    expected = factory_expected(state, function, options)
    actual = factory_observed(state, actual, expected)
    exact(state, source, :state_status_factory_value, actual, expected)
  end

  defp factory_expected(_state, :mode, options), do: options[:mode] || :transaction

  defp factory_expected(state, :notify, options) do
    options[:notify] ||
      {:compiled_factory, Map.fetch!(state.decoders.factory_identities, :notify), []}
  end

  defp factory_observed(state, actual, {:compiled_factory, _identity, _environment})
       when is_function(actual) do
    Map.get(state.decoders.factory_observations, actual, :missing_observed_factory)
  end

  defp factory_observed(_state, actual, _expected), do: actual

  defp status_callback(state, pid) do
    Enum.find(Map.get(state.frames, pid, []), &(elem(&1.source.mfa, 1) in @last_state))
  end

  defp status_options(%{source: %{event: {_, :call, {_, :ping, [_]}}}}), do: {:ok, []}

  defp status_options(%{source: %{event: {_, :call, {_, :ping, [_protocol, options]}}}}),
    do: {:ok, options}

  defp status_options(%{source: %{event: {_, :call, {_, function, arguments}}}})
       when function in @last_state do
    case Enum.at(arguments, -2) do
      options when is_list(options) -> {:ok, options}
      _ -> :error
    end
  end

  defp status_options(_frame), do: :error

  defp status_input(state, source, :handle_msg, [_protocol, actual, _message])
       when is_map_key(state.starting, source.pid) do
    context = state.starting[source.pid]
    options = startup_options(context.options)
    options = if context.authenticated?, do: Keyword.delete(options, :password), else: options
    lock = state.type_locks[source.pid]

    expected = %{
      opts: options,
      types_mod: context.options[:types],
      types_key: if(context.options[:types], do: context.endpoint),
      types_lock: if(lock, do: {lock.server, lock.ref}),
      prepare: context.options[:prepare] || :named,
      messages: [],
      ssl: nil,
      ssl_negotiation: context.options[:ssl_negotiation] || :postgres,
      channel_binding: context.options[:channel_binding] || :prefer,
      target_server_type: context.options[:target_server_type] || :any
    }

    helper_copy(
      state,
      source,
      [2, 2, 1],
      actual,
      expected,
      {:constructor_status, context.source.index}
    )
  end

  defp status_input(state, source, function, arguments) when function in @status_consumers do
    with %{source: callback} = frame <- status_callback(state, source.pid),
         {:ok, options} <- status_options(frame),
         %{value: notify, index: notify_index} <- state.factories[{callback.index, :notify}],
         {:ok, mode} <- status_mode(state, frame, options) do
      prepare =
        if elem(callback.mfa, 1) == :handle_prepare,
          do: Keyword.get(options, :postgrex_prepare, false),
          else: false

      expected = %{notify: notify, mode: mode, prepare: prepare}
      actual = Enum.at(arguments, 1)

      actual =
        if is_map(actual) and Map.has_key?(actual, :notify),
          do: Map.update!(actual, :notify, &factory_observed(state, &1, notify)),
          else: actual

      state = exact(state, source, :state_status_copy, actual, expected)
      origin = {:callback_status, callback.index, notify_index}
      term = %{index: source.index, path: [2, 2, 1], origin: origin}

      state
      |> Map.update!(:terms, &[term | &1])
      |> put_in([:term_values, {source.index, term.path}], %{value: expected, origin: origin})
    else
      _ -> failure(state, source, :state_status_origin)
    end
  end

  defp status_input(state, _source, _function, _arguments), do: state

  defp status_mode(_state, %{source: %{mfa: {_, function, _}}}, _options)
       when function in [:ping, :handle_begin, :handle_commit, :handle_rollback, :handle_info],
       do: {:ok, :transaction}

  defp status_mode(
         _state,
         %{source: %{event: {_, :call, {_, :handle_execute, [%Postgrex.TextQuery{} | _]}}}},
         _options
       ),
       do: {:ok, :transaction}

  defp status_mode(
         _state,
         %{
           input: %{postgres: {_, locked_ref}},
           source: %{
             event:
               {_, :call, {_, :handle_fetch, [_, %Postgrex.Cursor{ref: ref, mode: mode}, _, _]}}
           }
         },
         _options
       )
       when ref == locked_ref,
       do: {:ok, mode}

  defp status_mode(
         state,
         %{source: %{event: {_, :call, {_, :handle_deallocate, [_, cursor, _, protocol]}}}} =
           frame,
         options
       ) do
    case protocol.postgres do
      {_, ref} when ref == cursor.ref -> factory_mode(state, frame, options)
      _ -> {:ok, :transaction}
    end
  end

  defp status_mode(state, frame, options), do: factory_mode(state, frame, options)

  defp factory_mode(state, %{source: callback}, options) do
    case state.factories[{callback.index, :mode}] do
      %{value: mode} when mode in [:transaction, :savepoint] ->
        if mode == (options[:mode] || :transaction), do: {:ok, mode}, else: :error

      _ ->
        :error
    end
  end

  defp fixture_event(
         %{event: {_, :call, {Root, :invoke, [_invoke, initial]}}} = source,
         %{fixture: {:initial, expected}} = state
       ) do
    state = exact(state, source, :state_fixture_copy, initial, expected)

    Enum.reduce(state.decoders.protocol_copies, state, fn
      %{index: index, path: [2, 2, 1 | path] = coordinate}, state when index == source.index ->
        copy(state, source, coordinate, %{origin: {:fixture_initial, path}})

      _, state ->
        state
    end)
  end

  defp fixture_event(_source, state), do: state

  defp reload_event(
         %{event: {pid, :call, {Postgrex.Protocol, function, _}}} = source,
         state
       )
       when function in [:reload_flushed, :reload_ready, :reload_transaction, :reload_closed] do
    case active_reload(state, pid, source.index) do
      nil -> reload_origin(state, source)
      context -> put_in(state.reload_spawns[pid], %{context | source: source})
    end
  end

  defp reload_event(
         %{event: {pid, :call, {Postgrex.Protocol, :reload_spawn, _}}} = source,
         state
       ) do
    with context when is_map(context) <- state.reload_spawns[pid],
         [frame | _] <- Map.get(state.frames, pid, []) do
      protocol = %{frame.current | buffer: nil}
      version = %{frame.owner | protocol: protocol}

      context = %{
        context
        | source: source,
          version: version,
          buffer: cursor_buffer(state, source, frame)
      }

      put_in(state.reload_spawns[pid], context)
    else
      _ -> failure(state, source, :state_reload_origin)
    end
  end

  defp reload_event(
         %{event: {child, :call, {Postgrex.Protocol, :msg_send, _}}},
         state
       ) do
    case {state.reload_children[child], Map.get(state.frames, child, [])} do
      {%{}, [%{source: %{mfa: {Postgrex.Protocol, :reload_init, 5}}} = frame | rest]} ->
        put_in(state.frames[child], [%{frame | current: %{frame.current | buffer: nil}} | rest])

      _ ->
        state
    end
  end

  defp reload_event(
         %{event: {pid, :call, {:erlang, :spawn_monitor, [fun]}}} = source,
         state
       ) do
    case active_reload(state, pid, source.index) do
      %{source: %{mfa: {Postgrex.Protocol, :reload_spawn, 5}} = owner} = context ->
        references =
          for {_index, %{source: call, returned: returned}} <- state.pairs,
              call.pid == pid and call.index > owner.index and returned.index < source.index,
              call.mfa == {:erlang, :make_ref, 0},
              List.first(call.stack) == owner.mfa,
              {_, :return_from, _, ref} <- [returned.event],
              is_reference(ref),
              do: {ref, returned.index}

        case {references, state.decoders.reload_factories[pid]} do
          {[{ref, index}], %{identity: identity, positions: positions}} ->
            inputs = [
              context.version.protocol,
              context.native_status,
              context.oids,
              ref,
              context.buffer
            ]

            environment =
              positions
              |> Enum.zip(inputs)
              |> Enum.sort_by(&elem(&1, 0))
              |> Enum.map(&elem(&1, 1))

            expected = {:compiled_factory, identity, environment}
            actual = factory_observed(state, fun, expected)
            context = Map.merge(context, %{fun: fun, exit_ref: ref, reference_origin: index})

            state
            |> helper_copy(
              source,
              [2, 2, 0],
              actual,
              expected,
              {:reload_closure, owner.index, index}
            )
            |> reload_cover(source, context.version)
            |> put_in([:reload_spawns, pid], context)

          _ ->
            failure(state, source, :state_reload_closure_origin)
        end

      _ ->
        state
    end
  end

  defp reload_event(
         %{event: {pid, :call, {:erlang, :spawn_opt, arguments}}} = source,
         state
       ) do
    case active_reload(state, pid, source.index) do
      %{fun: fun, version: version, source: owner} ->
        expected = [:erlang, :apply, [fun, []], [:monitor]]

        state
        |> helper_copy(source, [2, 2], arguments, expected, {:reload_native_spawn, owner.index})
        |> reload_cover(source, version)

      _ ->
        state
    end
  end

  defp reload_event(%{event: {pid, :spawn, child, entry}} = source, state) do
    case active_reload(state, pid, source.index) do
      %{fun: fun} = context ->
        state =
          exact(state, source, :state_reload_spawn_entry, entry, {:erlang, :apply, [fun, []]})

        child_context = Map.merge(context, %{parent: pid, child: child})

        state
        |> reload_cover(source, context.version)
        |> put_in([:reload_children, child], child_context)
        |> put_in([:lookups, child], context.version)

      _ ->
        state
    end
  end

  defp reload_event(%{event: {child, :spawned, parent, entry}} = source, state) do
    case state.reload_children[child] do
      %{parent: ^parent, fun: fun, version: version} ->
        state
        |> exact(source, :state_reload_spawn_entry, entry, {:erlang, :apply, [fun, []]})
        |> reload_cover(source, version)

      _ ->
        state
    end
  end

  defp reload_event(
         %{event: {child, :call, {:erlang, :exit, [actual]}}} = source,
         state
       ) do
    case {state.reload_children[child], List.first(Map.get(state.frames, child, []))} do
      {%{exit_ref: ref} = context,
       %{source: %{mfa: {Postgrex.Protocol, :reload_init, 5}}} = frame} ->
        protocol = %{frame.current | buffer: nil}
        buffer = cursor_buffer(state, source, frame)
        expected = {ref, protocol, buffer}
        version = %{frame.owner | protocol: protocol, origin: {:reload_exit, source.index}}
        context = Map.merge(context, %{terminal: expected, terminal_version: version})

        state
        |> helper_copy(
          source,
          [2, 2, 0],
          actual,
          expected,
          {:reload_terminal, frame.source.index}
        )
        |> reload_cover(source, version)
        |> put_in([:reload_children, child], context)

      _ ->
        state
    end
  end

  defp reload_event(
         %{event: {child, :exception_from, {module, function, _}, actual}} = source,
         state
       )
       when (module == :erlang and function == :exit) or
              (module == Postgrex.Protocol and function == :reload_init) do
    case state.reload_children[child] do
      %{terminal: expected, terminal_version: version} ->
        state
        |> helper_copy(source, [3], actual, {:exit, expected}, {:reload_terminal, version.origin})
        |> reload_cover(source, version)

      _ ->
        state
    end
  end

  defp reload_event(%{event: {child, :exit, actual}} = source, state) do
    case state.reload_children[child] do
      %{terminal: expected, terminal_version: version} ->
        state
        |> helper_copy(source, [2], actual, expected, {:reload_terminal, version.origin})
        |> reload_cover(source, version)

      _ ->
        state
    end
  end

  defp reload_event(
         %{event: {parent, :receive, {:DOWN, monitor, :process, child, actual}}} = source,
         state
       ) do
    case state.reload_children[child] do
      %{parent: ^parent, terminal: expected, terminal_version: version} = context ->
        spawned =
          Enum.any?(state.pairs, fn {_index, pair} ->
            pair.source.pid == parent and pair.source.index > context.source.index and
              pair.returned.index < source.index and
              pair.source.mfa == {:erlang, :spawn_monitor, 1} and
              elem(pair.returned.event, 3) === {child, monitor}
          end)

        state = exact(state, source, :state_reload_monitor_origin, spawned, true)

        state =
          helper_copy(state, source, [2, 4], actual, expected, {:reload_terminal, version.origin})

        state = reload_cover(state, source, version)

        case Map.get(state.frames, parent, []) do
          [%{source: %{mfa: {Postgrex.Protocol, :reload_spawn, 5}}} = frame | rest] ->
            next = %{frame | current: version.protocol, owner: version}
            put_in(state.frames[parent], [next | rest])

          _ ->
            failure(state, source, :state_reload_join_origin)
        end

      _ ->
        state
    end
  end

  defp reload_event(_source, state), do: state

  defp reload_origin(state, %{pid: pid} = source) do
    case List.first(Map.get(state.frames, pid, [])) do
      %{source: owner} = frame ->
        with %{value: query} <- state.term_values[{owner.index, [2, 2, 2]}],
             %{value: status} <- state.term_values[{owner.index, [2, 2, 1]}] do
          context = %{
            source: source,
            version: %{frame.owner | protocol: frame.current},
            query: query,
            status: status,
            oids: missing_type_origins(state, pid, owner.index, source.index),
            buffer: cursor_buffer(state, source, frame)
          }

          callback = status_callback(state, pid).source
          native_notify = state.factories[{callback.index, :notify}].native
          context = Map.put(context, :native_status, Map.put(status, :notify, native_notify))

          put_in(state.reload_spawns[pid], context)
        else
          _ -> failure(state, source, :state_reload_origin)
        end

      _ ->
        failure(state, source, :state_reload_origin)
    end
  end

  defp missing_type_origins(state, pid, first, last) do
    for {_index, %{source: call, returned: returned} = pair} <- state.pairs,
        call.pid == pid and call.index > first and returned.index < last,
        call.mfa == {Postgrex.Types, :fetch, 2},
        {:ok, {:error, nil, _}, _origins} <- [native_type_outcome(state, pair)],
        into: MapSet.new(),
        do: native_type_key(state, call, returned)
  end

  defp native_type_outcome(state, %{source: call, returned: returned} = pair) do
    with {:ok, types} <- native_type_state(state, call) do
      oid = native_type_key(state, call, returned)
      ConnectionTypes.fetch(state.pairs, pair, oid, types)
    end
  end

  defp native_type_key(state, call, returned) do
    keys =
      for {_index, pair} <- state.pairs,
          pair.source.pid == call.pid and pair.source.index > call.index and
            pair.returned.index < returned.index,
          {_, :call, {:ets, :lookup_element, [_table, oid, 3]}} <- [pair.source.event],
          do: oid

    case keys do
      [oid] -> oid
      _ -> :missing_native_type_key
    end
  end

  defp reload_cover(state, source, version) do
    Enum.reduce(state.decoders.protocol_copies, state, fn
      %{index: index, path: path}, state when index == source.index ->
        copy(state, source, path, version)

      _, state ->
        state
    end)
  end

  defp active_reload(state, pid, index) do
    with %{source: owner} = context <- state.reload_spawns[pid],
         %{returned: returned} <- state.pairs[owner.index],
         true <- owner.index < index and index < returned.index do
      context
    else
      _ -> nil
    end
  end

  defp holder_event(
         %{event: {pid, :return_from, {:ets, :lookup, 2}, [row]}} = source,
         state
       )
       when is_tuple(row) and tuple_size(row) == 8 do
    with {:conn, _owner, Postgrex.Protocol, %Postgrex.Protocol{} = protocol, _, _, _, _} <- row,
         %{source: %{event: {^pid, :call, {:ets, :lookup, [holder, :conn]}}}} <-
           pair_returned(state, source),
         {:ok, version} <- Map.fetch(state.holders, holder) do
      state = exact(state, source, :state_holder_lookup, protocol, version.protocol)
      lookup = %{version | origin: {source.index, [3, 0, 3]}}

      state
      |> put_in([:lookups, pid], lookup)
      |> copy(source, [3, 0, 3], version)
    else
      _ -> state
    end
  end

  defp holder_event(
         %{event: {pid, :return_from, {DBConnection.Holder, :checkout, _}, result}} = source,
         state
       ) do
    case {result, Map.get(state.lookups, pid), pair_returned(state, source)} do
      {{:ok, {:pool_ref, _, _, _, holder, _}, Postgrex.Protocol, _, protocol},
       %{holder: holder, origin: {lookup_index, _}} = version, %{source: call}}
      when lookup_index > call.index ->
        state
        |> exact(source, :state_checkout_copy, protocol, version.protocol)
        |> copy(source, [3, 4], version)

      _ ->
        state
    end
  end

  defp holder_event(
         %{event: {pid, :call, {:ets, :update_element, [holder, :conn, updates]}}} = source,
         state
       ) do
    if Map.has_key?(state.holders, holder) do
      state_updates(state, source, pid, holder, updates)
    else
      state
    end
  end

  defp holder_event(_source, state), do: state

  defp state_updates(state, source, pid, holder, updates) do
    listed? = is_list(updates)
    updates = if listed?, do: updates, else: [updates]

    Enum.reduce(Enum.with_index(updates), state, fn
      {{4, %Postgrex.Protocol{} = protocol}, ordinal}, state ->
        path =
          if listed?,
            do: [2, 2, 2, ordinal, 1],
            else: [2, 2, 2, 1]

        store(state, source, pid, holder, protocol, path)

      _, state ->
        state
    end)
  end

  defp store(state, source, pid, holder, protocol, path) do
    case {Map.get(state.completed, pid), Map.get(state.pairs, source.index)} do
      {%{holder: ^holder} = version,
       %{returned: %{index: index, event: {_, :return_from, _, true}}}} ->
        state
        |> exact(source, :state_holder_update, protocol, version.protocol)
        |> copy(source, path, version)
        |> put_in([:pending, index], version)

      _ ->
        failure(state, source, :state_holder_update_origin)
    end
  end

  defp commit(source, state) do
    case Map.pop(state.pending, source.index) do
      {nil, _} ->
        state

      {version, pending} ->
        %{state | pending: pending, holders: Map.put(state.holders, version.holder, version)}
    end
  end

  defp callback_event(
         %{event: {pid, :call, {Postgrex.Protocol, function, arguments}}} = source,
         state
       )
       when function in @owners do
    argument = protocol_argument(function, length(arguments))

    protocol = Enum.at(arguments, argument)
    frames = Map.get(state.frames, pid, [])

    case callback_owner(state, source, function, protocol, frames) do
      {:ok, expected} ->
        state = status_input(state, source, function, arguments)
        state = buffer_input(state, source, function, arguments, expected)
        state = helper_input(state, source, function, arguments, expected)

        {state, protocol_input} =
          input_protocol(state, source, expected.protocol, function, arguments)

        expected = %{expected | protocol: protocol_input}

        state = exact(state, source, :state_input_copy, protocol, expected.protocol)

        frame = %{
          source: source,
          input: protocol,
          owner: expected,
          current: protocol,
          parsed?: false
        }

        state
        |> copy(source, [2, 2, argument], expected)
        |> put_in([:frames, pid], [frame | frames])

      :error ->
        failure(state, source, :state_input_origin)
    end
  end

  defp callback_event(
         %{event: {pid, tag, {Postgrex.Protocol, function, _}, result}} = source,
         state
       )
       when function in @owners and tag in [:return_from, :exception_from] do
    case Map.get(state.frames, pid, []) do
      [%{source: %{mfa: mfa}} = frame | rest] when mfa == source.mfa ->
        state = put_in(state.frames[pid], rest)
        returned(state, source, frame, result, rest)

      _ ->
        failure(state, source, :state_return_origin)
    end
  end

  defp callback_event(_source, state), do: state

  defp callback_owner(state, source, :ping, protocol, []) do
    case state.owner_received[source.pid] do
      %{message: {:ping, _holder, _state}, version: version} -> {:ok, version}
      _ -> input_version(protocol, [], Map.get(state.lookups, source.pid), state.ports)
    end
  end

  defp callback_owner(state, source, :disconnect, protocol, []) do
    case {state.starting[source.pid], state.owner_machines[source.pid]} do
      {%{version: version}, _} -> {:ok, version}
      {_, %{version: version}} -> {:ok, version}
      _ -> input_version(protocol, [], Map.get(state.lookups, source.pid), state.ports)
    end
  end

  defp callback_owner(state, source, _function, _protocol, [])
       when is_map_key(state.starting, source.pid),
       do: {:ok, state.starting[source.pid].version}

  defp callback_owner(state, source, _function, protocol, frames),
    do: input_version(protocol, frames, Map.get(state.lookups, source.pid), state.ports)

  defp protocol_argument(:cancel_request, 3), do: 2

  defp protocol_argument(function, arity) when function in @last_state and function != :ping,
    do: arity - 1

  defp protocol_argument(_function, _arity), do: 0

  defp input_version(_protocol, [frame | _], _lookup, _ports),
    do: {:ok, %{frame.owner | protocol: frame.current}}

  defp input_version(_protocol, [], lookup, _ports) when not is_nil(lookup), do: {:ok, lookup}

  defp input_version(%Postgrex.Protocol{sock: sock}, [], nil, ports), do: Map.fetch(ports, sock)
  defp input_version(_protocol, _frames, _lookup, _ports), do: :error

  defp buffer_input(state, source, :msg_send, [_protocol, _messages, buffer], version) do
    cursor? =
      Map.has_key?(state.starting, source.pid) or
        Enum.any?(source.stack, fn
          {Postgrex.Protocol, function, _} ->
            function in [
              :error_flushed,
              :rollback_flushed,
              :reload_flushed,
              :reload_ready,
              :reload_transaction,
              :reload_init
            ]

          _ ->
            false
        end)

    {state, expected, origin} = send_buffer_origin(state, source, version, cursor?)
    buffer_copy(state, source, [2, 2, 2], buffer, expected, origin, version.protocol.sock)
  end

  defp buffer_input(state, source, function, arguments, version) do
    case Map.fetch(@cursor_buffers, function) do
      {:ok, position} ->
        position = if position < 0, do: length(arguments) + position, else: position
        {expected, origin} = helper_buffer_origin(state, source, version, nil)
        {state, expected, origin} = continuation_buffer(state, source, version, expected, origin)

        state =
          buffer_copy(
            state,
            source,
            [2, 2, position],
            Enum.at(arguments, position),
            expected,
            origin,
            version.protocol.sock
          )

        ping_buffer_input(state, source, function, arguments, version)

      :error ->
        state
    end
  end

  defp ping_buffer_input(state, source, :ping_recv, arguments, version) do
    frame =
      Enum.find(Map.get(state.frames, source.pid, []), fn frame ->
        elem(frame.source.mfa, 1) == :ping
      end)

    case frame do
      nil ->
        failure(state, source, :state_ping_buffer_origin)

      frame ->
        expected = if frame.input.buffer == :active_once, do: :active_once, else: nil
        origin = {:state_buffer, frame.owner.origin}

        buffer_copy(
          state,
          source,
          [2, 2, 2],
          Enum.at(arguments, 2),
          expected,
          origin,
          version.protocol.sock
        )
    end
  end

  defp ping_buffer_input(state, _source, _function, _arguments, _version), do: state

  defp buffer_copy(state, source, path, buffer, expected, origin, sock) do
    state = exact(state, source, :state_buffer_copy, buffer, expected)
    state = copy_error_path(state, source, path, :state_buffer_copy)

    copy = %{
      index: source.index,
      path: path,
      origin: origin,
      sock: sock
    }

    value = %{value: expected, origin: origin}

    state
    |> Map.update!(:buffers, &[copy | &1])
    |> put_in([:buffer_values, {source.index, path}], value)
  end

  defp helper_buffer_origin(state, source, version, frame) do
    frame = frame || List.first(Map.get(state.frames, source.pid, []))
    {boundary, fallback, origin} = lexical_buffer(state, frame, version)

    case cursor_version(state, source, version.protocol) do
      %{index: index, port: port} = cursor when index > boundary ->
        case cursor do
          %{returned_buffer: buffer} -> {buffer, {:decoder_return_buffer, port, index}}
          %{cursor: bytes} -> {bytes.buffer, {:decoder_cursor, port, index}}
        end

      _ ->
        {fallback, origin}
    end
  end

  defp lexical_buffer(_state, nil, version),
    do: {-1, version.protocol.buffer, {:state_buffer, version.origin}}

  defp lexical_buffer(state, frame, version) do
    {_, function, _} = frame.source.mfa
    {_, :call, {_, _, arguments}} = frame.source.event
    position = Map.get(@cursor_buffers, function, -1)
    position = if position < 0, do: length(arguments) + position, else: position

    case Map.fetch(state.buffer_values, {frame.source.index, [2, 2, position]}) do
      {:ok, %{value: value, origin: origin}} -> {frame.source.index, value, origin}
      :error -> {frame.source.index, version.protocol.buffer, {:state_buffer, version.origin}}
    end
  end

  defp continuation_buffer(state, source, version, expected, origin) do
    case List.first(Map.get(state.frames, source.pid, [])) do
      %{source: %{mfa: mfa} = parent}
      when mfa == source.mfa and
             mfa in [{Postgrex.Protocol, :msg_recv, 4}, {Postgrex.Protocol, :rows_recv, 5}] ->
        continued_buffer(state, source, parent, version, expected, origin)

      _ ->
        {state, expected, origin}
    end
  end

  defp continued_buffer(state, source, parent, version, expected, origin) do
    position = Map.fetch!(@cursor_buffers, elem(source.mfa, 1))
    previous = Map.fetch!(state.buffer_values, {parent.index, [2, 2, position]})

    reads =
      Enum.filter(state.native.reads, fn read ->
        read.returned.pid == source.pid and read.returned.index > parent.index and
          read.returned.index < source.index and
          read.port == NativeTransport.physical_port(state.native, version.protocol.sock)
      end)

    case reads do
      [%{bytes: bytes, returned: returned}] when is_binary(bytes) ->
        # reverse/2 accepts an arbitrary tail: keep Postgrex's binary-tail iodata.
        constructed = :lists.reverse([previous.value], bytes)

        state =
          exact(
            state,
            source,
            :state_buffer_continuation,
            IO.iodata_to_binary(constructed),
            expected
          )

        {state, constructed, {:continuation_buffer, parent.index, returned.index}}

      _ ->
        {failure(state, source, :state_buffer_continuation_origin), expected, origin}
    end
  end

  defp buffer_return(state, source, frame, result)
       when elem(source.mfa, 1) in [
              :msg_recv,
              :rows_recv,
              :redescribe,
              :describe,
              :recv_describe,
              :reload_describe_result
            ] and
              is_tuple(result) do
    if elem(result, 0) in [:ok, :reload, :error] do
      position = tuple_size(result) - 1
      {expected, origin} = helper_buffer_origin(state, source, frame.owner, frame)

      buffer_copy(
        state,
        source,
        [3, position],
        elem(result, position),
        expected,
        origin,
        frame.input.sock
      )
    else
      state
    end
  end

  defp buffer_return(state, _source, _frame, _result), do: state

  defp helper_input(state, source, :rows_recv, [_protocol, types, rows | rest], version) do
    state = helper_types(state, source, version, types)
    state = helper_rows(state, source, [2, 2, 2], rows, version.protocol)

    case rest do
      [_buffer, more] -> helper_demand(state, source, more, version, :rows)
      [_buffer] -> state
    end
  end

  defp helper_input(state, source, :msg_recv, [_protocol, timeout, _buffer | tail], version) do
    state = helper_timeout(state, source, timeout)

    case tail do
      [more] -> helper_demand(state, source, more, version, :message)
      [] -> state
    end
  end

  defp helper_input(
         state,
         source,
         :reload_describe_result,
         [_protocol, param_oids, result_oids, _buffer],
         _version
       ) do
    with {:ok, input} <- current_query_description(state, source),
         %{source: owner} <- describe_frame(state, source.pid) do
      missing = missing_type_origins(state, source.pid, owner.index, source.index)
      origin = {:parameter_type_reload, owner.index, input.origin}

      state
      |> helper_copy(source, [2, 2, 1], param_oids, missing, origin)
      |> helper_copy(source, [2, 2, 2], result_oids, input.result_oids, origin)
    else
      _ -> failure(state, source, :state_helper_query_origin)
    end
  end

  defp helper_input(state, source, function, arguments, _version)
       when function in [
              :reload_flushed,
              :reload_ready,
              :reload_transaction,
              :reload_closed,
              :reload_spawn,
              :reload_init
            ] do
    context =
      if function == :reload_init,
        do: state.reload_children[source.pid],
        else: state.reload_spawns[source.pid]

    case context do
      %{status: status, oids: oids} ->
        actual_status = Enum.at(arguments, 1)

        actual_status =
          if is_map(actual_status) and Map.has_key?(actual_status, :notify),
            do: Map.update!(actual_status, :notify, &factory_observed(state, &1, status.notify)),
            else: actual_status

        {second, third} =
          if function == :reload_init,
            do: {oids, context.exit_ref},
            else: {context.query, oids}

        [actual_status, Enum.at(arguments, 2), Enum.at(arguments, 3)]
        |> Enum.zip([status, second, third])
        |> Enum.with_index(1)
        |> Enum.reduce(state, fn {{actual, expected}, position}, state ->
          helper_copy(
            state,
            source,
            [2, 2, position],
            actual,
            expected,
            {:reload_input, context.source.index, position}
          )
        end)

      _ ->
        failure(state, source, :state_reload_origin)
    end
  end

  defp helper_input(state, source, :done, [_protocol, query, rows, tag], version) do
    state = helper_rows(state, source, [2, 2, 2], rows, version.protocol)

    case {execution_origin(state, source, version.protocol),
          command_origin(state, source, version.protocol)} do
      {%{descriptor: descriptor}, %{tag: expected, index: index}} ->
        state
        |> helper_copy(
          source,
          [2, 2, 1],
          query,
          descriptor.query,
          {:query_descriptor, descriptor.index, descriptor.path}
        )
        |> helper_copy(source, [2, 2, 3], tag, expected, {:command_tag, index})

      _ ->
        failure(state, source, :state_completion_origin)
    end
  end

  defp helper_input(state, source, function, arguments, _version)
       when function in [:describe, :describe_params, :describe_result, :redescribe] do
    case Map.fetch(state.decoders.query_inputs, source.index) do
      {:ok, input} ->
        fields =
          case function do
            :describe ->
              [
                query: input.query,
                param_oids: input.param_oids,
                result_oids: input.result_oids,
                result_mods: input.result_mods,
                columns: input.columns
              ]

            :describe_params ->
              [query: input.query, param_oids: input.param_oids]

            _ ->
              [
                query: input.query,
                result_oids: input.result_oids,
                result_mods: input.result_mods,
                columns: input.columns
              ]
          end

        fields
        |> Enum.with_index(1)
        |> Enum.reduce(state, fn {{field, expected}, position}, state ->
          helper_copy(
            state,
            source,
            [2, 2, position],
            Enum.at(arguments, position),
            expected,
            {:query_constructor_input, input.root, input.origin, field}
          )
        end)

      :error ->
        failure(state, source, :state_helper_query_origin)
    end
  end

  defp helper_input(
         state,
         source,
         :recv_describe,
         [_protocol, _status, actual, _buffer],
         _version
       ) do
    case current_query_description(state, source) do
      {:ok, input} ->
        helper_copy(
          state,
          source,
          [2, 2, 2],
          actual,
          input.parameter_accumulator,
          {:parameter_description, input.origin}
        )

      :error ->
        failure(state, source, :state_helper_query_origin)
    end
  end

  defp helper_input(state, source, :done, [_protocol, tags], version),
    do: transaction_tag_copy(state, source, [2, 2, 1], tags, version.protocol, false)

  defp helper_input(
         state,
         source,
         :recv_transaction,
         [_protocol, _status, tags, _buffer],
         version
       ),
       do: transaction_tag_copy(state, source, [2, 2, 2], tags, version.protocol, true)

  defp helper_input(state, source, function, [_protocol, _status, actual_query | rest], _version)
       when function in [
              :parse_describe,
              :parse_describe_close,
              :close_parse_describe,
              :parse_describe_flush,
              :close_parse_describe_flush
            ] do
    with %{source: callback} = frame <- status_callback(state, source.pid),
         {:ok, options} <- status_options(frame),
         {_, :call, {_, _, [query | _]}} <- callback.event,
         %Postgrex.Query{} <- query do
      state =
        helper_copy(
          state,
          source,
          [2, 2, 2],
          actual_query,
          query,
          {:callback_query, callback.index}
        )

      comment =
        if {Postgrex.Protocol, :reload_spawn, 5} in source.stack, do: nil, else: options[:comment]

      prepare_comment(state, source, rest, comment, callback.index)
    else
      _ -> failure(state, source, :state_helper_query_origin)
    end
  end

  defp helper_input(
         state,
         source,
         :recv_strict_ready,
         [_protocol, _status, actual, _buffer],
         version
       ) do
    expected =
      case version.protocol.postgres do
        {postgres, _ref} -> postgres
        postgres -> postgres
      end

    helper_copy(state, source, [2, 2, 2], actual, expected, {:ready_status, version.origin})
  end

  defp helper_input(state, source, :done, [_protocol, query, rows, command, count], version) do
    state = helper_rows(state, source, [2, 2, 2], rows, version.protocol)

    case {execution_origin(state, source, version.protocol),
          command_origin(state, source, version.protocol)} do
      {%{descriptor: descriptor}, %{tag: tag, index: index}} ->
        %{value: expected_rows} = Map.fetch!(state.term_values, {source.index, [2, 2, 2]})
        {expected_command, expected_count} = completion_command(tag, expected_rows)

        state
        |> helper_copy(
          source,
          [2, 2, 1],
          query,
          descriptor.query,
          {:query_descriptor, descriptor.index, descriptor.path}
        )
        |> helper_copy(source, [2, 2, 3], command, expected_command, {:command, index})
        |> helper_copy(source, [2, 2, 4], count, expected_count, {:command_count, index})

      _ ->
        failure(state, source, :state_completion_origin)
    end
  end

  defp helper_input(state, source, :handle_msg, [_protocol, _status, actual], version) do
    case native_message_instance(state, source, version.protocol) do
      %{expected: {:ok, expected, _}, returned: returned} ->
        message_copy(state, source, actual, expected, {:decoder_message, returned.index})

      _ ->
        failure(state, source, :state_message_origin)
    end
  end

  defp helper_input(state, source, function, [_protocol, _status, actual, _buffer], version)
       when function in [:error_ready, :error_flushed, :rollback_flushed] do
    case native_message_instance(state, source, version.protocol) do
      %{expected: {:ok, msg_error(fields: fields), _}, returned: %{index: index}} ->
        expected = prepare_error(state, source, version, fields)
        origin = {:server_error, index}
        error_copy(state, source, [2, 2, 2], actual, expected, origin)

      _ ->
        failure(state, source, :state_error_origin)
    end
  end

  defp helper_input(state, source, :msg_send, [_protocol, messages, _buffer], version) do
    frame = List.first(Map.get(state.frames, source.pid, []))
    helper_messages(state, source, frame, version, messages)
  end

  defp helper_input(state, _source, _function, _arguments, _version), do: state

  defp transaction_tag_copy(state, source, path, actual, protocol, reverse?) do
    case transaction_tags(state, source, protocol) do
      {:ok, tags, origins} ->
        expected = if reverse?, do: Enum.reverse(tags), else: tags
        helper_copy(state, source, path, actual, expected, {:transaction_tags, origins})

      :error ->
        failure(state, source, :state_transaction_origin)
    end
  end

  defp prepare_comment(state, _source, [], _comment, _origin), do: state

  defp prepare_comment(state, source, [actual], comment, origin),
    do: helper_copy(state, source, [2, 2, 3], actual, comment, {:callback_comment, origin})

  defp helper_messages(
         state,
         source,
         %{source: %{mfa: {Postgrex.Protocol, function, 4}}} = frame,
         version,
         messages
       )
       when function in [:handle_execute, :handle_prepare_execute] do
    execute_messages(state, source, frame, version, messages)
  end

  defp helper_messages(
         state,
         source,
         %{source: %{mfa: {Postgrex.Protocol, :ping, arity}} = callback},
         _version,
         messages
       )
       when arity in [1, 2] do
    helper_copy(state, source, [2, 2, 1], messages, msg_sync(), {:ping_sync, callback.index})
  end

  defp helper_messages(
         state,
         source,
         %{source: %{mfa: {Postgrex.Protocol, function, 2}} = callback} = frame,
         _version,
         messages
       )
       when function in [:handle_begin, :handle_commit, :handle_rollback] do
    transaction_messages(state, source, frame, callback, messages)
  end

  defp helper_messages(
         state,
         source,
         %{source: %{mfa: {Postgrex.Protocol, function, _}}} = frame,
         _version,
         messages
       )
       when function in [
              :parse_describe,
              :parse_describe_close,
              :close_parse_describe,
              :parse_describe_flush,
              :close_parse_describe_flush
            ] do
    prepare_messages(state, source, frame, messages)
  end

  defp helper_messages(
         state,
         source,
         %{source: %{mfa: {Postgrex.Protocol, :error_flushed, 4}} = owner},
         _version,
         messages
       ) do
    helper_copy(state, source, [2, 2, 1], messages, [msg_sync()], {:error_sync, owner.index})
  end

  defp helper_messages(
         state,
         source,
         %{source: %{mfa: {Postgrex.Protocol, :rollback_flushed, 4}} = owner},
         _version,
         messages
       ) do
    statement = "ROLLBACK TO SAVEPOINT postgrex_query;RELEASE SAVEPOINT postgrex_query"
    expected = [msg_sync(), msg_query(statement: statement)]
    helper_copy(state, source, [2, 2, 1], messages, expected, {:error_rollback, owner.index})
  end

  defp helper_messages(
         state,
         source,
         %{source: %{mfa: {Postgrex.Protocol, function, 5}} = owner},
         _version,
         messages
       )
       when function in [:reload_flushed, :reload_ready, :reload_transaction] do
    context = Map.fetch!(state.reload_spawns, source.pid)
    close = msg_close(type: :statement, name: context.query.name)

    tail =
      if function != :reload_flushed or context.status.mode == :transaction,
        do: msg_sync(),
        else:
          msg_query(
            statement: "ROLLBACK TO SAVEPOINT postgrex_query;RELEASE SAVEPOINT postgrex_query"
          )

    helper_copy(
      state,
      source,
      [2, 2, 1],
      messages,
      [close, tail],
      {:reload_close, owner.index}
    )
  end

  defp helper_messages(
         state,
         source,
         %{source: %{mfa: {Postgrex.Protocol, :reload_init, 5}}},
         _version,
         messages
       ),
       do: reload_query_messages(state, source, messages)

  defp helper_messages(state, source, nil, version, messages)
       when is_map_key(state.starting, source.pid),
       do: startup_messages(state, source, version, messages)

  defp helper_messages(state, source, _frame, _version, messages),
    do: callback_messages(state, source, messages)

  defp startup_messages(state, source, version, actual) do
    context = state.starting[source.pid]
    options = startup_options(context.options)

    {expected, phase} =
      case context.phase do
        :ssl_negotiation ->
          {{:msg_ssl_request}, :ssl_upgrade}

        :startup ->
          parameters =
            [
              user: Keyword.fetch!(options, :username),
              database: Keyword.fetch!(options, :database)
            ] ++ options[:parameters]

          {{:msg_startup, parameters}, :authentication}

        :authentication ->
          {startup_password(state, source, context), :authentication}

        :bootstrap ->
          {startup_query(state, source, context, version), :initializing}
      end

    state
    |> helper_copy(
      source,
      [2, 2, 1],
      actual,
      expected,
      {:constructor_message, context.source.index}
    )
    |> put_in([:starting, source.pid, :phase], phase)
  end

  defp startup_password(state, source, context) do
    options = startup_options(context.options)

    case native_message(state, source, context.version.protocol) do
      {:msg_auth, :cleartext, _} ->
        {:msg_password, [Keyword.fetch!(options, :password), 0]}

      {:msg_auth, :md5, salt} ->
        digest =
          :erlang.md5([Keyword.fetch!(options, :password), Keyword.fetch!(options, :username)])
          |> Base.encode16(case: :lower)

        digest = :erlang.md5([digest, salt]) |> Base.encode16(case: :lower)
        {:msg_password, ["md5", digest, 0]}

      {:msg_auth, type, _} when type in [:sasl, :sasl_cont] ->
        {:msg_password, context.password_message}

      _ ->
        :no_constructor_authentication_origin
    end
  end

  defp startup_query(state, source, context, version) do
    [size] =
      for pair <- native_type_calls(state, context.source, source, {:ets, :info, 2}),
          {_, :call, {_, _, [table, :size]}} <- [pair.source.event],
          {_, actual_table} = version.protocol.types,
          table == actual_table,
          do: pair

    {_, :return_from, _, 0} = size.returned.event
    server_version = Postgrex.Utils.parse_version(version.protocol.parameters["server_version"])
    type_module = Keyword.fetch!(context.options, :types)
    disable_composite_types = version.protocol.disable_composite_types

    # The short-lived owner retires the independently created table without
    # inspecting Postgrex's opaque state or borrowing the observed table.
    query =
      Task.async(fn ->
        types = Postgrex.Types.new(type_module)
        input = %{types: types, disable_composite_types: disable_composite_types}
        Postgrex.Types.bootstrap_query(server_version, input)
      end)
      |> Task.await()

    {:msg_query, query}
  end

  defp callback_messages(state, source, actual) do
    with %{source: callback} = frame <- status_callback(state, source.pid),
         {:ok, options} <- status_options(frame),
         {:ok, expected, origins} <- callback_message_origin(state, source, frame, options) do
      helper_copy(
        state,
        source,
        [2, 2, 1],
        actual,
        expected,
        {:callback_messages, callback.index, origins}
      )
    else
      _ -> failure(state, source, :state_helper_send_origin)
    end
  end

  defp reload_query_messages(state, source, actual) do
    case Map.fetch(state.reload_children, source.pid) do
      {:ok, context} -> reload_query_messages(state, source, actual, context)
      :error -> failure(state, source, :state_reload_origin)
    end
  end

  defp reload_query_messages(state, source, actual, context) do
    parameters =
      for {_index, %{source: call, returned: returned}} <- state.pairs,
          call.pid == source.pid and call.index > context.source.index and
            returned.index < source.index,
          call.mfa == {Postgrex.Parameters, :fetch, 1},
          {_, :call, {_, _, [reference]}} <- [call.event],
          reference === context.version.protocol.parameters,
          {_, :return_from, _, {:ok, values}} <- [returned.event],
          do: {returned.index, values}

    case Enum.max_by(parameters, &elem(&1, 0), fn -> nil end) do
      {index, values} ->
        version = Postgrex.Utils.parse_version(values["server_version"])
        oids = reload_missing_oids(state, source, context)

        # The native reload has populated its type table by comparison time.
        # These OIDs are independently proven absent at this occurrence. Build
        # the reference query with the library over a fresh genuine type table,
        # so later native updates cannot change the expected earlier statement.
        {module, _table} = context.version.protocol.types
        table = :ets.new(Postgrex.Types, [:protected, read_concurrency: true])

        statement =
          try do
            options = %{
              types: {module, table},
              disable_composite_types: context.version.protocol.disable_composite_types
            }

            Postgrex.Types.reload_query(version, Enum.to_list(oids), options)
          after
            :ets.delete(table)
          end

        helper_copy(
          state,
          source,
          [2, 2, 1],
          actual,
          msg_query(statement: statement),
          {:reload_query, context.source.index, index}
        )

      nil ->
        failure(state, source, :state_reload_parameters_origin)
    end
  end

  defp reload_missing_oids(state, source, context) do
    complete? =
      Enum.any?(state.decoders.instances, fn instance ->
        instance.returned.pid == source.pid and instance.returned.index < source.index and
          match?({:ok, {:msg_command_complete, _}, _}, instance.expected)
      end)

    if complete? do
      missing =
        for {_index, %{source: call, returned: returned} = pair} <- state.pairs,
            call.pid == source.pid and call.mfa == {Postgrex.Types, :fetch, 2},
            returned.index < source.index,
            {:ok, {:error, nil, _}, _origins} <- [native_type_outcome(state, pair)],
            into: MapSet.new(),
            do: native_type_key(state, call, returned)

      loaded = MapSet.new(reload_catalog_rows(state, source), fn {_row, info} -> info.oid end)
      MapSet.difference(missing, loaded)
    else
      context.oids
    end
  end

  defp callback_message_origin(
         _state,
         _source,
         %{source: %{event: {_, :call, {_, :handle_prepare, [query, _options, protocol]}}}},
         options
       ) do
    query =
      if is_reference(query.ref),
        do: %Postgrex.Query{name: query.name, statement: query.statement},
        else: query

    query = if is_nil(protocol.queries), do: %{query | name: ""}, else: query
    comment = options[:comment]

    statement =
      if is_binary(comment), do: [query.statement, "/*", comment, "*/"], else: query.statement

    parse = msg_parse(name: query.name, statement: statement, type_oids: query.param_oids || [])
    describe = msg_describe(type: :statement, name: query.name)
    head = if query.name == "", do: [], else: [msg_close(type: :statement, name: query.name)]
    tail = if options[:postgrex_prepare], do: [msg_sync()], else: [msg_flush()]

    tail =
      if options[:postgrex_prepare] and query.name == "",
        do: [msg_close(type: :statement, name: "") | tail],
        else: tail

    {:ok, head ++ [parse, describe] ++ tail, []}
  end

  defp callback_message_origin(
         _state,
         _source,
         %{source: %{event: {_, :call, {_, :handle_close, [query, _options, _protocol]}}}},
         _callback_options
       ),
       do: {:ok, [msg_close(type: :statement, name: query.name), msg_sync()], []}

  defp callback_message_origin(
         _state,
         _source,
         %{
           source: %{event: {_, :call, {_, :handle_fetch, [_query, cursor, _options, _protocol]}}}
         },
         options
       ) do
    execute =
      msg_execute(name_port: cursor.portal, max_rows: Keyword.get(options, :max_rows, 500))

    {:ok, [execute, msg_sync()], []}
  end

  defp callback_message_origin(
         _state,
         _source,
         %{
           source: %{
             event: {_, :call, {_, :handle_deallocate, [_query, cursor, _options, _protocol]}}
           }
         },
         _callback_options
       ),
       do: {:ok, [msg_close(type: :portal, name: cursor.portal), msg_sync()], []}

  defp callback_message_origin(
         state,
         source,
         %{
           source:
             %{event: {_, :call, {_, :handle_declare, [query, params, _options, _protocol]}}} =
               callback
         },
         _callback_options
       ) do
    portals =
      for {_index, %{source: call, returned: returned}} <- state.pairs,
          call.pid == source.pid and call.index > callback.index and returned.index < source.index,
          call.mfa == {:erlang, :unique_integer, 1},
          {_, :call, {_, _, [[:positive]]}} <- [call.event],
          {_, :return_from, _, value} <- [returned.event],
          is_integer(value),
          do: {Integer.to_string(value, 36), returned.index}

    case portals do
      [{portal, origin}] ->
        bind =
          msg_bind(
            name_port: portal,
            name_stat: query.name,
            param_formats: query.param_formats,
            params: params,
            result_formats: query.result_formats
          )

        {:ok, [bind, msg_sync()], [origin]}

      _ ->
        :error
    end
  end

  defp callback_message_origin(_state, _source, _frame, _options), do: :error

  defp prepare_error(state, source, version, fields) do
    error = Postgrex.Error.exception(postgres: fields)

    frame =
      Enum.find(Map.get(state.frames, source.pid, []), fn frame ->
        elem(frame.source.mfa, 1) in [
          :parse_describe,
          :parse_describe_close,
          :close_parse_describe,
          :parse_describe_flush,
          :close_parse_describe_flush
        ]
      end)

    query = if frame, do: state.term_values[{frame.source.index, [2, 2, 2]}]
    annotate_prepare_error(error, query, version.protocol.types)
  end

  defp annotate_prepare_error(error, %{value: %Postgrex.Query{} = query}, types)
       when is_nil(query.ref) or query.types != types,
       do: %{error | query: query.statement}

  defp annotate_prepare_error(error, _query, _types), do: error

  defp transaction_messages(state, source, frame, callback, actual) do
    {_, :call, {_, function, [options, _protocol]}} = callback.event
    mode = Keyword.get(options, :mode, :transaction)

    statement =
      case {function, mode} do
        {:handle_begin, :transaction} ->
          "BEGIN"

        {:handle_begin, :savepoint} ->
          "SAVEPOINT postgrex_savepoint"

        {:handle_commit, :transaction} ->
          case options[:commit_comment] do
            comment when is_binary(comment) -> "/* " <> comment <> " */\nCOMMIT"
            _ -> "COMMIT"
          end

        {:handle_commit, :savepoint} ->
          "RELEASE SAVEPOINT postgrex_savepoint"

        {:handle_rollback, :transaction} ->
          "ROLLBACK"

        {:handle_rollback, :savepoint} ->
          "ROLLBACK TO SAVEPOINT postgrex_savepoint;RELEASE SAVEPOINT postgrex_savepoint"
      end

    helper_copy(
      state,
      source,
      [2, 2, 1],
      actual,
      [msg_query(statement: statement)],
      {:transaction_statement, frame.source.index}
    )
  end

  defp prepare_messages(state, source, frame, actual) do
    with %{value: query} <- state.term_values[{frame.source.index, [2, 2, 2]}],
         %{value: status} <- state.term_values[{frame.source.index, [2, 2, 1]}] do
      function = elem(frame.source.mfa, 1)
      comment = state.term_values[{frame.source.index, [2, 2, 3]}]
      statement = prepare_statement(query.statement, comment)
      tail = prepare_tail(function, status.mode, query.name)

      messages = [
        msg_parse(name: query.name, statement: statement, type_oids: query.param_oids || []),
        msg_describe(type: :statement, name: query.name)
        | tail
      ]

      messages = prepare_head(function, status.mode, query.name) ++ messages

      helper_copy(
        state,
        source,
        [2, 2, 1],
        actual,
        messages,
        {:prepare_messages, frame.source.index}
      )
    else
      _ -> failure(state, source, :state_helper_send_origin)
    end
  end

  defp prepare_statement(statement, %{value: comment}) when is_binary(comment),
    do: [statement, "/*", comment, "*/"]

  defp prepare_statement(statement, _comment), do: statement

  defp prepare_tail(function, _mode, _name)
       when function in [:parse_describe_flush, :close_parse_describe_flush],
       do: [msg_flush()]

  defp prepare_tail(_function, :savepoint, _name),
    do: [msg_query(statement: "RELEASE SAVEPOINT postgrex_query")]

  defp prepare_tail(:parse_describe_close, :transaction, name),
    do: [msg_close(type: :statement, name: name), msg_sync()]

  defp prepare_tail(_function, :transaction, _name), do: [msg_sync()]

  defp prepare_head(function, mode, name) do
    close =
      if function in [:close_parse_describe, :close_parse_describe_flush],
        do: [msg_close(type: :statement, name: name)],
        else: []

    savepoint =
      if mode == :savepoint,
        do: [msg_query(statement: "SAVEPOINT postgrex_query")],
        else: []

    savepoint ++ close
  end

  defp execute_messages(state, source, frame, version, actual) do
    execution = execution_origin(state, source, version.protocol)
    {_, :call, {_, _, [_query, params, options, _protocol]}} = frame.source.event

    case {execution, Keyword.get(options, :mode, :transaction)} do
      {%{descriptor: descriptor}, mode} when mode in [:transaction, :savepoint] ->
        query = descriptor.query

        bind =
          msg_bind(
            name_port: "",
            name_stat: query.name,
            param_formats: query.param_formats,
            params: params,
            result_formats: query.result_formats
          )

        tail =
          case {mode, query.name} do
            {:savepoint, _name} ->
              [msg_query(statement: "RELEASE SAVEPOINT postgrex_query")]

            {:transaction, ""} ->
              [msg_close(type: :statement, name: ""), msg_sync()]

            {:transaction, _name} ->
              [msg_sync()]
          end

        expected = [bind, msg_execute(name_port: "", max_rows: 0) | tail]
        origin = {:execute_messages, frame.source.index, descriptor.index, descriptor.path}
        helper_copy(state, source, [2, 2, 1], actual, expected, origin)

      _ ->
        failure(state, source, :state_helper_send_origin)
    end
  end

  defp helper_timeout(state, source, actual) when is_map_key(state.starting, source.pid),
    do:
      helper_copy(
        state,
        source,
        [2, 2, 1],
        actual,
        :infinity,
        {:constructor_timeout, state.starting[source.pid].source.index}
      )

  defp helper_timeout(state, source, actual) do
    callback =
      Enum.find(Map.get(state.frames, source.pid, []), fn frame ->
        elem(frame.source.mfa, 1) in @last_state
      end)

    case callback do
      %{source: %{mfa: {Postgrex.Protocol, function, _}}, owner: version} ->
        {expected, expression} =
          case function do
            :ping -> {version.protocol.ping_timeout, :ping_timeout}
            :handle_info -> {version.protocol.timeout, :timeout}
            _query_callback -> {:infinity, :query_receive_timeout}
          end

        origin = {:callback_timeout, version.origin, expression}
        helper_copy(state, source, [2, 2, 1], actual, expected, origin)

      nil ->
        case state.reload_children[source.pid] do
          %{source: owner} ->
            helper_copy(
              state,
              source,
              [2, 2, 1],
              actual,
              :infinity,
              {:reload_timeout, owner.index}
            )

          _ ->
            failure(state, source, :state_helper_timeout_origin)
        end
    end
  end

  defp helper_types(state, source, %{protocol: %{sock: _socket} = protocol}, actual) do
    execution = execution_origin(state, source, protocol)

    case execution do
      %{descriptor: descriptor} ->
        origin = {:query_descriptor, descriptor.index, descriptor.path, :result_types}
        helper_copy(state, source, [2, 2, 1], actual, descriptor.query.result_types, origin)

      nil ->
        failure(state, source, :state_helper_type_origin)
    end
  end

  defp helper_types(state, source, _version, _actual),
    do: failure(state, source, :state_helper_type_origin)

  defp execution_origin(state, source, %{sock: socket}) do
    port = NativeTransport.physical_port(state.native, socket)

    state.decoders.executions
    |> Enum.filter(&(&1.port == port and &1.pid == source.pid and &1.index < source.index))
    |> List.last()
  end

  defp execution_origin(_state, _source, _protocol), do: nil

  defp helper_rows(state, source, path, actual, protocol) do
    case cursor_version(state, source, protocol) do
      %{index: index, port: port, cursor: cursor} ->
        helper_copy(state, source, path, actual, cursor.rows, {:decoder_rows, port, index})

      nil ->
        failure(state, source, :state_helper_rows_origin)
    end
  end

  defp helper_demand(state, source, actual, version, kind) do
    instance = helper_decoder(state, source, version.protocol, kind)

    case helper_required(instance, kind) do
      {:ok, more} ->
        %{returned: returned, port: port} = instance

        reads =
          Enum.filter(state.native.reads, fn read ->
            read.port == port and read.returned.pid == source.pid and
              read.returned.index > returned.index and read.returned.index < source.index
          end)

        remaining = more - Enum.sum(Enum.map(reads, &byte_size(&1.bytes)))
        path = if kind == :rows, do: [2, 2, 4], else: [2, 2, 3]
        origin = {:decoder_demand, returned.index, Enum.map(reads, & &1.returned.index)}
        helper_copy(state, source, path, actual, remaining, origin)

      :error ->
        failure(state, source, :state_helper_demand_origin)
    end
  end

  defp helper_required(%{expected: {:more, _buffer, _rows, more}}, :rows), do: {:ok, more}
  defp helper_required(%{expected: {:more, more}}, :message), do: {:ok, more}
  defp helper_required(_instance, _kind), do: :error

  defp helper_decoder(state, source, %{sock: socket}, kind) do
    port = NativeTransport.physical_port(state.native, socket)

    mfa =
      if kind == :rows,
        do: {Postgrex.Types, :decode_rows, 4},
        else: {Postgrex.Protocol, :msg_decode, 1}

    state.decoders.instances
    |> Enum.filter(
      &(&1.port == port and &1.returned.pid == source.pid and
          &1.returned.index < source.index and &1.source.mfa == mfa)
    )
    |> List.last()
  end

  defp helper_decoder(_state, _source, _protocol, _kind), do: nil

  defp helper_return(state, source, _frame, {tag, actual, _protocol, _buffer})
       when elem(source.mfa, 1) == :reload_describe_result do
    case describe_frame(state, source.pid) do
      %{source: owner} ->
        expected = missing_type_origins(state, source.pid, owner.index, source.index)
        origin = {:description_type_reload, owner.index}

        state
        |> helper_copy(source, [3, 0], tag, :reload, origin)
        |> helper_copy(source, [3, 1], actual, expected, origin)

      _ ->
        failure(state, source, :state_helper_query_origin)
    end
  end

  defp helper_return(state, source, frame, {:ok, message, _buffer})
       when elem(source.mfa, 1) == :msg_recv,
       do: helper_message(state, source, frame, message)

  defp helper_return(state, source, frame, {:ok, message, rows, _buffer})
       when elem(source.mfa, 1) == :rows_recv do
    state
    |> helper_message(source, frame, message)
    |> helper_rows(source, [3, 2], rows, frame.input)
  end

  defp helper_return(state, source, frame, {%Postgrex.Result{} = actual, _protocol})
       when elem(source.mfa, 1) == :done do
    case completion_result(state, source, frame) do
      {:ok, expected, origin} -> helper_copy(state, source, [3, 0], actual, expected, origin)
      :error -> failure(state, source, :state_completion_origin)
    end
  end

  defp helper_return(state, source, frame, result)
       when elem(source.mfa, 1) in [
              :describe_params,
              :describe_result,
              :describe,
              :redescribe,
              :parse_describe,
              :parse_describe_close,
              :close_parse_describe,
              :parse_describe_flush,
              :close_parse_describe_flush,
              :reload_ready,
              :reload_transaction,
              :reload_closed,
              :reload_flushed,
              :reload_spawn,
              :handle_prepare
            ] do
    case result do
      {:ok, actual} -> query_result_copy(state, source, frame, actual)
      {:ok, actual, _protocol} -> query_result_copy(state, source, frame, actual)
      {:ok, actual, _protocol, _buffer} -> query_result_copy(state, source, frame, actual)
      _ -> state
    end
  end

  defp helper_return(
         state,
         source,
         _frame,
         {:ok, param_oids, result_oids, result_mods, columns, _protocol, _buffer}
       )
       when elem(source.mfa, 1) == :recv_describe do
    case current_query_description(state, source) do
      {:ok, input} ->
        [param_oids, result_oids, result_mods, columns]
        |> Enum.zip([input.param_oids, input.result_oids, input.result_mods, input.columns])
        |> Enum.with_index(1)
        |> Enum.reduce(state, fn {{actual, expected}, position}, state ->
          helper_copy(
            state,
            source,
            [3, position],
            actual,
            expected,
            {:query_description, input.origin}
          )
        end)

      :error ->
        failure(state, source, :state_helper_query_origin)
    end
  end

  defp helper_return(state, source, frame, {:error, actual, _protocol})
       when elem(source.mfa, 1) in [:error_ready, :error_flushed, :rollback_flushed] do
    case Map.fetch(state.term_values, {frame.source.index, [2, 2, 2]}) do
      {:ok, %{value: %Postgrex.Error{} = error, origin: origin}} ->
        expected = %{error | connection_id: frame.input.connection_id}

        helper_copy(
          state,
          source,
          [3, 1],
          actual,
          expected,
          {:error_result, origin, frame.owner.origin}
        )

      {:ok, %{value: expected, origin: origin}} ->
        helper_copy(state, source, [3, 1], actual, expected, {:error_result, origin})

      :error ->
        failure(state, source, :state_error_origin)
    end
  end

  defp helper_return(state, _source, _frame, _result), do: state

  defp query_result_copy(state, source, frame, actual) do
    expected =
      case state.decoders.query_outputs[source.index] do
        %{query: query} -> query
        nil -> query_origin(state, frame)
      end

    case expected do
      %Postgrex.Query{} ->
        helper_copy(
          state,
          source,
          [3, 1],
          actual,
          expected,
          {:query_constructor, frame.source.index}
        )

      _ ->
        failure(state, source, :state_query_origin)
    end
  end

  defp describe_frame(state, pid) do
    Enum.find(Map.get(state.frames, pid, []), fn frame ->
      frame.source.mfa == {Postgrex.Protocol, :describe, 7}
    end)
  end

  defp current_query_description(state, source) do
    Map.fetch(state.decoders.query_inputs, source.index)
  end

  defp helper_message(state, source, frame, actual) do
    case helper_decoder(state, source, frame.input, :message) do
      %{expected: {:ok, message, _}, returned: returned}
      when returned.index > frame.source.index ->
        helper_copy(state, source, [3, 1], actual, message, {:decoder_message, returned.index})

      _ ->
        failure(state, source, :state_helper_message_origin)
    end
  end

  defp helper_copy(state, source, path, actual, expected, origin) do
    state = exact(state, source, :state_helper_copy, actual, expected)
    state = copy_error_path(state, source, path, :state_helper_copy)
    copy = %{index: source.index, path: path, origin: origin}

    state
    |> Map.update!(:terms, &[copy | &1])
    |> put_in([:term_values, {source.index, path}], %{value: expected, origin: origin})
  end

  defp copy_error_path(
         %{errors: [%{index: index, rule: rule} = error | rest]} = state,
         %{index: index},
         path,
         rule
       ) do
    if Map.has_key?(error, :path),
      do: state,
      else: %{state | errors: [Map.put(error, :path, path) | rest]}
  end

  defp copy_error_path(state, _source, _path, _rule), do: state

  defp completion_result(state, _source, %{
         source: %{mfa: {Postgrex.Protocol, :done, 2}} = call,
         input: protocol
       }) do
    case Map.fetch(state.term_values, {call.index, [2, 2, 1]}) do
      {:ok, %{value: tags, origin: origin}} ->
        command =
          case Enum.map(tags, &command_tag/1) do
            [{command, _count}] -> command
            commands -> Enum.map(commands, &elem(&1, 0))
          end

        expected = %Postgrex.Result{
          command: command,
          num_rows: nil,
          rows: nil,
          columns: nil,
          connection_id: protocol.connection_id,
          messages: protocol.messages
        }

        {:ok, expected, {:transaction_result, call.index, origin}}

      _ ->
        :error
    end
  end

  defp completion_result(state, source, %{source: call, input: protocol}) do
    values = fn position -> Map.fetch(state.term_values, {call.index, [2, 2, position]}) end

    with {:ok, %{value: query}} <- values.(1),
         {:ok, %{value: rows}} <- values.(2),
         %{tag: tag, index: index} <- command_origin(state, source, protocol) do
      {command, count} = completion_command(tag, rows)
      count = if is_nil(count) and command == :select, do: length(rows), else: count
      rows = if is_nil(query.columns) and rows == [] and command != :copy, do: nil, else: rows

      expected = %Postgrex.Result{
        command: command,
        num_rows: count || 0,
        rows: rows,
        columns: query.columns,
        connection_id: protocol.connection_id,
        messages: protocol.messages
      }

      {:ok, expected, {:completion_result, call.index, index}}
    else
      _ -> :error
    end
  end

  defp transaction_tags(state, source, protocol) do
    frame =
      Enum.find(Map.get(state.frames, source.pid, []), fn frame ->
        frame.source.mfa == {Postgrex.Protocol, :recv_transaction, 3}
      end)

    case frame do
      %{source: entry} ->
        {tags, origins} = transaction_commands(state, source, protocol, entry.index)
        {:ok, tags, origins}

      nil ->
        :error
    end
  end

  defp transaction_commands(state, source, protocol, first) do
    state.decoders.instances
    |> Enum.filter(fn instance ->
      instance.port == NativeTransport.physical_port(state.native, protocol.sock) and
        instance.returned.pid == source.pid and
        instance.source.index > first and instance.returned.index < source.index and
        match?({:ok, {:msg_command_complete, _}, _}, instance.expected)
    end)
    |> Enum.map(fn %{expected: {:ok, {:msg_command_complete, tag}, _}, returned: returned} ->
      {tag, returned.index}
    end)
    |> Enum.unzip()
  end

  defp command_origin(state, source, protocol) do
    first = callback_boundary(state, source)

    state.decoders.instances
    |> Enum.filter(fn instance ->
      instance.port == NativeTransport.physical_port(state.native, protocol.sock) and
        instance.returned.pid == source.pid and
        instance.source.index > first and
        instance.returned.index < source.index and
        command_message?(instance.expected)
    end)
    |> List.last()
    |> case do
      %{expected: {:ok, {:msg_command_complete, tag}, _}, returned: returned} ->
        %{tag: tag, index: returned.index}

      %{expected: {:ok, {:msg_portal_suspend}, _}, returned: returned} ->
        %{tag: :portal_suspend, index: returned.index}

      %{expected: {:ok, {:msg_empty_query}, _}, returned: returned} ->
        %{tag: nil, index: returned.index}

      _ ->
        nil
    end
  end

  defp command_message?({:ok, {:msg_command_complete, _}, _}), do: true

  defp command_message?({:ok, {kind}, _}) when kind in [:msg_empty_query, :msg_portal_suspend],
    do: true

  defp command_message?(_message), do: false

  defp callback_boundary(state, source) do
    case status_callback(state, source.pid) do
      %{source: %{index: index}} -> index
      _ -> source.index
    end
  end

  defp completion_command(:portal_suspend, rows), do: {:stream, length(rows)}
  defp completion_command(tag, _rows), do: command_tag(tag)

  defp command_tag(nil), do: {nil, nil}

  defp command_tag("INSERT " <> tail) do
    [_oid, count] = :binary.split(tail, " ")
    {:insert, String.to_integer(count)}
  end

  for {prefix, command} <- [
        {"SELECT", :select},
        {"UPDATE", :update},
        {"DELETE", :delete},
        {"FETCH", :fetch},
        {"MOVE", :move},
        {"COPY", :copy}
      ] do
    defp command_tag(unquote(prefix) <> " " <> count),
      do: {unquote(command), String.to_integer(count)}
  end

  defp command_tag(tag), do: command_name(tag, <<>>)
  defp command_name(<<>>, name), do: {String.to_atom(name), nil}
  defp command_name(<<?\s, tail::binary>>, name), do: command_name(tail, name <> "_")

  defp command_name(<<head, tail::binary>>, name) when head in ?A..?Z,
    do: command_name(tail, <<name::binary, head + 32>>)

  defp command_name(_tail, name), do: {name |> String.trim_trailing("_") |> String.to_atom(), nil}

  defp error_copy(state, source, path, actual, expected, origin) do
    state = exact(state, source, :state_error_copy, actual, expected)
    copy = %{index: source.index, path: path, origin: origin}

    state
    |> Map.update!(:terms, &[copy | &1])
    |> put_in([:term_values, {source.index, path}], %{value: expected, origin: origin})
  end

  defp message_copy(state, source, actual, expected, origin) do
    state = exact(state, source, :state_message_copy, actual, expected)
    path = [2, 2, 2]
    state = copy_error_path(state, source, path, :state_message_copy)
    copy = %{index: source.index, path: path, origin: origin}

    state
    |> Map.update!(:terms, &[copy | &1])
    |> put_in([:term_values, {source.index, path}], %{value: expected, origin: origin})
  end

  defp send_buffer_origin(state, _source, version, false),
    do: {state, version.protocol.buffer, {:state_buffer, version.origin}}

  defp send_buffer_origin(state, source, version, true) do
    case cursor_version(state, source, version.protocol) do
      %{index: index, port: port, cursor: cursor} ->
        {state, cursor.buffer, {:decoder_cursor, port, index}}

      nil ->
        {failure(state, source, :state_buffer_origin), version.protocol.buffer, :unbound}
    end
  end

  defp returned(state, source, frame, result, rest) do
    function = elem(source.mfa, 1)
    state = buffer_return(state, source, frame, result)
    state = helper_return(state, source, frame, result)
    state = described(state, source, frame, result)

    case returned_protocol(function, result) do
      {:ok, protocol, path} ->
        {state, expected} = output_protocol(state, source, frame, function, result)
        state = exact(state, source, :state_output_copy, protocol, expected)
        version = %{frame.owner | origin: {source.index, path}, protocol: protocol}
        state = %{state | versions: [version | state.versions]}
        state = copy(state, source, path, version)

        advance_owner(state, source.pid, function, version, rest)

      nil ->
        state
    end
  end

  defp advance_owner(state, pid, _function, version, []) do
    state =
      state
      |> put_in([:ports, version.protocol.sock], version)
      |> put_in([:completed, pid], version)

    case state.starting[pid] do
      nil -> state
      context -> put_in(state.starting[pid], %{context | version: version})
    end
  end

  defp advance_owner(state, _pid, function, _version, _rest) when function in @copies,
    do: state

  defp advance_owner(state, pid, function, version, [parent | outer]) do
    parsed? =
      function in [
        :parse_describe,
        :parse_describe_close,
        :close_parse_describe,
        :parse_describe_flush,
        :close_parse_describe_flush
      ]

    parent = %{
      parent
      | current: version.protocol,
        owner: version,
        parsed?: parent.parsed? or parsed?
    }

    put_in(state.frames[pid], [parent | outer])
  end

  defp returned_protocol(:handle_msg, %Postgrex.Protocol{} = protocol),
    do: {:ok, protocol, [3]}

  defp returned_protocol(:redescribe, {_, _, %Postgrex.Protocol{} = protocol, _}),
    do: {:ok, protocol, [3, 2]}

  defp returned_protocol(function, {_, _, %Postgrex.Protocol{} = protocol, _})
       when function in [:describe, :reload_describe_result],
       do: {:ok, protocol, [3, 2]}

  defp returned_protocol(:recv_describe, {:ok, _, _, _, _, %Postgrex.Protocol{} = protocol, _}),
    do: {:ok, protocol, [3, 5]}

  defp returned_protocol(_function, result) when is_tuple(result) and tuple_size(result) > 0 do
    position = tuple_size(result) - 1

    case elem(result, position) do
      %Postgrex.Protocol{} = protocol -> {:ok, protocol, [3, position]}
      _ -> nil
    end
  end

  defp returned_protocol(_function, _result), do: nil

  defp input_protocol(state, source, protocol, :msg_send, _arguments) do
    preserve? =
      case List.first(source.stack) do
        {Postgrex.Protocol, function, _} ->
          function in [
            :error_flushed,
            :rollback_flushed,
            :reload_flushed,
            :reload_ready,
            :reload_transaction
          ]

        _ ->
          false
      end

    expected = if preserve?, do: protocol, else: %{protocol | buffer: nil}
    {state, expected}
  end

  defp input_protocol(state, _source, protocol, :reload_spawn, _arguments),
    do: {state, %{protocol | buffer: nil}}

  defp input_protocol(state, source, protocol, :disconnect, _arguments) do
    if Map.has_key?(state.starting, source.pid),
      do: {state, %{protocol | buffer: cursor_buffer(state, source, %{input: protocol})}},
      else: {state, protocol}
  end

  defp input_protocol(state, source, protocol, function, _arguments)
       when function in [
              :parse_describe,
              :parse_describe_close,
              :close_parse_describe,
              :parse_describe_flush
            ] do
    if {Postgrex.Protocol, :reload_spawn, 5} in source.stack,
      do: {state, %{protocol | buffer: cursor_buffer(state, source, %{input: protocol})}},
      else: {state, protocol}
  end

  defp input_protocol(state, source, protocol, :done, arguments) when length(arguments) == 2,
    do: ready_protocol(state, source, protocol)

  defp input_protocol(state, _source, protocol, :ping_recv, _arguments),
    do: {state, %{protocol | buffer: nil}}

  defp input_protocol(state, source, protocol, :activate, _arguments) do
    if {Postgrex.Protocol, :ping_recv, 4} in source.stack do
      {state, expected} = ready_protocol(state, source, protocol)
      {state, %{expected | buffer: protocol.buffer}}
    else
      {state, protocol}
    end
  end

  defp input_protocol(state, _source, protocol, _function, _arguments), do: {state, protocol}

  defp output_protocol(state, source, frame, function, {:ok, _query, _protocol})
       when function in [:parse_describe_flush, :close_parse_describe_flush] do
    case query_origin(state, frame) do
      %Postgrex.Query{} = expected_query ->
        postgres =
          case frame.current.postgres do
            {postgres, _ref} -> postgres
            postgres -> postgres
          end

        protocol = %{frame.current | postgres: {postgres, expected_query.ref}}
        {state, %{protocol | buffer: cursor_buffer(state, source, frame)}}

      nil ->
        {failure(state, source, :state_query_origin), frame.current}
    end
  end

  defp output_protocol(state, source, frame, function, _result)
       when function in [:recv_ready, :recv_strict_ready] do
    ready_protocol(state, source, frame.current)
  end

  defp output_protocol(state, _source, frame, :done, _result),
    do: {state, %{frame.input | messages: []}}

  defp output_protocol(state, source, frame, :handle_msg, _result) do
    message = native_message(state, frame.source, frame.input)

    expected =
      case message do
        msg_parameter(name: name, value: value) when is_map(frame.input.parameters) ->
          %{frame.input | parameters: Map.put(frame.input.parameters, name, value)}

        msg_parameter(name: _name, value: _value) ->
          frame.input

        msg_notice(fields: fields) ->
          %{frame.input | messages: [fields | frame.input.messages]}

        msg_notify(channel: _channel, payload: _payload) ->
          frame.input

        _ ->
          :no_message_origin
      end

    if expected == :no_message_origin,
      do: {failure(state, source, :state_message_origin), frame.input},
      else: {state, expected}
  end

  defp output_protocol(state, _source, frame, :activate, _result) do
    {_, :call, {_, _, [_protocol, buffer]}} = frame.source.event
    expected = if buffer == <<>>, do: %{frame.input | buffer: :active_once}, else: frame.input
    {state, expected}
  end

  defp output_protocol(state, source, frame, :recv_buffer, _result) do
    deliveries = state.native.active ++ state.decoders.replays

    received =
      Enum.filter(deliveries, fn delivery ->
        event = Map.get(delivery, :received, Map.get(delivery, :returned))

        event.pid == source.pid and event.index > frame.source.index and
          event.index < source.index
      end)

    case received do
      [] ->
        {state, %{frame.input | buffer: <<>>}}

      [delivery] ->
        bytes = Map.get(delivery, :bytes, Map.get(delivery, :input))
        {state, %{frame.input | buffer: bytes}}

      _ ->
        {failure(state, source, :state_buffer_delivery), frame.input}
    end
  end

  defp output_protocol(state, source, frame, :ping_recv, _result) do
    {_, :call, {_, _, [_protocol, _status, old_buffer, _buffer]}} = frame.source.event

    if is_nil(old_buffer),
      do: ready_protocol(state, source, frame.current),
      else: {state, frame.current}
  end

  defp output_protocol(state, source, frame, function, {:disconnect, _, _})
       when function in [:describe, :redescribe, :reload_describe_result] do
    # These three native type-error branches install the already consumed
    # lexical buffer. Their success/reload branches preserve the input state.
    {buffer, _origin} = helper_buffer_origin(state, source, frame.owner, frame)
    {state, %{frame.input | buffer: buffer}}
  end

  defp output_protocol(state, _source, frame, :redescribe, _result), do: {state, frame.input}

  defp output_protocol(state, _source, frame, :handle_prepare, _result) do
    {_, :call, {_, _, [query, _opts, _protocol]}} = frame.source.event

    expected =
      if frame.parsed? and query.name != "" and not is_nil(frame.input.queries),
        do: %{frame.current | messages: []},
        else: frame.current

    {state, expected}
  end

  defp output_protocol(state, _source, frame, _function, _result), do: {state, frame.current}

  defp described(state, source, frame, {:ok, %Postgrex.Query{}, _protocol, _buffer}) do
    if source.mfa in [{Postgrex.Protocol, :redescribe, 6}, {Postgrex.Protocol, :describe, 7}] do
      case state.decoders.query_outputs[source.index] do
        %{query: expected} ->
          put_in(state.described[frame.input.sock], %{query: expected, index: source.index})

        nil ->
          failure(state, source, :state_query_origin)
      end
    else
      state
    end
  end

  defp described(state, _source, _frame, _result), do: state

  defp query_origin(state, frame) do
    case Map.get(state.described, frame.input.sock) do
      %{index: index, query: query} when index > frame.source.index ->
        query

      _ ->
        case state.term_values[{frame.source.index, [2, 2, 2]}] do
          %{value: %Postgrex.Query{ref: ref, types: types} = query}
          when is_reference(ref) and types === frame.input.types ->
            query

          _ ->
            nil
        end
    end
  end

  defp ready_protocol(state, source, protocol) do
    case native_message(state, source, protocol) do
      msg_ready(status: status) ->
        expected = %{
          protocol
          | postgres: status,
            buffer: cursor_buffer(state, source, %{input: protocol})
        }

        {state, expected}

      _ ->
        {failure(state, source, :state_ready_origin), protocol}
    end
  end

  defp native_message(state, source, protocol) do
    case native_message_instance(state, source, protocol) do
      %{expected: {:ok, message, _rest}} -> message
      _ -> :no_native_message
    end
  end

  defp native_message_instance(state, source, protocol) do
    state.decoders.instances
    |> Enum.filter(
      &(&1.port == NativeTransport.physical_port(state.native, protocol.sock) and
          &1.returned.pid == source.pid and
          &1.returned.index < source.index)
    )
    |> List.last()
  end

  defp cursor_version(state, source, %{sock: socket}) do
    port = NativeTransport.physical_port(state.native, socket)

    state.decoders.timeline
    |> Enum.filter(&(&1.port == port and &1.index < source.index))
    |> List.last()
  end

  defp cursor_version(_state, _source, _protocol), do: nil

  defp cursor_buffer(state, source, frame) do
    case cursor_version(state, source, frame.input) do
      %{cursor: cursor} -> cursor.buffer
      nil -> frame.input.buffer
    end
  end

  defp pair_returned(state, source), do: Map.get(state.returns, source.index)

  defp copy(state, source, path, version) do
    copy = %{index: source.index, path: path, origin: version.origin}
    %{state | copies: [copy | state.copies]}
  end

  defp exact(state, _source, _rule, actual, expected) when actual === expected, do: state

  defp exact(state, source, rule, actual, expected) do
    state = failure(state, source, rule)

    fields =
      case {actual, expected} do
        {%Postgrex.Protocol{}, %Postgrex.Protocol{}} ->
          for {field, value} <- Map.from_struct(expected),
              Map.fetch!(actual, field) !== value,
              do: field

        _ ->
          []
      end

    [error | errors] = state.errors
    %{state | errors: [Map.put(error, :different_fields, fields) | errors]}
  end

  defp failure(state, source, rule) do
    error = %{
      index: source.index,
      at: Map.take(source, [:mfa, :role, :stack]),
      rule: rule,
      actual: false,
      expected: true
    }

    %{state | errors: [error | state.errors]}
  end
end
