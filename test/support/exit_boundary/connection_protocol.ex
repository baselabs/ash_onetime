defmodule AshOnetime.Test.ExitBoundary.ConnectionProtocol do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Wire

  # One machine per physical connection. Commands are queued when written, not
  # when a receive begins. Flush does not end an exchange; Sync does. Consequently
  # a receive may finish several operations or leave bytes for the next borrower.
  def build(frames, statements \\ %{}) do
    frames |> Enum.reduce(new(statements), &step/2) |> finish()
  end

  def new(statements \\ %{}) do
    %{
      statements: statements,
      portals: %{},
      pending: [],
      counts: %{},
      ordinal: 0,
      message_counts: %{},
      failed?: false,
      messages: [],
      errors: []
    }
  end

  def push(state, frame), do: step(frame, state)

  def cancellation(origin), do: Map.put(new(), :cancel, origin)

  def close_cancel(%{pending: [%{kind: :cancel}]} = state, {:error, :closed}),
    do: {:ok, %{state | pending: []}}

  def close_cancel(_state, _result), do: {:error, :cancel_close}

  def finish(state) do
    errors =
      case state.pending do
        [] ->
          state.errors

        pending ->
          error = %{rule: :protocol_incomplete, expected: Enum.map(pending, & &1.kind)}
          [error | state.errors]
      end

    %{state | messages: Enum.reverse(state.messages), errors: Enum.reverse(errors)}
  end

  def request(%{cancel: origin, pending: [%{kind: :cancel}]}, <<>>),
    do: {:ok, %{length: 0, timeout: origin.timeout}}

  def request(%{pending: []}, <<>>), do: {:error, :extra_read}

  def request(%{pending: []} = state, <<tag, _::binary>> = buffer) when tag in [?N, ?S, ?A],
    do: required_read(state, buffer)

  def request(%{pending: []}, _buffer), do: {:error, :no_frontend_origin}
  def request(state, buffer), do: required_read(state, buffer)

  defp required_read(state, buffer) do
    case Wire.frame_remaining(buffer) do
      0 when byte_size(buffer) >= 5 ->
        {:error, :complete_buffer}

      :invalid_length ->
        {:error, :frame_length}

      remaining ->
        {:ok, %{length: requested_length(state, buffer, remaining), timeout: :infinity}}
    end
  end

  defp requested_length(%{pending: [%{kind: :execute} | _]}, <<?D, _::binary>>, _remaining),
    do: 0

  defp requested_length(_state, _buffer, remaining), do: min(remaining, 64 * 1024 * 1024)

  defp step(frame, state) do
    case frame.direction do
      :frontend -> frontend(frame, state)
      :backend -> backend(frame, state)
    end
  rescue
    error in [ArgumentError, MatchError, KeyError, FunctionClauseError] ->
      fail(state, frame, :protocol_message, error.__struct__, :valid_protocol_instance)
  end

  defp frontend(
         %{tag: :startup, payload: <<80_877_102::32, backend::signed-32, key::signed-32>>} = frame,
         %{cancel: origin, pending: [], message_counts: counts} = state
       )
       when not is_map_key(counts, :frontend) do
    state =
      state
      |> enqueue(:cancel, nil)
      |> emit(frame, {:cancel_request, backend, key}, nil)

    if {backend, key} === {origin.backend, origin.key} do
      state
    else
      fail(state, frame, :cancel_identity, :foreign_cancel_identity, :bound_native_connection)
    end
  end

  defp frontend(%{tag: ?P, payload: payload} = frame, state) do
    {name, rest} = string(payload)
    {sql, <<count::16, oids::binary>>} = string(rest)
    types = for <<oid::32 <- oids>>, do: oid
    true = byte_size(oids) == count * 4
    {context, state} = context(state, frame, sql)
    context = context |> Map.put(:parameter_types, types) |> Map.put(:name, name)
    state = enqueue(state, :parse, context)
    emit(state, frame, {:parse, name, sql, count, types}, context)
  end

  defp frontend(%{tag: ?D, payload: <<kind, rest::binary>>} = frame, state)
       when kind in [?S, ?P] do
    {name, <<>>} = string(rest)
    {context, operation} = described(state, kind, name)
    state = enqueue(state, operation, Map.put(context, :name, name))
    emit(state, frame, {:describe, frame.payload}, context)
  end

  defp frontend(%{tag: ?B, payload: payload} = frame, state) do
    {portal, rest} = string(payload)
    {name, _} = string(rest)
    prepared = statement(state, name)
    {context, state} = context(state, frame, prepared.sql)
    context = %{context | parameter_types: prepared.parameter_types, columns: prepared.columns}
    context = Map.put(context, :description, Map.fetch!(prepared, :description))
    {decoded, context} = decode(frame, context)
    {:bind, ^portal, ^name, _formats, params, _result_formats} = decoded
    true = length(params) == length(prepared.parameter_types)
    context = Map.put(context, :portal, portal)
    state = enqueue(state, :bind, context)
    emit(state, frame, decoded, context)
  end

  defp frontend(%{tag: ?E, payload: payload} = frame, state) do
    {portal, <<_max_rows::32>>} = string(payload)
    context = portal(state, portal)
    state = enqueue(state, :execute, context)
    emit(state, frame, {:exact_payload, ?E, payload}, context)
  end

  defp frontend(%{tag: ?C, payload: <<kind, rest::binary>>} = frame, state)
       when kind in [?S, ?P] do
    {name, <<>>} = string(rest)
    {context, state} = context(state, frame, nil)
    context = context |> Map.put(:close_kind, kind) |> Map.put(:close_name, name)
    state = enqueue(state, :close, context)
    emit(state, frame, {:exact_payload, ?C, frame.payload}, context)
  end

  defp frontend(%{tag: ?Q, payload: payload} = frame, state) do
    {sql, <<>>} = string(payload)
    {context, state} = context(state, frame, sql)
    state = enqueue(state, :simple, context)
    emit(state, frame, {:query, sql}, context)
  end

  defp frontend(%{tag: ?S, payload: <<>>} = frame, state) do
    {context, state} = context(state, frame, nil)
    state = enqueue(state, :sync, context)
    emit(state, frame, {:exact_payload, ?S, <<>>}, context)
  end

  defp frontend(%{tag: tag, payload: <<>>} = frame, state) when tag in [?H, ?X],
    do: emit(state, frame, {:exact_payload, tag, <<>>}, nil)

  defp frontend(%{tag: tag} = frame, state) when tag in [?d, ?c, ?f] do
    operation = List.first(state.pending)
    true = operation.kind in [:execute, :simple]
    emit(state, frame, {:exact_payload, tag, frame.payload}, operation.context)
  end

  defp frontend(frame, state),
    do: fail(state, frame, :frontend_message, frame.tag, :declared_frontend_protocol)

  defp backend(%{tag: tag} = frame, state) when tag in [?N, ?S, ?A],
    do: emit(state, frame, {:exact_payload, tag, frame.payload}, nil)

  defp backend(%{tag: ?E} = frame, %{pending: [operation | _]} = state) do
    # Extended protocol discards commands through Sync after an error. A simple
    # query instead remains pending through its own ReadyForQuery.
    pending = if operation.kind == :simple, do: state.pending, else: error_tail(state.pending)
    state = %{state | pending: pending, failed?: operation.kind != :simple}
    emit(state, frame, {:exact_payload, ?E, frame.payload}, operation.context, operation)
  end

  defp backend(%{tag: ?Z, payload: <<status>>} = frame, %{pending: [operation | rest]} = state)
       when status in [?I, ?T, ?E] and operation.kind in [:sync, :simple] do
    state = %{state | pending: rest, failed?: false}
    emit(state, frame, {:exact_payload, ?Z, frame.payload}, operation.context, operation)
  end

  defp backend(%{tag: ?1, payload: <<>>} = frame, state),
    do: complete(state, frame, :parse)

  defp backend(%{tag: ?2, payload: <<>>} = frame, state),
    do: complete(state, frame, :bind)

  defp backend(%{tag: ?3, payload: <<>>} = frame, state),
    do: complete(state, frame, :close)

  defp backend(
         %{tag: ?t} = frame,
         %{pending: [%{kind: :describe_statement} = op | rest]} = state
       ) do
    {decoded, context} = decode(frame, op.context)
    {:parameter_description, count, types} = decoded
    true = count == length(types) and byte_size(frame.payload) == 2 + count * 4
    context = %{context | parameter_types: types}
    state = put_in(state.statements[context.name], Map.delete(context, :name))
    op = %{op | kind: :describe_row, context: context}
    emit(%{state | pending: [op | rest]}, frame, decoded, context, op)
  end

  defp backend(%{tag: tag} = frame, %{pending: [op | rest]} = state)
       when tag in [?T, ?n] and op.kind in [:describe_row, :describe_portal, :simple] do
    {decoded, context} = decode(frame, op.context)
    state = save_description(state, op.kind, context)
    pending = if op.kind == :simple, do: [%{op | context: context} | rest], else: rest
    emit(%{state | pending: pending}, frame, decoded, context, op)
  end

  defp backend(%{tag: ?D} = frame, %{pending: [op | _]} = state)
       when op.kind in [:execute, :simple] do
    {decoded, context} = decode(frame, op.context)
    emit(state, frame, decoded, context, op)
  end

  defp backend(%{tag: tag} = frame, %{pending: [op | rest]} = state)
       when tag in [?C, ?I, ?s] and op.kind in [:execute, :simple] do
    pending = if op.kind == :simple, do: state.pending, else: rest
    emit(%{state | pending: pending}, frame, {:exact_payload, tag, frame.payload}, op.context, op)
  end

  defp backend(%{tag: tag} = frame, %{pending: [op | _]} = state)
       when tag in [?G, ?H, ?W, ?d, ?c] and op.kind in [:execute, :simple],
       do: emit(state, frame, {:exact_payload, tag, frame.payload}, op.context, op)

  defp backend(frame, state),
    do: fail(state, frame, :protocol_association, frame.tag, pending_kind(state))

  defp described(state, ?S, name),
    do: {statement(state, name), :describe_statement}

  defp described(state, ?P, name),
    do: {portal(state, name), :describe_portal}

  defp statement(state, name),
    do: pending_context(state, :parse, :name, name, :statements)

  defp portal(state, name),
    do: pending_context(state, :bind, :portal, name, :portals)

  defp pending_context(state, kind, key, name, table) do
    pending =
      state.pending
      |> Enum.reverse()
      |> Enum.find(fn operation ->
        operation.kind == kind and Map.get(operation.context, key) == name
      end)

    if pending, do: pending.context, else: Map.fetch!(Map.fetch!(state, table), name)
  end

  defp save_description(state, :describe_row, context),
    do: put_in(state.statements[context.name], Map.delete(context, :name))

  defp save_description(state, :describe_portal, context),
    do: put_in(state.portals[context.name], Map.delete(context, :name))

  defp save_description(state, :simple, _context), do: state

  # After an extended-query failure PostgreSQL skips every frontend message
  # until Sync, including a queued simple Query. Its raw frame remains emitted;
  # it owns no backend reply. A simple-query error keeps its own ReadyForQuery.
  defp error_tail([%{kind: :sync} | _] = pending), do: pending
  defp error_tail([_ | rest]), do: error_tail(rest)
  defp error_tail([]), do: []

  defp complete(%{pending: [%{kind: kind} = op | rest]} = state, frame, kind) do
    state = complete_catalog(state, kind, op.context)
    emit(%{state | pending: rest}, frame, {:exact_payload, frame.tag, <<>>}, op.context, op)
  end

  defp complete(state, frame, kind),
    do: fail(state, frame, :protocol_association, pending_kind(state), kind)

  defp complete_catalog(state, :parse, context),
    do: put_in(state.statements[context.name], Map.delete(context, :name))

  defp complete_catalog(state, :bind, context),
    do: put_in(state.portals[context.portal], Map.delete(context, :portal))

  defp complete_catalog(state, :close, context) do
    table = if context.close_kind == ?S, do: :statements, else: :portals
    Map.update!(state, table, &Map.delete(&1, context.close_name))
  end

  defp context(state, frame, sql) do
    phase = Map.get(frame, :phase, :shared)
    ordinal = Map.get(state.counts, phase, 0) + 1

    context = %{
      sql: sql,
      statement: {:wire_statement, phase, ordinal},
      parameter_types: [],
      columns: [],
      description: :unknown,
      binds: [],
      counts: %{},
      annotation_phase: phase,
      direction: frame.direction
    }

    {context, put_in(state.counts[phase], ordinal)}
  end

  defp enqueue(state, kind, context) do
    op = %{
      kind: kind,
      context: context,
      ordinal: state.ordinal,
      request: Map.get(state.message_counts, :frontend, 0)
    }

    pending = state.pending ++ [op]
    pending = if state.failed?, do: error_tail(pending), else: pending
    %{state | pending: pending, ordinal: state.ordinal + 1}
  end

  defp decode(frame, context),
    do: Wire.decode_message(frame.tag, frame.payload, %{context | direction: frame.direction})

  defp emit(state, frame, decoded, context, operation \\ nil) do
    association = if operation, do: {operation.kind, operation.ordinal}, else: :frontend
    ordinal = Map.get(state.message_counts, frame.direction, 0)

    # A reply belongs to the frontend message that queued its protocol
    # operation, including Describe/Execute's inherited statement context.
    # Native receive positions never identify a request.
    request =
      cond do
        operation -> operation.request
        frame.direction == :frontend and context != nil -> ordinal
        true -> nil
      end

    message =
      frame
      |> Map.put(:decoded, decoded)
      |> Map.put(:association, association)
      |> Map.put(:request, request)
      |> Map.put(:sql, if(context, do: context.sql))
      |> Map.put(:statement, if(context, do: context.statement))
      |> Map.put(:context, context)
      |> Map.put(:message_ordinal, ordinal)

    %{
      state
      | messages: [message | state.messages],
        message_counts: Map.put(state.message_counts, frame.direction, ordinal + 1)
    }
  end

  defp pending_kind(%{pending: [operation | _]}), do: operation.kind
  defp pending_kind(_state), do: :no_frontend_origin

  defp fail(state, frame, rule, actual, expected) do
    error = %{
      rule: rule,
      direction: frame.direction,
      offset: frame.start,
      actual: actual,
      expected: expected
    }

    %{state | errors: [error | state.errors]}
  end

  defp string(bytes) do
    {size, 1} = :binary.match(bytes, <<0>>)
    <<value::binary-size(^size), 0, rest::binary>> = bytes
    {value, rest}
  end
end
