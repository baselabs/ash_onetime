defmodule AshOnetime.Test.ExitBoundary.ConnectionHistory do
  @moduledoc false
  use GenServer
  import Postgrex.Messages,
    only: [msg_parameter_desc: 1, msg_row_desc: 1, msg_no_data: 0, row_field: 1]

  # Start before the fixture opens its pools. Only successful native prepare
  # returns and their own server descriptions can create a historical descriptor.
  # Opaque decoder types are retained as the Query their owner returned.
  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  def snapshot do
    case Process.get({__MODULE__, :pid}) do
      nil -> raise "the connection history observer was not started"
      pid -> GenServer.call(pid, :snapshot, 30_000)
    end
  end

  @impl true
  def init(owner) do
    Process.flag(:trap_exit, true)
    Code.ensure_loaded!(Postgrex.Protocol)
    session = :trace.session_create(:ash_onetime_connection_history, self(), [])

    for function <- [:handle_prepare, :msg_recv] do
      :trace.function(
        session,
        {Postgrex.Protocol, function, :_},
        [{:_, [], [{:exception_trace}]}],
        [:local]
      )
    end

    flags = [:call, :procs, :strict_monotonic_timestamp]
    :trace.process(session, :new, true, flags)
    1 = :trace.process(session, owner, true, flags)
    {:ok, %{session: session, events: [], frames: %{}, origins: %{}, waiting: %{}}}
  end

  @impl true
  def handle_call(:snapshot, from, state) do
    fence = :trace.delivered(state.session, :all)
    {:noreply, put_in(state.waiting[fence], from)}
  end

  @impl true
  def handle_info({:trace_delivered, :all, fence}, state) do
    {from, waiting} = Map.pop(state.waiting, fence)
    state = Enum.reduce(Enum.sort_by(state.events, &elem(&1, 0)), state, &record/2)
    if from, do: GenServer.reply(from, Map.values(state.origins))
    {:noreply, %{state | events: [], waiting: waiting}}
  end

  def handle_info(message, state) when is_tuple(message) and elem(message, 0) == :trace_ts do
    [_tag | fields] = Tuple.to_list(message)
    {fields, [stamp]} = Enum.split(fields, -1)

    # Select named fields before retaining anything. Authentication messages,
    # protocol credentials, execution values and exception reasons are not kept.
    case select(List.to_tuple(fields)) do
      nil -> {:noreply, state}
      event -> {:noreply, %{state | events: [{stamp, event} | state.events]}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _value} -> {:log, []}
      {key, _value} when key in [:state, :message, :reason] -> {key, :native_connection_history}
      entry -> entry
    end)
  end

  @impl true
  def terminate(_reason, state), do: :trace.session_destroy(state.session)

  defp select({pid, :call, {Postgrex.Protocol, :handle_prepare, [_query, _opts, %{sock: sock}]}}),
    do: {pid, :prepare, sock}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :handle_prepare, 3},
          {:ok, %Postgrex.Query{} = query, %{sock: sock}}}
       ),
       do: {pid, :prepared, {sock, query}}

  defp select({pid, tag, {Postgrex.Protocol, :handle_prepare, 3}, _result})
       when tag in [:return_from, :exception_from],
       do: {pid, :refused, nil}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :msg_recv, arity},
          {:ok, msg_parameter_desc(type_oids: oids), _buffer}}
       ),
       do: {pid, :parameters, {arity, oids}}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :msg_recv, arity},
          {:ok, msg_row_desc(fields: fields), _buffer}}
       ),
       do: {pid, :columns, {arity, columns(fields)}}

  defp select(
         {pid, :return_from, {Postgrex.Protocol, :msg_recv, arity},
          {:ok, msg_no_data(), _buffer}}
       ),
       do: {pid, :columns, {arity, []}}

  defp select({pid, :exit, _reason}), do: {pid, :exit, nil}
  defp select(_event), do: nil

  defp columns(fields) do
    for row_field(
          name: name,
          table_oid: table,
          column: number,
          type_oid: oid,
          type_size: width,
          type_mod: modifier,
          format: format
        ) <- fields,
        do: {name, {:table_oid, table}, number, oid, width, modifier, format}
  end

  defp record({_stamp, {pid, :prepare, sock}}, state) do
    frames = Map.get(state.frames, pid, [])
    put_in(state.frames[pid], [%{sock: sock} | frames])
  end

  defp record({stamp, {pid, kind, {arity, value}}}, state)
       when kind in [:parameters, :columns] do
    case Map.get(state.frames, pid, []) do
      [frame | rest] ->
        origin = %{index: {:historical, stamp}, mfa: {Postgrex.Protocol, :msg_recv, arity}}
        frame = Map.put_new(frame, kind, value) |> Map.put_new({:origin, kind}, origin)
        put_in(state.frames[pid], [frame | rest])

      [] ->
        state
    end
  end

  defp record({stamp, {pid, :prepared, {sock, query}}}, state) do
    {frame, state} = pop(state, pid)
    key = {sock, query.name}

    case frame do
      %{sock: ^sock, parameters: parameters, columns: columns} ->
        origin = %{
          index: {:historical, stamp},
          mfa: {Postgrex.Protocol, :handle_prepare, 3},
          path: [3, 1],
          sock: sock,
          query: query,
          parameters: parameters,
          columns: columns,
          description_origins: Map.take(frame, [{:origin, :parameters}, {:origin, :columns}])
        }

        put_in(state.origins[key], origin)

      _ ->
        # A cached return supplies no new server facts. Its original successful
        # preparation remains the descriptor's origin.
        state
    end
  end

  defp record({_stamp, {pid, :refused, _}}, state), do: elem(pop(state, pid), 1)
  defp record({_stamp, {pid, :exit, _}}, state),
    do: %{state | frames: Map.delete(state.frames, pid)}

  defp pop(state, pid) do
    case Map.get(state.frames, pid, []) do
      [frame | rest] -> {frame, put_in(state.frames[pid], rest)}
      [] -> {nil, state}
    end
  end
end
