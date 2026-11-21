defmodule AshOnetime.Test.ExitBoundary.HostCall do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.{External, Producer, ReturnedExternal}

  @calls [{Producer, :produce, 2}, {External, :execute, 3}, {ReturnedExternal, :execute, 3}]

  # Only the first declared host call owns its interior. The endpoints remain in
  # the transfer program, and a second host call owns no events or origins.
  def indexes(events) do
    case Enum.find(events, &(&1.mfa in @calls and elem(&1.event, 1) == :call)) do
      nil ->
        MapSet.new()

      start ->
        stop = Enum.find(events, &host_return?(&1, start))
        interior(events, start, stop)
    end
  end

  defp host_return?(event, start),
    do: event.pid == start.pid and event.index > start.index and
          event.mfa == start.mfa and length(event.stack) == length(start.stack) + 1 and
          elem(event.event, 1) in [:return_from, :exception_from]

  defp interior(_events, _start, nil), do: MapSet.new()

  defp interior(events, start, stop) do
    events
    |> Enum.filter(fn e ->
      e.pid == start.pid and e.index > start.index and e.index < stop.index and
        start.mfa in e.stack and not peer?(e)
    end)
    |> MapSet.new(& &1.index)
  end

  defp peer?(e),
    do:
      Enum.any?([e.mfa | e.stack], fn
        {AshOnetime.Test.ExternalPeer, _, _} -> true
        _ -> false
      end)
end
