defmodule AshOnetime.Test.ExitBoundary.Scheduling do
  alias AshOnetime.Test.ExitBoundary.Capture
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Registry

  # Signal arrival is a scheduling choice; its source and payload are not. Each
  # alternative below consumes a complete protocol instance and keeps its source
  # event. Unmatched events stay in the ordinary per-role comparison.
  def build(indexed) do
    events = indexed.events
    state = %{claimed: MapSet.new(), moves: %{}, rewrites: %{}, errors: []}

    state = Enum.reduce(events, state, &schedule(&1, &2, events))

    # Move only validated scheduling signals. Their complete payloads continue to
    # compare at the fixed anchor; all other event order is untouched.
    moved = MapSet.new(for {_anchor, signals} <- state.moves, signal <- signals, do: Capture.address(signal))

    result =
      Enum.flat_map(events, fn e ->
        if MapSet.member?(state.claimed, Capture.address(e)) or MapSet.member?(moved, Capture.address(e)) do
          []
        else
          e = Map.get(state.rewrites, Capture.address(e), e)
          before = Map.get(state.moves, {:before, Capture.address(e)}, [])
          after_events = Map.get(state.moves, {:after, Capture.address(e)}, [])
          before ++ [e] ++ after_events
        end
      end)

    %{events: result, errors: Enum.reverse(state.errors)}
  end

  defp schedule(%{event: {caller, :return_from, {:erts_internal, f, 3}, ref}} = e, s, events)
       when f in [:port_command, :port_control] and is_reference(ref),
       do: deferred(e, caller, f, ref, events, s)

  defp schedule(%{event: {caller, :receive, {:inet_async, port, id, result}}} = e, s, events),
    do: async(e, caller, port, id, result, events, s)

  defp schedule(
         %{event: {caller, :call, {:prim_inet, :send, [port, data, _options, ref]}}} = e,
         s,
         events
       )
       when is_port(port) and is_reference(ref),
       do: inet(e, caller, port, data, ref, events, s)

  defp schedule(
         %{
           event:
             {parent, :send, {parent, ref, ref, [parent], {:erlang, :apply, [fun, []]}} = message,
              child}
         } = e,
         s,
         events
       )
       when is_function(fun),
       do: task(e, parent, child, message, events, s)

  defp schedule(%{event: {parent, :getting_unlinked, child}} = e, s, events),
    do: unlinked(e, parent, child, events, s)

  defp schedule(
         %{event: {caller, :call, {:erts_internal, :flush_monitor_messages, [ref, false, true]}}} =
           e,
         s,
         events
       ),
       do: flush(e, caller, ref, events, s)

  defp schedule(
         %{event: {caller, :receive, {:DOWN, ref, :process, child, reason}}} = e,
         s,
         events
       ),
       do: down(e, caller, ref, child, reason, events, s)

  defp schedule(_e, s, _events), do: s

  defp deferred(source, caller, f, ref, events, s) do
    [:immediate_result, :reference_then_same_result] =
      Registry.scheduling(:deferred_port, :command_reply)

    call =
      previous(events, source, fn
        %{event: {^caller, :call, {:erts_internal, ^f, [port, _, _]}}} -> is_port(port)
        _ -> false
      end)

    with %{event: {_, _, {_, _, [port, _, _]}}} <- call,
         [received] <-
           select(events, fn
             %{event: {^caller, :receive, {^ref, _}}} -> true
             _ -> false
           end),
         {_, :receive, {^ref, result}} <- received.event,
         sent <-
           select(events, fn
             %{event: {^port, :send, {^ref, _}, ^caller}} -> true
             _ -> false
           end),
         true <-
           sent == [] or Enum.map(sent, & &1.event) == [{port, :send, {ref, result}, caller}],
         %{event: {_, _, _, ^result}} <-
           following(
             events,
             source,
             &match?(%{event: {^caller, :return_from, {:erlang, ^f, 3}, _}}, &1)
           ) do
      s = Enum.reduce(sent, s, &claim(&2, &1))

      s
      |> claim(received)
      |> put_in([:rewrites, Capture.address(source)], %{
        source
        | event: {caller, :return_from, {:erts_internal, f, 3}, result}
      })
    else
      _ -> failure(s, source, :deferred_port, :incomplete, :same_command_reply)
    end
  end

  defp inet(source, caller, port, data, ref, events, s) do
    [:reply_before_return, :reply_at_return] = Registry.scheduling(:inet_reply, :command_reply)

    with [sent] <-
           select(events, fn
             %{event: {^port, :send, {:inet_reply, ^port, _, ^ref}, ^caller}} -> true
             _ -> false
           end),
         {_, :send, message, _} <- sent.event,
         [received] <- select(events, &(&1.event == {caller, :receive, message})),
         %{event: {_, _, _, status}} = returned <-
           following(
             events,
             source,
             &match?(%{event: {^caller, :return_from, {:prim_inet, :send, 4}, _}}, &1)
           ),
         {:inet_reply, ^port, ^status, ^ref} <- message,
         command when not is_nil(command) <-
           Enum.find(events, fn
             %{event: {^port, :receive, {^caller, {:command, bytes}}}} ->
               IO.iodata_to_binary(bytes) == IO.iodata_to_binary(data)

             _ ->
               false
           end) do
      s |> move(received, {:before, Capture.address(returned)}) |> move(sent, {:after, Capture.address(command)})
    else
      _ -> failure(s, source, :inet_reply, :incomplete, :same_port_monitor_and_status)
    end
  end

  defp async(source, caller, port, id, result, events, s) do
    [:reply_before_recv0_return, :reply_at_recv0_return] =
      Registry.scheduling(:inet_async, :receive_command_reply)

    with [sent] <-
           select(events, &(&1.event == {port, :send, {:inet_async, port, id, result}, caller})),
         %{} = call <-
           previous(
             events,
             source,
             &match?(%{event: {^caller, :call, {:prim_inet, :async_recv, [^port, _, _]}}}, &1)
           ),
         %{} <-
           Enum.find(
             events,
             &match?(
               %{event: {^caller, :return_from, {:prim_inet, :async_recv, 3}, {:ok, ^id}}},
               &1
             )
           ),
         %{event: {_, _, _, ^result}} = anchor <-
           following(
             events,
             call,
             &match?(%{event: {^caller, :return_from, {:prim_inet, :recv0, 3}, _}}, &1)
           ) do
      s = move(s, source, {:before, Capture.address(anchor)})

      controls =
        select(events, fn
          %{event: {^port, :send, {^port, {:control, <<1, hi, lo>>}}, ^caller}} ->
            hi * 256 + lo == id

          _ ->
            false
        end)

      case controls do
        [control] -> move(s, control, {:before, Capture.address(sent)})
        [] -> s
        _ -> failure(s, source, :inet_async, :duplicate_control, :one_origin)
      end
    else
      _ -> s
    end
  end

  defp task(source, parent, child, message, events, s) do
    [:startup_after_spawned, :startup_at_spawned] =
      Registry.scheduling(:task_startup, :spawn_send_receive)

    with %{event: {^parent, :spawn, ^child, _}} <-
           Enum.find(events, &match?(%{event: {^parent, :spawn, ^child, _}}, &1)),
         [received] <- select(events, &(&1.event == {child, :receive, message})),
         %{event: {^child, :spawned, ^parent, _}} = spawned <-
           Enum.find(events, &match?(%{event: {^child, :spawned, ^parent, _}}, &1)) do
      move(s, received, {:after, Capture.address(spawned)})
    else
      _ -> failure(s, source, :task_startup, :incomplete, :spawn_send_receive)
    end
  end

  defp unlinked(source, parent, child, events, s) do
    [:unlink_before_flush, :unlink_at_flush] =
      Registry.scheduling(:task_unlink, :monitored_child_exit)

    with true <-
           Enum.any?(events, fn
             %{event: {^child, :call, {:erlang, :unlink, [^parent]}}} -> true
             %{event: {^child, :exit, :normal}} -> true
             _ -> false
           end),
         %{ref: ref, source: monitor} <- monitor(events, parent, child),
         %{} = demonitor <-
           following(
             events,
             monitor,
             &match?(%{event: {^parent, :call, {:erlang, :demonitor, [^ref, [:flush]]}}}, &1)
           ),
         %{} = anchor <-
           following(
             events,
             demonitor,
             &match?(%{event: {^parent, :return_from, {:erlang, :demonitor, 2}, true}}, &1)
           ) do
      move(s, source, {:after, Capture.address(anchor)})
    else
      _ -> s
    end
  end

  defp down(source, caller, ref, child, reason, events, s) do
    [:received_and_flushed, :absent_and_flushed] =
      Registry.scheduling(:down_flush, :demonitor_flush)

    with %{child: ^child, source: origin} <- monitor_reference(events, caller, ref),
         true <- origin.index < source.index,
         %{} = demonitor <-
           following(
             events,
             source,
             &match?(%{event: {^caller, :call, {:erlang, :demonitor, [^ref, [:flush]]}}}, &1)
           ),
         %{} <-
           following(
             events,
             demonitor,
             &match?(%{event: {^caller, :return_from, {:erlang, :demonitor, 2}, true}}, &1)
           ),
         true <- Enum.any?(events, &match?(%{event: {^child, :exit, ^reason}}, &1)) do
      claim(s, source)
    else
      _ -> s
    end
  end

  defp flush(source, caller, ref, events, s) do
    [:received_and_flushed, :absent_and_flushed] =
      Registry.scheduling(:down_flush, :demonitor_flush)

    with %{} = demonitor <-
           previous(
             events,
             source,
             &match?(%{event: {^caller, :call, {:erlang, :demonitor, [^ref, [:flush]]}}}, &1)
           ),
         %{source: origin} <- monitor_reference(events, caller, ref),
         true <- origin.index < demonitor.index,
         %{event: {_, :return_from, _, true}} = returned <-
           following(
             events,
             source,
             &match?(
               %{event: {^caller, :return_from, {:erts_internal, :flush_monitor_messages, 3}, _}},
               &1
             )
           ) do
      s |> claim(source) |> claim(returned)
    else
      _ -> failure(s, source, :monitor_flush, :incomplete, :paired_monitor_flush_true)
    end
  end

  defp monitor(events, parent, child) do
    Enum.find_value(events, fn
      %{event: {^parent, :return_from, {:erlang, function, _}, {^child, ref}}} = e
      when function in [:spawn_opt, :spawn_monitor] and is_reference(ref) ->
        %{ref: ref, source: e}

      %{event: {^parent, :call, {:erlang, :monitor, [:process, ^child | _]}}} = e ->
        case following(
               events,
               e,
               &match?(%{event: {^parent, :return_from, {:erlang, :monitor, _}, _}}, &1)
             ) do
          %{event: {_, _, _, ref}} -> %{ref: ref, source: e}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp monitor_reference(events, parent, ref) do
    Enum.find_value(events, fn
      %{event: {^parent, :return_from, {:erlang, function, _}, {child, ^ref}}} = e
      when function in [:spawn_opt, :spawn_monitor] ->
        %{ref: ref, child: child, source: e}

      %{event: {^parent, :return_from, {:erlang, :monitor, arity}, ^ref}} = e
      when arity in [2, 3] ->
        case previous(events, e, &monitor_call?(&1, parent, arity)) do
          %{event: {_, :call, {_, _, [:process, child | _]}}} ->
            %{ref: ref, child: child, source: e}

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp monitor_call?(%{event: {parent, :call, {:erlang, :monitor, arguments}}}, parent, arity),
    do: length(arguments) == arity

  defp monitor_call?(_event, _parent, _arity), do: false

  defp select(events, predicate), do: Enum.filter(events, predicate)

  defp previous(events, source, predicate),
    do:
      events
      |> Enum.take_while(&(&1.index < source.index))
      |> Enum.reverse()
      |> Enum.find(predicate)

  defp following(events, source, predicate),
    do: events |> Enum.drop_while(&(&1.index <= source.index)) |> Enum.find(predicate)

  defp claim(s, e), do: %{s | claimed: MapSet.put(s.claimed, Capture.address(e))}
  defp move(s, e, anchor), do: %{s | moves: Map.update(s.moves, anchor, [e], &(&1 ++ [e]))}

  defp failure(s, e, rule, actual, expected),
    do: %{
      s
      | errors: [
          %{
            index: e.index,
            at: Map.take(e, [:mfa, :role, :stack]),
            rule: rule,
            actual: actual,
            expected: expected
          }
          | s.errors
        ]
    }
end
