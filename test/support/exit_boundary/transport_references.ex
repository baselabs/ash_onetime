defmodule AshOnetime.Test.ExitBoundary.TransportReferences do
  alias AshOnetime.Test.ExitBoundary.Capture
  @moduledoc false

  # inet_drv's asynchronous receive id is created by TCP_REQ_RECV. Its two
  # octets are opaque only at this command's return and its documented copies.
  def build(indexed, readback \\ MapSet.new()) do
    initial = %{active: %{}, counts: %{}, origins: %{}, errors: [], readback: readback}
    {events, state} = Enum.map_reduce(indexed.events, initial, &event/2)

    events = Enum.map(events, &rewrite_copy(&1, state.origins))

    errors =
      for %{event: event} = e <- events,
          id =
            (case event do
               {_, :receive, {:inet_async, _, id, _}} when is_integer(id) -> id
               {_, :send, {:inet_async, _, id, _}, _} when is_integer(id) -> id
               _ -> nil
             end),
          id != nil,
          do: %{
            at: Map.take(e, [:mfa, :role, :stack]),
            index: e.index,
            rule: :driver_reference,
            actual: id,
            expected: :paired_receive_command
          }

    %{events: events, errors: Enum.reverse(state.errors) ++ errors}
  end

  defp rewrite_copy(%{event: {pid, :receive, {:inet_async, port, id, result}}} = e, origins)
       when is_integer(id),
       do:
         rewrite_origin(e, origins, port, id, fn frame ->
           {pid, :receive, {:inet_async, port, token(frame), result}}
         end)

  defp rewrite_copy(%{event: {port, :send, {:inet_async, port, id, result}, to}} = e, origins)
       when is_integer(id),
       do:
         rewrite_origin(e, origins, port, id, fn frame ->
           {port, :send, {:inet_async, port, token(frame), result}, to}
         end)

  defp rewrite_copy(%{event: {port, :send, {port, {:control, <<1, hi, lo>>}}, to}} = e, origins),
    do:
      rewrite_origin(e, origins, port, hi * 256 + lo, fn frame ->
        {port, :send, {port, {:control, [1, token(frame), :low_octet]}}, to}
      end)

  defp rewrite_copy(e, _origins), do: e

  defp rewrite_origin(e, origins, port, id, build) do
    case Map.fetch(origins, {port, id}) do
      {:ok, frame} -> %{e | event: build.(frame)}
      :error -> e
    end
  end

  defp event(%{event: {pid, :call, {:prim_inet, :async_recv, [port, _, _]}}} = e, state) do
    phase = if MapSet.member?(state.readback, Capture.address(e)), do: :committed_read, else: :shared
    n = Map.get(state.counts, {e.role, port, phase}, 0)
    frame = %{port: port, phase: phase, ordinal: n, source: nil}

    {e,
     %{
       state
       | active: Map.put(state.active, pid, frame),
         counts: Map.put(state.counts, {e.role, port, phase}, n + 1)
     }}
  end

  defp event(
         %{event: {pid, :return_from, {:erts_internal, :port_control, 3}, [1, hi, lo]}} = e,
         state
       ) do
    case Map.get(state.active, pid) do
      %{source: nil} = frame ->
        frame = %{frame | source: {hi, lo}}
        state = put_in(state.active[pid], frame)
        state = put_in(state.origins[{frame.port, hi * 256 + lo}], frame)
        {replace_return(e, [1, token(frame), :low_octet]), state}

      _ ->
        {e, state}
    end
  end

  defp event(%{event: {pid, :return_from, mfa, value}} = e, state)
       when mfa in [
              {:erlang, :port_control, 3},
              {:prim_inet, :ctl_cmd, 3},
              {:prim_inet, :async_recv, 3}
            ] do
    case Map.get(state.active, pid) do
      %{source: {hi, lo}} = frame ->
        {expected, replacement} =
          case mfa do
            {:erlang, :port_control, 3} -> {[1, hi, lo], [1, token(frame), :low_octet]}
            {:prim_inet, :ctl_cmd, 3} -> {{:ok, [hi, lo]}, {:ok, [token(frame), :low_octet]}}
            {:prim_inet, :async_recv, 3} -> {{:ok, hi * 256 + lo}, {:ok, token(frame)}}
          end

        state = check(state, e, value, expected)

        state =
          if mfa == {:prim_inet, :async_recv, 3},
            do: %{state | active: Map.delete(state.active, pid)},
            else: state

        {if(value === expected, do: replace_return(e, replacement), else: e), state}

      _ ->
        {e, state}
    end
  end

  defp event(%{event: {pid, :receive, {:inet_async, port, id, result}}} = e, state) do
    case Map.fetch(state.origins, {port, id}) do
      {:ok, frame} ->
        {%{e | event: {pid, :receive, {:inet_async, port, token(frame), result}}}, state}

      :error ->
        {e, state}
    end
  end

  defp event(%{event: {port, :send, {:inet_async, port, id, result}, to}} = e, state) do
    case Map.fetch(state.origins, {port, id}) do
      {:ok, frame} ->
        {%{e | event: {port, :send, {:inet_async, port, token(frame), result}, to}}, state}

      :error ->
        {e, state}
    end
  end

  defp event(e, state), do: {e, state}
  defp token(frame), do: {:inet_receive_reference, frame.port, frame.phase, frame.ordinal}

  defp replace_return(%{event: {pid, tag, mfa, _}} = e, value),
    do: %{e | event: {pid, tag, mfa, value}}

  defp check(state, _e, a, b) when a === b, do: state

  defp check(state, e, actual, expected),
    do: %{
      state
      | errors: [
          %{
            at: Map.take(e, [:mfa, :role, :stack]),
            index: e.index,
            rule: :driver_reference,
            actual: actual,
            expected: expected
          }
          | state.errors
        ]
    }
end
