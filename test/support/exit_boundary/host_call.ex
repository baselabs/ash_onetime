defmodule AshOnetime.Test.ExitBoundary.HostCall do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.{External, Producer, ReturnedExternal}

  @calls [{Producer, :produce, 2}, {External, :execute, 3}, {ReturnedExternal, :execute, 3}]

  # Only the first declared host call owns its interior. The endpoints remain in
  # the transfer program, and a second host call owns no events or origins.
  def indexes(events) do
    case Enum.find(events, &(&1.mfa in @calls and elem(&1.event, 1) == :call)) do
      nil -> MapSet.new()
      start ->
        stop = Enum.find(events, &(&1.pid == start.pid and &1.index > start.index and
          &1.mfa == start.mfa and length(&1.stack) == length(start.stack) + 1 and
          elem(&1.event, 1) in [:return_from, :exception_from]))
        if stop do
          events |> Enum.filter(fn e ->
            e.pid == start.pid and e.index > start.index and e.index < stop.index and
              start.mfa in e.stack and not peer?(e)
          end) |> MapSet.new(& &1.index)
        else
          MapSet.new()
        end
    end
  end

  defp peer?(e), do: Enum.any?([e.mfa | e.stack], fn
    {AshOnetime.Test.ExternalPeer, _, _} -> true
    _ -> false
  end)
end
