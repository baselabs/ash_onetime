defmodule AshOnetime.Test.ExitBoundary.ConnectionNative do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.ConnectionDecoders
  alias AshOnetime.Test.ExitBoundary.ConnectionTls
  alias AshOnetime.Test.Repo

  @domain_shapes [
    :domain_reload,
    :domain_array_reload,
    :composite_domain_reload,
    :composite_domain_array_reload,
    :nested_composite_domain_reload,
    :nested_composite_array_domain_reload,
    :array_composite_domain_reload,
    :array_nested_composite_array_domain_reload
  ]

  # Every packet here goes to the job's real PostgreSQL. Authentication and type
  # bootstrap finish before capture; the socket is owned and closed by the root.
  # Corruptions change real native calls or real frontend messages, never captures.
  def observe(mode, corruption \\ nil) do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect()
          protocol = initial_mode(protocol, mode)
          {:gen_tcp, port} = protocol.sock
          {:connected, owner} = Port.info(port, :connected)
          send(observer, {tag, %{self() => %{protocol: protocol, port_owner: owner}}})
          protocol
        end,
        &execute(&1, mode, corruption),
        native_spec(mode)
      )

    receive do
      {^tag, historical} -> Map.put(run, :native_history, historical)
    after
      0 -> raise "native connection history was not captured"
    end
  end

  defp initial_mode(protocol, :historical_active) do
    {:ok, protocol} = Postgrex.Protocol.checkin(protocol)
    protocol
  end

  defp initial_mode(protocol, _mode), do: protocol

  # Exercise the actual Holder API on a real, single-connection Postgrex pool.
  # The deliberately altered write is restored before the next callback runs.
  def observe_holder(corruption \\ nil) do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          options =
            Repo.config()
            |> Keyword.delete(:name)
            |> Keyword.put(:pool, DBConnection.ConnectionPool)
            |> Keyword.put(:pool_size, 1)
            |> Keyword.put(:types, Postgrex.DefaultTypes)

          {:ok, pool} = Postgrex.start_link(options)

          try do
            holder =
              DBConnection.run(pool, fn %{pool_ref: pool_ref} ->
                {:pool_ref, _, _, _, holder, _} = pool_ref
                {:idle, _protocol} = DBConnection.Holder.handle(pool_ref, :handle_status, [], [])
                holder
              end)

            DBConnection.get_connection_metrics(pool)
            [row] = :ets.lookup(holder, :conn)
            send(observer, {tag, %{holder => holder_fields(row)}})
            pool
          catch
            kind, reason ->
              GenServer.stop(pool)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end
        end,
        fn pool ->
          try do
            DBConnection.run(pool, fn %{pool_ref: pool_ref} ->
              {:idle, protocol} = DBConnection.Holder.handle(pool_ref, :handle_status, [], [])

              holder_action(pool_ref, protocol, corruption)
              :ok
            end)
          after
            GenServer.stop(pool)
          end
        end,
        %{host: [], callbacks: []}
      )

    receive do
      {^tag, historical} -> Map.put(run, :native_history, historical)
    after
      0 -> raise "native holder state was not captured"
    end
  end

  defp holder_fields(
         {:conn, owner, Postgrex.Protocol, protocol, lock, clock, deadline, status}
       ) do
    {:gen_tcp, port} = protocol.sock
    {:connected, port_owner} = Port.info(port, :connected)

    %{
      owner: owner,
      port_owner: port_owner,
      protocol: protocol,
      lock: lock,
      clock: clock,
      deadline: deadline,
      status: status
    }
  end

  defp holder_action(pool_ref, protocol, {:committed_history, observer, token}) do
    {:pool_ref, _, _, _, holder, _} = pool_ref

    protocol =
      case protocol do
        %{buffer: :active_once} ->
          {:ok, checked} = Postgrex.Protocol.checkout(protocol)
          :ok = DBConnection.Holder.put_state(pool_ref, checked)
          [row] = :ets.lookup(holder, :conn)
          elem(row, 3)

        %{buffer: buffer} when is_binary(buffer) ->
          protocol
      end

    {:ok, active} = Postgrex.Protocol.checkin(protocol)
    holder_barrier(observer, token, holder, :uncommitted_checkin)
    :ok = DBConnection.Holder.put_state(pool_ref, active)
    holder_barrier(observer, token, holder, :committed_checkin)

    # Refresh the actual holder lookup before the next direct callback. The
    # temporary callback return and the committed ETS row are separate origins.
    [row] = :ets.lookup(holder, :conn)
    {:ok, passive} = Postgrex.Protocol.checkout(elem(row, 3))
    holder_barrier(observer, token, holder, :uncommitted_checkout)
    :ok = DBConnection.Holder.put_state(pool_ref, passive)
    holder_barrier(observer, token, holder, :committed_checkout)
  end

  defp holder_action(pool_ref, protocol, corruption) do
    stored =
      if corruption == :state_copy,
        do: %{protocol | null: :foreign_native_null},
        else: protocol

    :ok = DBConnection.Holder.put_state(pool_ref, stored)
    :ok = DBConnection.Holder.put_state(pool_ref, protocol)
  end

  defp holder_barrier(observer, token, holder, phase) do
    send(observer, {:native_holder_cut, token, self(), holder, phase})

    receive do
      {:native_holder_cut, ^token, ^phase, :observed} -> :ok
    after
      5_000 -> raise "the native holder observer did not acknowledge its live read"
    end
  end

  def observe_tls(corruption \\ nil) do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect_tls(corruption)
          {:ssl, socket} = protocol.sock
          binding = ConnectionTls.bind(socket)
          binding = tls_debug(binding, corruption)
          if corruption == :fragmented, do: :ok = :inet.setopts(binding.port, buffer: 1024)
          {binding, checked, other} = tls_families(binding, corruption)
          send(observer, {tag, binding})
          {protocol, checked, other, binding}
        end,
        fn {protocol, binding, other, _family} ->
          try do
            errors = ConnectionTls.validate(binding)
            execute_tls(protocol, corruption)
            errors
          after
            if other, do: :ok = :ssl.close(elem(other.sock, 1))
          end
        end,
        %{
          host: [],
          callbacks: [],
          services: %{ssl_manager: {:ssl_manager, :handle_info, 2}},
          preexisting: fn {_protocol, _binding, _other, family} ->
            Enum.flat_map(family.families, &[&1.owner, &1.sender])
          end
        }
      )

    receive do
      {^tag, binding} ->
        for family <- binding.families, pid <- [family.owner, family.sender] do
          monitor = Process.monitor(pid)

          receive do
            {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
          after
            10_000 -> raise "the native TLS fixture did not stop its worker"
          end
        end

        Map.put(run, :tls_binding, ConnectionTls.freeze_debug(run.events, binding))
    after
      0 -> raise "native TLS binding was not captured"
    end
  end

  defp tls_debug(binding, :debug) do
    for pid <- [binding.owner, binding.sender], do: :ok = :sys.log(pid, true)
    ConnectionTls.bind(binding.socket)
  end

  defp tls_debug(binding, _corruption), do: binding

  defp tls_families(binding, corruption) when corruption in [:binding, :workers] do
    other = connect_tls()
    other_binding = ConnectionTls.bind(elem(other.sock, 1))

    checked =
      case corruption do
        :binding ->
          %{other_binding | socket: binding.socket}

        :workers ->
          %{binding | supervisor: other_binding.supervisor, sender: other_binding.sender}
      end

    {Map.put(binding, :families, [binding, other_binding]), checked, other}
  end

  defp tls_families(binding, _corruption),
    do: {Map.put(binding, :families, [binding]), binding, nil}

  defp execute_tls(%{sock: {module, socket}}, :fragmented) do
    sql = "SELECT 17::int4 AS connection_stream_probe, repeat('x', 1048576)::text AS filler"

    :ok = module.send(socket, query_sql(sql))
    drain(module, socket, 1, <<>>, true, nil)
  after
    :ok = module.close(socket)
  end

  defp execute_tls(protocol, corruption),
    do: execute(protocol, :single, if(corruption == :byte, do: :byte))

  defp connect_tls(:fragmented) do
    previous = Application.fetch_env(:ssl, :internal_active_n)
    :ok = Application.put_env(:ssl, :internal_active_n, 2)

    try do
      connect_tls()
    after
      case previous do
        {:ok, value} -> Application.put_env(:ssl, :internal_active_n, value)
        :error -> Application.delete_env(:ssl, :internal_active_n)
      end
    end
  end

  defp connect_tls(_corruption), do: connect_tls()

  defp connect_tls do
    options =
      Repo.config()
      |> Keyword.put(:types, Postgrex.DefaultTypes)
      |> Keyword.put(:ssl,
        verify: :verify_peer,
        cacertfile: System.fetch_env!("ASH_ONETIME_NATIVE_TLS_CA_FILE") |> String.to_charlist(),
        server_name_indication: ~c"localhost"
      )

    {:ok, protocol} = Postgrex.Protocol.connect(options)
    {:ok, protocol} = Postgrex.Protocol.checkout(protocol)
    protocol
  end

  defp native_spec(:buffered) do
    %{
      host: [],
      callbacks: [],
      frames: [
        {Postgrex.Protocol, :ping, 1},
        {Postgrex.Protocol, :ping, 2},
        {Postgrex.Protocol, :checkin, 1},
        {Postgrex.Protocol, :checkout, 1},
        {Postgrex.Protocol, :msg_send, 3},
        {Postgrex.Protocol, :msg_recv, :_},
        {Postgrex.Protocol, :msg_decode, 1},
        {Postgrex.Protocol, :activate, 2},
        {Postgrex.Protocol, :recv_buffer, 1}
      ]
    }
  end

  defp native_spec(_mode), do: %{host: [], callbacks: []}

  # The server prepares this statement before observation. Its actual description
  # is retained independently of the later Bind and DataRow being checked.
  def observe_prepared do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect()
          send(observer, {tag, prepare_history(protocol)})
          protocol
        end,
        &execute(&1, :prepared, nil),
        %{host: [], callbacks: []}
      )

    receive do
      {^tag, history} -> %{run: run, history: history}
    after
      0 -> raise "native prepared history was not captured"
    end
  end

  def observe_cached(corruption \\ nil, shape \\ :rows) do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect(:named, shape)
          protocol = cached_environment(protocol, shape)
          {statement, arguments} = cached_statement(shape)

          query = %Postgrex.Query{
            name: "native_cached",
            statement: statement,
            cache: :statement
          }

          {:ok, query, protocol} = Postgrex.Protocol.handle_prepare(query, [], protocol)
          params = DBConnection.Query.encode(query, arguments, [])

          protocol = warm_cached(protocol, query, params, shape)

          %{sock: {module, socket}} = protocol
          describe = message(?D, <<?S, query.name::binary, 0>>)
          bytes = IO.iodata_to_binary([describe, message(?S, <<>>)])
          :ok = module.send(socket, bytes)
          chunks = [%{index: 0, direction: :frontend, bytes: bytes}]
          chunks = history_replies(module, socket, 1, <<>>, chunks)
          descriptor = %{query: query, port: socket, index: {:historical, self()}, path: [:query]}

          history = %{
            protocol: protocol,
            descriptors: [Map.put(descriptor, :sock, protocol.sock)]
          }

          history =
            if shape == :cross_connection do
              other = connect(:named)
              :ok = module.close(socket)
              %{history | protocol: other}
            else
              history
            end

          history =
            if shape == :redescribe do
              {:ok, _result, protocol} =
                Postgrex.Protocol.handle_close(query, [], history.protocol)

              {:ok, _results, protocol} =
                Postgrex.Protocol.handle_simple(
                  "ALTER TABLE pg_temp.ash_onetime_native_description ADD COLUMN filler text DEFAULT 'native'",
                  [],
                  protocol
                )

              %{history | protocol: protocol}
            else
              history
            end

          if shape == :large_rows do
            :ok = :inet.setopts(socket, buffer: 4096, recbuf: 8192)
          end

          send(observer, {tag, %{holder: self(), history: history, chunks: chunks}})
          {history.protocol, query, params, shape}
        end,
        &execute_cached(&1, corruption),
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

    receive do
      {^tag, history} -> %{run: run, history: history}
    after
      0 -> raise "native cached descriptor history was not captured"
    end
  end

  def observe_query_factory(shape \\ :rows, prepare \\ :named, options \\ []) do
    observer = self()
    tag = make_ref()

    reload_factory =
      Compiled.native_closure_factory(Postgrex.Protocol, :reload_spawn, 5, :reload_init, 5)

    run =
      ExitBoundary.observe(
        fn ->
          protocol = query_factory_environment(connect(prepare), shape)

          protocol =
            if options[:mode] == :savepoint do
              {:ok, %Postgrex.Result{}, protocol} = Postgrex.Protocol.handle_begin([], protocol)
              protocol
            else
              protocol
            end

          history = %{protocol: protocol, reload_factory: reload_factory}
          send(observer, {tag, %{self() => history}})
          protocol
        end,
        fn %{sock: {module, socket}} = protocol ->
          query = %Postgrex.Query{
            name: "native_query_factory",
            statement: query_factory_statement(shape),
            cache: :statement
          }

          try do
            settings = Keyword.merge(query_factory_options(shape), options)

            case Postgrex.Protocol.handle_prepare(query, settings, protocol) do
              {:ok, %Postgrex.Query{} = prepared, %Postgrex.Protocol{} = current}
              when shape in [:rows, :none, :external_notify, :enum_reload, :composite_reload] or
                     shape in @domain_shapes ->
                query_factory_result(shape, prepared, current)

              {:error, %Postgrex.Error{postgres: %{code: :syntax_error}}, %Postgrex.Protocol{}}
              when shape == :prepare_error ->
                :prepare_error

              {:disconnect, _error, %Postgrex.Protocol{}}
              when shape == :unsupported_type ->
                :unsupported_type
            end
          after
            :ok = module.close(socket)
          end
        end,
        %{
          host: [],
          callbacks: [],
          services: fn %{types: {module, table}} ->
            owner = :ets.info(table, :owner)

            %{
              {:native_type_owner, module} => %{
                pid: owner,
                table: table,
                callback: {Postgrex.TypeServer, :handle_call, 3}
              }
            }
          end
        }
      )

    receive do
      {^tag, historical} ->
        observations = ConnectionDecoders.freeze_factories(run.events)

        historical =
          Map.new(historical, fn {pid, history} ->
            {pid, Map.put(history, :factory_observations, observations)}
          end)

        Map.put(run, :native_history, historical)
    after
      0 -> raise "native query factory history was not captured"
    end
  end

  defp query_factory_statement(:rows), do: "SELECT $1::int4 AS connection_stream_probe"
  defp query_factory_statement(:external_notify), do: query_factory_statement(:rows)
  defp query_factory_statement(:none), do: "SET application_name TO 'ash_onetime_native_prepare'"
  defp query_factory_statement(:prepare_error), do: "SELECT ("

  defp query_factory_statement(:enum_reload),
    do: "SELECT 'native'::pg_temp.ash_onetime_native_enum AS connection_stream_probe"

  defp query_factory_statement(:composite_reload),
    do:
      "SELECT ROW(17, 'native')::pg_temp.ash_onetime_native_composite AS connection_stream_probe"

  defp query_factory_statement(shape) when shape in @domain_shapes do
    {type, _expected} = domain_case(shape)
    "SELECT $1::pg_temp." <> type <> " AS connection_stream_probe"
  end

  defp query_factory_statement(:unsupported_type),
    do: "SELECT NULL::pg_node_tree AS connection_stream_probe"

  defp domain_case(:domain_reload), do: {"native_scalar_domain", 17}
  defp domain_case(:domain_array_reload), do: {"native_array_domain", [17]}

  defp domain_case(:composite_domain_reload),
    do: {"native_composite_domain", {17, "native"}}

  defp domain_case(:composite_domain_array_reload),
    do: {"native_composite_array_domain", [{17, "native"}]}

  defp domain_case(:nested_composite_domain_reload),
    do: {"native_nested_domain", {17, "native"}}

  defp domain_case(:nested_composite_array_domain_reload),
    do: {"native_nested_array_domain", [{17, "native"}]}

  defp domain_case(:array_composite_domain_reload),
    do: {"native_composite_domain[]", [{17, "native"}]}

  defp domain_case(:array_nested_composite_array_domain_reload),
    do: {"native_nested_array_domain[]", [[{17, "native"}]]}

  defp query_factory_result(shape, query, protocol) when shape in @domain_shapes do
    {_type, expected} = domain_case(shape)
    parameters = DBConnection.Query.encode(query, [expected], [])

    {:ok, query, result, _protocol} =
      Postgrex.Protocol.handle_execute(query, parameters, [], protocol)

    [[^expected]] = DBConnection.Query.decode(query, result, []).rows
    :ok
  end

  defp query_factory_result(_shape, _query, _protocol), do: :ok

  defp query_factory_environment(protocol, :enum_reload) do
    {:ok, _, protocol} =
      Postgrex.Protocol.handle_simple(
        "CREATE TYPE pg_temp.ash_onetime_native_enum AS ENUM ('native')",
        [],
        protocol
      )

    protocol
  end

  defp query_factory_environment(protocol, :composite_reload) do
    {:ok, _, protocol} =
      Postgrex.Protocol.handle_simple(
        "CREATE TYPE pg_temp.ash_onetime_native_composite AS (number int4, label text)",
        [],
        protocol
      )

    protocol
  end

  defp query_factory_environment(protocol, shape) when shape in @domain_shapes do
    statement = """
    CREATE TYPE pg_temp.native_domain_composite AS (number int4, label text);
    CREATE DOMAIN pg_temp.native_scalar_domain AS int4;
    CREATE DOMAIN pg_temp.native_array_domain AS int4[];
    CREATE DOMAIN pg_temp.native_composite_domain AS pg_temp.native_domain_composite;
    CREATE DOMAIN pg_temp.native_composite_array_domain AS pg_temp.native_domain_composite[];
    CREATE DOMAIN pg_temp.native_nested_domain AS pg_temp.native_composite_domain;
    CREATE DOMAIN pg_temp.native_nested_array_domain AS pg_temp.native_composite_array_domain;
    """

    {:ok, _, protocol} = Postgrex.Protocol.handle_simple(statement, [], protocol)
    protocol
  end

  defp query_factory_environment(protocol, _shape), do: protocol

  defp query_factory_options(:external_notify), do: [notify: &__MODULE__.ignore_notification/2]
  defp query_factory_options(_shape), do: []

  def ignore_notification(_channel, _payload), do: :ok

  def observe_ping_options do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect()
          send(observer, {tag, %{self() => %{protocol: protocol}}})
          protocol
        end,
        fn %{sock: {module, socket}} = protocol ->
          try do
            {:ok, %Postgrex.Protocol{}} =
              Postgrex.Protocol.ping(protocol, notify: &__MODULE__.ignore_notification/2)

            :ok
          after
            :ok = module.close(socket)
          end
        end,
        %{host: [], callbacks: []}
      )

    receive do
      {^tag, history} -> Map.put(run, :native_history, history)
    after
      0 -> raise "native ping options history was not captured"
    end
  end

  def observe_prepare_cycle do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect(:named)
          send(observer, {tag, %{self() => %{protocol: protocol}}})
          protocol
        end,
        fn %{sock: {module, socket}} = protocol ->
          query = %Postgrex.Query{
            name: "native_prepare_cycle",
            statement: query_factory_statement(:rows),
            cache: :statement
          }

          options = [postgrex_prepare: true]

          try do
            {:ok, first, protocol} = Postgrex.Protocol.handle_prepare(query, options, protocol)
            {:ok, cached, protocol} = Postgrex.Protocol.handle_prepare(query, options, protocol)
            {:ok, reparsed, protocol} = Postgrex.Protocol.handle_prepare(first, options, protocol)

            {:ok, %Postgrex.Result{}, protocol} =
              Postgrex.Protocol.handle_close(first, [], protocol)

            {:ok, renewed, _protocol} = Postgrex.Protocol.handle_prepare(query, options, protocol)
            {first.ref, cached.ref, reparsed.ref, renewed.ref}
          after
            :ok = module.close(socket)
          end
        end,
        %{host: [], callbacks: []}
      )

    receive do
      {^tag, historical} -> Map.put(run, :native_history, historical)
    after
      0 -> raise "native prepare-cycle history was not captured"
    end
  end

  def observe_cursor do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect(:named)
          send(observer, {tag, %{self() => %{protocol: protocol}}})
          protocol
        end,
        fn %{sock: {module, socket}} = protocol ->
          query = %Postgrex.Query{
            name: "native_cursor",
            statement: "SELECT generate_series(1, 3)::int4 AS connection_stream_probe",
            cache: :statement
          }

          try do
            {:ok, query, protocol} =
              Postgrex.Protocol.handle_prepare(query, [postgrex_prepare: true], protocol)

            params = DBConnection.Query.encode(query, [], [])
            {:ok, %Postgrex.Result{}, protocol} = Postgrex.Protocol.handle_begin([], protocol)

            {:ok, query, cursor, protocol} =
              Postgrex.Protocol.handle_declare(query, params, [], protocol)

            {:cont, first, protocol} =
              Postgrex.Protocol.handle_fetch(query, cursor, [max_rows: 2], protocol)

            {:halt, last, protocol} =
              Postgrex.Protocol.handle_fetch(query, cursor, [max_rows: 2], protocol)

            {:ok, %Postgrex.Result{}, protocol} =
              Postgrex.Protocol.handle_deallocate(query, cursor, [], protocol)

            {:ok, %Postgrex.Result{}, protocol} =
              Postgrex.Protocol.handle_close(query, [], protocol)

            {:ok, %Postgrex.Result{}, _protocol} = Postgrex.Protocol.handle_commit([], protocol)

            DBConnection.Query.decode(query, first, []).rows ++
              DBConnection.Query.decode(query, last, []).rows
          after
            :ok = module.close(socket)
          end
        end,
        %{host: [], callbacks: []}
      )

    receive do
      {^tag, historical} -> Map.put(run, :native_history, historical)
    after
      0 -> raise "native cursor history was not captured"
    end
  end

  def observe_transactions do
    observer = self()
    tag = make_ref()

    run =
      ExitBoundary.observe(
        fn ->
          protocol = connect()
          send(observer, {tag, %{self() => %{protocol: protocol}}})
          protocol
        end,
        fn %{sock: {module, socket}} = protocol ->
          try do
            {:ok, %Postgrex.Result{}, protocol} = Postgrex.Protocol.handle_begin([], protocol)
            {:ok, %Postgrex.Result{}, protocol} = Postgrex.Protocol.handle_commit([], protocol)
            {:ok, %Postgrex.Result{}, protocol} = Postgrex.Protocol.handle_begin([], protocol)
            {:ok, %Postgrex.Result{}, _protocol} = Postgrex.Protocol.handle_rollback([], protocol)
            :ok
          after
            :ok = module.close(socket)
          end
        end,
        %{host: [], callbacks: []}
      )

    receive do
      {^tag, historical} -> Map.put(run, :native_history, historical)
    after
      0 -> raise "native transaction history was not captured"
    end
  end

  defp cached_statement(:rows), do: {"SELECT $1::int4 AS connection_stream_probe", [17]}
  defp cached_statement(:cross_connection), do: cached_statement(:rows)
  defp cached_statement(:strict), do: cached_statement(:rows)

  defp cached_statement(:redescribe),
    do: {"SELECT * FROM pg_temp.ash_onetime_native_description", []}

  defp cached_statement(:bind_error),
    do: {"SELECT 17 / $1::int4 AS connection_stream_probe", [0]}

  defp cached_statement(:execute_error),
    do:
      {"SELECT 17 / (n - $1::int4) AS connection_stream_probe FROM generate_series(1, 1) AS series(n)",
       [1]}

  defp cached_statement(:large_rows),
    do: {"SELECT $1::int4 AS connection_stream_probe, repeat('x', 131072)::text AS filler", [17]}

  defp cached_statement(:none),
    do: {"SET application_name TO 'ash_onetime_native_nodata'", []}

  defp cached_statement(:notice),
    do: {"DO $$ BEGIN RAISE NOTICE 'native connection notice'; END $$", []}

  defp cached_statement(:parameter),
    do: {"SET application_name TO 'ash_onetime_native_observed'", []}

  defp cached_statement(:notification),
    do: {"NOTIFY ash_onetime_native_stream, 'native notification'", []}

  defp cached_environment(protocol, :parameter) do
    {:ok, _results, protocol} =
      Postgrex.Protocol.handle_simple(
        "SET application_name TO 'ash_onetime_native_prior'",
        [],
        protocol
      )

    protocol
  end

  defp cached_environment(protocol, :notification) do
    {:ok, _results, protocol} =
      Postgrex.Protocol.handle_simple("LISTEN ash_onetime_native_stream", [], protocol)

    protocol
  end

  defp cached_environment(protocol, :redescribe) do
    {:ok, _results, protocol} =
      Postgrex.Protocol.handle_simple(
        "CREATE TEMPORARY TABLE ash_onetime_native_description (connection_stream_probe int4); " <>
          "INSERT INTO pg_temp.ash_onetime_native_description VALUES (17)",
        [],
        protocol
      )

    protocol
  end

  defp cached_environment(protocol, _shape), do: protocol

  defp warm_cached(protocol, _query, _params, shape)
       when shape in [:parameter, :notification, :bind_error, :execute_error],
       do: protocol

  defp warm_cached(protocol, query, params, _shape) do
    {:ok, ^query, _result, protocol} =
      Postgrex.Protocol.handle_execute(query, params, [], protocol)

    protocol
  end

  defp execute_cached({%{sock: {module, socket}} = protocol, query, params, shape}, corruption) do
    query = if corruption == :query_copy, do: %{query | cache: :reference}, else: query

    protocol =
      if corruption == :state_copy, do: %{protocol | null: :foreign_native_null}, else: protocol

    case Postgrex.Protocol.handle_execute(query, params, [], protocol) do
      {:ok, returned_query, result, protocol} ->
        if shape != :redescribe and returned_query !== query,
          do: raise("the native cached query changed without a new description")

        if shape == :notification, do: {:ok, _protocol} = Postgrex.Protocol.ping(protocol)
        DBConnection.Query.decode(returned_query, result, [])

      {:error, %Postgrex.Error{} = error, _protocol} ->
        {:error, error}
    end
  after
    :ok = module.close(socket)
  end

  defp connect(prepare \\ nil, shape \\ nil) do
    options = Keyword.put(Repo.config(), :types, Postgrex.DefaultTypes)
    options = if prepare, do: Keyword.put(options, :prepare, prepare), else: options
    options = if shape == :strict, do: Keyword.put(options, :transactions, :strict), else: options
    {:ok, protocol} = Postgrex.Protocol.connect(options)
    {:ok, protocol} = Postgrex.Protocol.checkout(protocol)
    protocol
  end

  defp execute(%{sock: {:gen_tcp, socket}}, :incomplete, nil) do
    :ok = :inet.setopts(socket, buffer: 4096, recbuf: 8192)
    :ok = :gen_tcp.send(socket, query_sql("SELECT repeat('x', 1048576)"))
    receive_partial(socket)
  after
    :ok = :gen_tcp.close(socket)
  end

  defp execute(%{sock: {module, socket}}, :prepared, nil) do
    bind = <<0, "native_prepared", 0, 1::16, 1::16, 1::16, 4::32, 17::signed-32, 1::16, 1::16>>
    :ok = module.send(socket, [message(?B, bind), message(?E, <<0, 0::32>>), message(?S, <<>>)])
    drain(module, socket, 1, <<>>, true, nil)
  after
    :ok = module.close(socket)
  end

  defp execute(%{sock: {module, socket}}, mode, corruption)
       when mode in [:active, :historical_active, :active_counted] and
              corruption in [nil, :unbound_active_control, :passive_source] do
    if mode == :active, do: :ok = :inet.setopts(socket, active: :once)
    if mode == :active_counted, do: :ok = :inet.setopts(socket, active: 1)
    :ok = module.send(socket, query(17))

    receive do
      {:tcp, ^socket, bytes} ->
        if mode == :active_counted, do: passive_notification(socket, corruption)
        :ok = :inet.setopts(socket, active: false)

        if corruption == :unbound_active_control do
          [1] = :erlang.port_control(socket, 0x03F1A300 + 7, <<22, 0::32>>)
        end

        drain(module, socket, 1, bytes, true, nil)
    after
      15_000 -> raise "native active query did not return"
    end
  after
    :ok = module.close(socket)
  end

  defp execute(%{sock: {module, socket}}, :contended, nil) do
    root = self()
    worker = spawn(fn -> option_load(socket, root) end)

    try do
      for _ <- 1..64 do
        :ok = module.send(socket, query(17))
        :ok = drain(module, socket, 1, <<>>, true, nil)
      end

      :ok
    after
      send(worker, :stop)

      receive do
        {:options_stopped, ^worker} -> :ok
      after
        15_000 -> raise "native option load did not stop"
      end

      :ok = module.close(socket)
    end
  end

  defp execute(%{sock: {module, socket}} = protocol, :buffered, corruption)
       when corruption in [nil, :replay_source] do
    syncs = List.duplicate(message(?S, <<>>), 256)
    :ok = module.send(socket, [syncs, query(17)])
    {:ok, protocol} = Postgrex.Protocol.ping(protocol)
    {:ok, protocol} = Postgrex.Protocol.checkin(protocol)
    drain_buffered(protocol, 257, corruption)
  after
    :ok = module.close(socket)
  end

  defp execute(%{sock: {module, socket}}, mode, corruption) do
    values = values(mode, corruption)
    messages = Enum.map(values, &query/1)
    :ok = module.send(socket, messages)
    :ok = drain(module, socket, length(values), <<>>, true, corruption)

    if corruption == :extra_read do
      {:error, :timeout} = module.recv(socket, 0, 0)
    end

    :ok
  after
    :ok = module.close(socket)
  end

  defp passive_notification(socket, corruption) do
    receive do
      {:tcp_passive, ^socket} -> :ok
    after
      15_000 -> raise "native counted socket did not become passive"
    end

    if corruption == :passive_source do
      send(self(), {:tcp_passive, socket})

      receive do
        {:tcp_passive, ^socket} -> :ok
      after
        0 -> raise "native foreign passive notification was not received"
      end
    end
  end

  defp option_load(socket, root) do
    receive do
      :stop -> send(root, {:options_stopped, self()})
    after
      0 ->
        {:ok, [active: false]} = :inet.getopts(socket, [:active])
        option_load(socket, root)
    end
  end

  defp drain_buffered(%{sock: {module, socket}, buffer: buffer}, ready, corruption)
       when is_binary(buffer) and byte_size(buffer) > 0 do
    receive do
      {:tcp, ^socket, ^buffer} ->
        buffer = replay_copy(socket, buffer, corruption)
        drain(module, socket, ready, buffer, true, nil)
    after
      15_000 -> raise "native buffered replay did not return"
    end
  end

  defp drain_buffered(protocol, ready, _corruption) do
    {:ok, %{sock: {module, socket}, buffer: buffer}} = Postgrex.Protocol.checkout(protocol)
    drain(module, socket, ready, buffer, true, nil)
  end

  defp replay_copy(socket, <<?Z, 5::32, ?I, rest::binary>>, :replay_source) do
    changed = <<?Z, 5::32, ?T, rest::binary>>
    send(self(), {:tcp, socket, changed})

    receive do
      {:tcp, ^socket, ^changed} -> changed
    after
      15_000 -> raise "native corrupt replay copy did not return"
    end
  end

  defp replay_copy(_socket, buffer, _corruption), do: buffer

  defp values(:single, nil), do: [17]
  defp values(:single, :byte), do: [18]
  defp values(:single, corruption) when corruption in [:length, :timeout, :extra_read], do: [17]
  defp values(:pipeline, nil), do: [17, 29]
  defp values(:pipeline, :byte), do: [18, 29]
  defp values(:pipeline, :swap), do: [29, 17]
  defp values(:pipeline, :drop), do: [17]
  defp values(:pipeline, :add), do: [17, 29, 41]

  defp query(value) do
    sql = "SELECT " <> Integer.to_string(value) <> "::int4 AS connection_stream_probe"
    query_sql(sql)
  end

  defp query_sql(sql) do
    <<?Q, byte_size(sql) + 5::32, sql::binary, 0>>
  end

  defp prepare_history(%{sock: {module, socket}}) do
    sql = "SELECT $1::int4 AS connection_stream_probe"
    parse = message(?P, <<"native_prepared", 0, sql::binary, 0, 1::16, 23::32>>)
    describe = message(?D, <<?S, "native_prepared", 0>>)
    bytes = IO.iodata_to_binary([parse, describe, message(?S, <<>>)])
    :ok = module.send(socket, bytes)
    chunks = [%{index: 0, direction: :frontend, bytes: bytes}]
    %{port: socket, chunks: history_replies(module, socket, 1, <<>>, chunks)}
  end

  defp history_replies(module, socket, ready, buffer, chunks) do
    {ready, buffer} = ready_frames(ready, buffer)

    if ready == 0 and buffer == <<>> do
      Enum.reverse(chunks)
    else
      {:ok, bytes} = module.recv(socket, required(buffer), :infinity)
      chunk = %{index: length(chunks), direction: :backend, bytes: bytes}
      history_replies(module, socket, ready, buffer <> bytes, [chunk | chunks])
    end
  end

  defp message(tag, payload), do: <<tag, byte_size(payload) + 4::32, payload::binary>>

  defp receive_partial(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, :infinity)

    case ready_frames(1, data) do
      {_ready, <<>>} -> receive_partial(socket)
      {_ready, _incomplete} -> :ok
    end
  end

  defp drain(_module, _socket, 0, <<>>, _first?, _corruption), do: :ok

  defp drain(module, socket, ready, buffer, first?, corruption) do
    {ready, buffer} = ready_frames(ready, buffer)

    if ready == 0 and buffer == <<>> do
      :ok
    else
      requested = if first? and corruption == :length, do: 1, else: required(buffer)
      timeout = if first? and corruption == :timeout, do: 60_000, else: :infinity
      {:ok, data} = module.recv(socket, requested, timeout)
      drain(module, socket, ready, buffer <> data, false, corruption)
    end
  end

  # This fixture reads ReadyForQuery only. It does not use the comparator's
  # framing, typed decoder or association machine as its completion oracle.
  defp ready_frames(ready, <<tag, size::32, tail::binary>>)
       when size >= 4 and byte_size(tail) >= size - 4 do
    payload_size = size - 4
    <<_payload::binary-size(^payload_size), rest::binary>> = tail
    ready = if tag == ?Z, do: ready - 1, else: ready
    ready_frames(ready, rest)
  end

  defp ready_frames(ready, buffer), do: {ready, buffer}

  defp required(buffer) when byte_size(buffer) < 5, do: 0

  defp required(<<_tag, size::32, tail::binary>>),
    do: min(size - 4 - byte_size(tail), 64 * 1024 * 1024)
end
