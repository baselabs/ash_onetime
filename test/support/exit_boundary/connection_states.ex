defmodule AshOnetime.Test.ExitBoundary.ConnectionStates do
  @moduledoc false
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
    :checkin,
    :checkout,
    :ping
  ]
  @constructors [
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
    :recv_transaction,
    :error_ready,
    :error_flushed,
    :rollback_flushed,
    :reload_flushed
  ]
  @copies [:msg_send, :msg_recv, :rows_recv, :redescribe]
  @owners @callbacks ++ @constructors ++ @scopes ++ @copies
  @last_state @callbacks ++ [:handle_prepare_execute]
  @status_consumers [
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
    :reload_flushed,
    :recv_describe
  ]
  @cursor_buffers %{
    msg_recv: 2,
    rows_recv: 3,
    redescribe: 5,
    describe: 6,
    recv_describe: -1,
    recv_ready: 2,
    recv_strict_ready: 3,
    recv_transaction: -1,
    error_ready: 3,
    error_flushed: 3,
    rollback_flushed: 3,
    reload_flushed: 4,
    ping_recv: 3,
    activate: 1
  }

  # An owner version is a native return, or the pre-observation holder state.
  # Copies must bind to that version before a buffer can leave exact comparison.
  # This ledger grants no event allowance or projection.
  def build(indexed, native, decoders, historical, fixture \\ :unavailable) do
    holders =
      for {holder, %{protocol: protocol}} <- historical, into: %{} do
        {holder, %{origin: {:historical, holder}, protocol: protocol, holder: holder}}
      end

    ports = for {_holder, version} <- holders, into: %{}, do: {version.protocol.sock, version}

    initial = %{
      holders: holders,
      ports: ports,
      lookups: %{},
      completed: %{},
      frames: %{},
      pending: %{},
      described: %{},
      factories: %{},
      versions: Map.values(holders),
      copies: [],
      buffers: [],
      terms: [],
      buffer_values: %{},
      term_values: %{},
      errors: [],
      pairs: native.pairs,
      returns: Map.new(native.pairs, fn {_index, pair} -> {pair.returned.index, pair} end),
      decoders: decoders,
      native: native,
      fixture: fixture
    }

    state = Enum.reduce(indexed.events, initial, &event/2)
    state = unbound_copies(state, indexed)

    %{
      versions: Enum.reverse(state.versions),
      copies: Enum.reverse(state.copies),
      buffers: Enum.reverse(state.buffers),
      terms: Enum.reverse(state.terms),
      errors: Enum.reverse(state.errors)
    }
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
    state = commit(source, state)
    state = holder_event(source, state)
    state = fixture_event(source, state)
    state = factory_event(source, state)
    callback_event(source, state)
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

        expected =
          case {module, length(arguments), progress.remaining} do
            {Postgrex.Types, 2, [oid | _]} ->
              [oid, input.types]

            {Postgrex.Protocol, 2, _} ->
              [input.oids, input.types]

            {Postgrex.Protocol, 3, _} ->
              [input.oids, input.types, []]

            {Postgrex.Protocol, 4, _} ->
              [progress.remaining, input.types, progress.infos, progress.reloads]

            _ ->
              :no_type_origin
          end

        if expected == :no_type_origin do
          failure(state, source, :state_type_factory_origin)
        else
          Enum.with_index(expected)
          |> Enum.reduce(state, fn {value, position}, state ->
            helper_copy(
              state,
              source,
              [2, 2, position],
              Enum.at(arguments, position),
              value,
              {:type_factory, first, progress.origins}
            )
          end)
        end

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

        expected =
          case progress.error do
            {%Postgrex.TypeInfo{} = info, module} ->
              {:error, Postgrex.QueryError.exception(Postgrex.Utils.type_msg(info, module))}

            nil ->
              if MapSet.size(progress.reloads) == 0,
                do: {:ok, Enum.reverse(progress.infos)},
                else: {:reload, progress.reloads}

            :invalid ->
              :no_type_origin
          end

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

      if is_tuple(actual) and tuple_size(actual) == 3 do
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
      else
        helper_copy(state, source, [3], actual, expected, origin)
      end
    else
      _ -> failure(state, source, :state_helper_query_origin)
    end
  end

  defp factory_event(_source, state), do: state

  defp type_context(state, source) do
    frame =
      Enum.find(Map.get(state.frames, source.pid, []), fn frame ->
        elem(frame.source.mfa, 1) in [:describe_params, :describe_result]
      end)

    case frame do
      %{source: owner} ->
        case Map.fetch(state.decoders.query_inputs, owner.index) do
          {:ok, input} ->
            oids =
              if elem(owner.mfa, 1) == :describe_params,
                do: input.param_oids,
                else: input.result_oids

            {:ok, %{oids: oids, types: input.types}, owner.index}

          :error ->
            :error
        end

      nil ->
        :error
    end
  end

  defp type_progress(state, source, input, first) do
    initial = %{remaining: input.oids, infos: [], reloads: MapSet.new(), origins: [], error: nil}

    state.pairs
    |> Map.values()
    |> Enum.filter(
      &(&1.source.pid == source.pid and &1.source.index > first and
          &1.returned.index < source.index and &1.source.mfa == {Postgrex.Types, :fetch, 2})
    )
    |> Enum.sort_by(& &1.source.index)
    |> Enum.reduce(initial, fn pair, progress ->
      case {progress.remaining, pair.returned.event} do
        {[oid | remaining], {_, :return_from, _, result}} ->
          progress = %{
            progress
            | remaining: remaining,
              origins: progress.origins ++ [pair.returned.index]
          }

          case result do
            {:ok, info} -> %{progress | infos: [info | progress.infos]}
            {:error, nil, _module} -> %{progress | reloads: MapSet.put(progress.reloads, oid)}
            {:error, %Postgrex.TypeInfo{} = info, module} -> %{progress | error: {info, module}}
            _ -> %{progress | error: :invalid}
          end

        _ ->
          %{progress | error: :invalid}
      end
    end)
  end

  defp factory_value(state, source, function, actual, options) do
    expected = factory_expected(state, function, options)
    actual = factory_observed(state, actual, expected)
    exact(state, source, :state_status_factory_value, actual, expected)
  end

  defp factory_expected(_state, :mode, options), do: options[:mode] || :transaction

  defp factory_expected(state, :notify, options) do
    options[:notify] ||
      {:compiled_notify, Map.fetch!(state.decoders.factory_identities, :notify), []}
  end

  defp factory_observed(state, actual, {:compiled_notify, _identity, _environment})
       when is_function(actual) do
    Map.get(state.decoders.factory_observations, actual, :missing_observed_factory)
  end

  defp factory_observed(_state, actual, _expected), do: actual

  defp status_callback(state, pid) do
    Enum.find(Map.get(state.frames, pid, []), &(elem(&1.source.mfa, 1) in @last_state))
  end

  defp status_options(%{source: %{event: {_, :call, {_, :ping, [_]}}}}), do: {:ok, []}

  defp status_options(%{source: %{event: {_, :call, {_, function, arguments}}}})
       when function in @last_state do
    case Enum.at(arguments, -2) do
      options when is_list(options) -> {:ok, options}
      _ -> :error
    end
  end

  defp status_options(_frame), do: :error

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
    argument = if function in @last_state, do: length(arguments) - 1, else: 0
    protocol = Enum.at(arguments, argument)
    frames = Map.get(state.frames, pid, [])

    case input_version(protocol, frames, Map.get(state.lookups, pid), state.ports) do
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

  defp input_version(_protocol, [frame | _], _lookup, _ports),
    do: {:ok, %{frame.owner | protocol: frame.current}}

  defp input_version(_protocol, [], lookup, _ports) when not is_nil(lookup), do: {:ok, lookup}

  defp input_version(%Postgrex.Protocol{sock: sock}, [], nil, ports), do: Map.fetch(ports, sock)
  defp input_version(_protocol, _frames, _lookup, _ports), do: :error

  defp buffer_input(state, source, :msg_send, [_protocol, _messages, buffer], version) do
    cursor? =
      Enum.any?(source.stack, fn
        {Postgrex.Protocol, function, _} ->
          function in [:error_flushed, :rollback_flushed, :reload_flushed]

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
        frame.source.mfa == {Postgrex.Protocol, :ping, 1}
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
          read.returned.index < source.index and {:gen_tcp, read.port} == version.protocol.sock
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
       when elem(source.mfa, 1) in [:msg_recv, :rows_recv, :redescribe, :describe, :recv_describe] and
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
          input.param_oids,
          {:parameter_description, input.origin}
        )

      :error ->
        failure(state, source, :state_helper_query_origin)
    end
  end

  defp helper_input(state, source, :done, [_protocol, tags], version) do
    {expected, origins} = transaction_tags(state, source, version.protocol)
    helper_copy(state, source, [2, 2, 1], tags, expected, {:transaction_tags, origins})
  end

  defp helper_input(
         state,
         source,
         :recv_transaction,
         [_protocol, _status, tags, _buffer],
         version
       ) do
    {expected, origins} = transaction_tags(state, source, version.protocol)

    helper_copy(
      state,
      source,
      [2, 2, 2],
      tags,
      Enum.reverse(expected),
      {:transaction_tags, origins}
    )
  end

  defp helper_input(
         state,
         source,
         function,
         [_protocol, _status, actual_query, actual_comment],
         _version
       )
       when function in [:parse_describe_flush, :close_parse_describe_flush] do
    with %{source: callback} = frame <- status_callback(state, source.pid),
         {:ok, options} <- status_options(frame),
         {_, :call, {_, _, [query | _]}} <- callback.event,
         %Postgrex.Query{} <- query do
      state
      |> helper_copy(source, [2, 2, 2], actual_query, query, {:callback_query, callback.index})
      |> helper_copy(
        source,
        [2, 2, 3],
        actual_comment,
        options[:comment],
        {:callback_comment, callback.index}
      )
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
        {expected_command, expected_count} = command_tag(tag)

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
        expected = Postgrex.Error.exception(postgres: fields)
        origin = {:server_error, index}
        error_copy(state, source, [2, 2, 2], actual, expected, origin)

      _ ->
        failure(state, source, :state_error_origin)
    end
  end

  defp helper_input(state, source, :msg_send, [_protocol, messages, _buffer], version) do
    case List.first(Map.get(state.frames, source.pid, [])) do
      %{source: %{mfa: {Postgrex.Protocol, function, 4}}} = frame
      when function in [:handle_execute, :handle_prepare_execute] ->
        execute_messages(state, source, frame, version, messages)

      %{source: %{mfa: {Postgrex.Protocol, :ping, 1}} = callback} ->
        helper_copy(state, source, [2, 2, 1], messages, msg_sync(), {:ping_sync, callback.index})

      %{source: %{mfa: {Postgrex.Protocol, function, 2}} = callback} = frame
      when function in [:handle_begin, :handle_commit, :handle_rollback] ->
        transaction_messages(state, source, frame, callback, messages)

      %{source: %{mfa: {Postgrex.Protocol, function, 4}}} = frame
      when function in [:parse_describe_flush, :close_parse_describe_flush] ->
        prepare_messages(state, source, frame, messages)

      _ ->
        state
    end
  end

  defp helper_input(state, _source, _function, _arguments, _version), do: state

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
    values = fn position ->
      Map.fetch(state.term_values, {frame.source.index, [2, 2, position]})
    end

    with {:ok, %{value: query}} <- values.(2),
         {:ok, %{value: comment}} <- values.(3),
         {:ok, %{value: status}} <- values.(1) do
      statement =
        if is_binary(comment), do: [query.statement, "/*", comment, "*/"], else: query.statement

      messages = [
        msg_parse(name: query.name, statement: statement, type_oids: query.param_oids || []),
        msg_describe(type: :statement, name: query.name),
        msg_flush()
      ]

      messages =
        if elem(frame.source.mfa, 1) == :close_parse_describe_flush,
          do: [msg_close(type: :statement, name: query.name) | messages],
          else: messages

      messages =
        if status.mode == :savepoint,
          do: [msg_query(statement: "SAVEPOINT postgrex_query") | messages],
          else: messages

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
        failure(state, source, :state_helper_timeout_origin)
    end
  end

  defp helper_types(state, source, %{protocol: %{sock: {:gen_tcp, port}}}, actual) do
    execution = execution_origin(state, source, %{sock: {:gen_tcp, port}})

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

  defp execution_origin(state, source, %{sock: {:gen_tcp, port}}) do
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

  defp helper_decoder(state, source, %{sock: {:gen_tcp, port}}, kind) do
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
              :parse_describe_flush,
              :close_parse_describe_flush,
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
       when elem(source.mfa, 1) == :error_ready do
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
    with {:ok, %{value: tags, origin: origin}} <-
           Map.fetch(state.term_values, {call.index, [2, 2, 1]}) do
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
    else
      _ -> :error
    end
  end

  defp completion_result(state, source, %{source: call, input: protocol}) do
    values = fn position -> Map.fetch(state.term_values, {call.index, [2, 2, position]}) end

    with {:ok, %{value: query}} <- values.(1),
         {:ok, %{value: rows}} <- values.(2),
         %{tag: tag, index: index} <- command_origin(state, source, protocol) do
      {command, count} = command_tag(tag)
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
    first = callback_boundary(state, source)

    state.decoders.instances
    |> Enum.filter(fn instance ->
      {:gen_tcp, instance.port} == protocol.sock and instance.returned.pid == source.pid and
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
      {:gen_tcp, instance.port} == protocol.sock and instance.returned.pid == source.pid and
        instance.source.index > first and
        instance.returned.index < source.index and
        command_message?(instance.expected)
    end)
    |> List.last()
    |> case do
      %{expected: {:ok, {:msg_command_complete, tag}, _}, returned: returned} ->
        %{tag: tag, index: returned.index}

      %{expected: {:ok, {kind}, _}, returned: returned}
      when kind in [:msg_empty_query, :msg_portal_suspend] ->
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
    state
    |> put_in([:ports, version.protocol.sock], version)
    |> put_in([:completed, pid], version)
  end

  defp advance_owner(state, _pid, function, _version, _rest) when function in @copies,
    do: state

  defp advance_owner(state, pid, function, version, [parent | outer]) do
    parsed? = function in [:parse_describe_flush, :close_parse_describe_flush]

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

  defp returned_protocol(:describe, {_, _, %Postgrex.Protocol{} = protocol, _}),
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
      Enum.any?(source.stack, fn
        {Postgrex.Protocol, function, _} ->
          function in [:error_flushed, :rollback_flushed, :reload_flushed]

        _ ->
          false
      end)

    expected = if preserve?, do: protocol, else: %{protocol | buffer: nil}
    {state, expected}
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

  defp output_protocol(state, source, frame, function, result)
       when function in [:parse_describe_flush, :close_parse_describe_flush] do
    case result do
      {:ok, query, _protocol} ->
        case query_origin(state, frame) do
          %Postgrex.Query{} = expected_query ->
            _ = query
            protocol = %{frame.current | postgres: {frame.current.postgres, expected_query.ref}}
            {state, %{protocol | buffer: cursor_buffer(state, source, frame)}}

          nil ->
            {failure(state, source, :state_query_origin), frame.current}
        end

      _ ->
        {state, frame.current}
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
    if source.mfa == {Postgrex.Protocol, :redescribe, 6} do
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
      &({:gen_tcp, &1.port} == protocol.sock and &1.returned.pid == source.pid and
          &1.returned.index < source.index)
    )
    |> List.last()
  end

  defp cursor_version(state, source, %{sock: {:gen_tcp, port}}) do
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
