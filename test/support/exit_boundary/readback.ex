defmodule AshOnetime.Test.ExitBoundary.Readback do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.{ClockExpressions, Comparator, Historical, Origins}
  @root {AshOnetime.Store, :committed_completion, 2}

  # OPEN's read is checked against a second real, read-only execution with the
  # already-bound target and admission row. It has no delivery dictionary, producer
  # or delivered values. This is a reference computation over paired origins; its
  # complete trace is compared, including native calls and the SQL wire.
  def prepare(side) do
    target =
      Enum.find_value(side.run.events, fn
        %{event: {_, :call, {AshOnetime.Store, function, [target | _]}}}
        when function in [:complete, :complete_external] ->
          target

        _ ->
          nil
      end)

    claim =
      Enum.find_value(side.run.events, fn
        %{
          event:
            {_, :return_from, {AshOnetime.Store, function, _},
             %AshOnetime.Store.Result{claim: %AshOnetime.Store.Claim{} = claim}}
        }
        when function in [:claim, :claim_committed] ->
          claim

        _ ->
          nil
      end)

    if target && claim &&
         Enum.any?(
           side.run.events,
           &match?(%{event: {_, :call, {AshOnetime.Store, :committed_completion, _}}}, &1)
         ) do
      Map.put(side, :readback_reference, capture(side, %{target: target, c_admit: claim}))
    else
      side
    end
  end

  defp capture(side, bound) do
    historical = Historical.capture(side.prefix)

    run =
      ExitBoundary.observe(
        fn ->
          bound.target.repo_module.put_dynamic_repo(bound.target.dynamic_repo)
        end,
        fn _ -> AshOnetime.Store.committed_completion(bound.target, bound.c_admit) end,
        %{host: [], callbacks: []}
      )

    %{run: run, historical: historical}
  end

  def check(side, indexed, bound) do
    case interval(indexed.events) do
      [] ->
        %{claimed: MapSet.new(), errors: []}

      observed ->
        start =
          Enum.find(
            observed,
            &match?(%{event: {_, :call, {AshOnetime.Store, :committed_completion, _}}}, &1)
          ).index

        clocks = ClockExpressions.build(indexed, side)
        prepared = Map.get_lazy(side, :readback_reference, fn -> capture(side, bound) end)
        historical = prepared.historical
        reference = prepared.run
        reference_events = reference.events |> origins_for_interval(side) |> interval()

        reference = %{
          reference
          | events: Enum.map(reference_events, &Map.drop(&1, [:index, :role, :phase]))
        }

        run = %{
          side.run
          | events: Enum.map(observed, &Map.drop(&1, [:index, :role, :phase])),
            result: result(observed),
            residue: 0
        }

        run_side =
          %{
            side
            | run: run,
              delta: %{},
              historical: %{side.historical | pool_clocks: Map.fetch!(clocks.checkpoints, start)}
          }
          |> Map.put(:origin_phase_override, :open)
          |> Map.put(:claim_origins, [bound.c_admit])

        twin_side =
          %{side | run: reference, delta: %{}, historical: historical}
          |> Map.put(:origin_phase_override, :open)
          |> Map.put(:claim_origins, [bound.c_admit])

        result =
          Comparator.compare(%{run: run_side, twin: twin_side, row: side.row},
            readback_reference?: true
          )

        errors =
          Enum.map(result.errors, fn error ->
            at =
              case error.at do
                %{run_index: n} = at ->
                  %{at | run_index: Enum.at(observed, n, hd(observed)).index}

                other ->
                  other
              end

            %{error | at: at}
          end)

        reference_origins = Origins.build(twin_side).origins

        sources =
          for {key, origin} <- Origins.build(run_side).origins, into: %{} do
            {Enum.fetch!(observed, origin.index).index,
             %{
               key: key,
               value: origin.value,
               twin: Map.get(reference_origins, key),
               pairing: result.pairing
             }}
          end

        %{claimed: MapSet.new(observed, & &1.index), errors: errors, sources: sources}
    end
  end

  defp origins_for_interval(events, side) do
    temporary = %{side | run: %{side.run | events: events}}
    Origins.build(temporary).events
  end

  defp interval(events) do
    case Enum.find_index(
           events,
           &match?(%{event: {_, :call, {AshOnetime.Store, :committed_completion, _}}}, &1)
         ) do
      nil ->
        []

      start ->
        caller = Enum.at(events, start).pid
        tail = Enum.drop(events, start)

        stop =
          Enum.find_index(tail, fn e ->
            e.pid == caller and e.mfa == @root and elem(e.event, 1) == :return_from
          end)

        range = if stop == nil, do: tail, else: Enum.take(tail, stop + 1)
        caller_events = Enum.filter(range, &(&1.pid == caller))
        requests = driver_requests(events)

        owned_requests =
          for e <- caller_events, Map.has_key?(requests, e.index), do: requests[e.index]

        messages = for %{event: {^caller, :receive, message}} <- caller_events, do: message

        control_replies =
          for index <- owned_requests,
              %{event: {port, :receive, {^caller, {:control, _}}}} <- [
                Enum.find(events, &(&1.index == index))
              ],
              reply =
                Enum.find(events, fn e ->
                  e.index > index and
                    match?({^port, :send, {^port, {:control, _}}, ^caller}, e.event)
                end),
              reply != nil,
              do: reply.index

        roots = MapSet.new(caller_events, & &1.index)
        selected = MapSet.new(owned_requests ++ control_replies)

        Enum.filter(events, fn e ->
          MapSet.member?(roots, e.index) or MapSet.member?(selected, e.index) or
            case e.event do
              {port, :send, message, ^caller} when is_port(port) ->
                message in messages

              _ ->
                false
            end
        end)
    end
  end

  defp driver_requests(events) do
    requests =
      for %{event: {port, :receive, {caller, {kind, payload}}}, index: index} <- events,
          is_port(port),
          kind in [:command, :control],
          do: {{caller, port, kind, request_payload(kind, payload)}, index}

    grouped = Enum.group_by(requests, &elem(&1, 0), &elem(&1, 1))

    {bound, _} =
      Enum.reduce(events, {%{}, %{}}, fn e, {bound, counts} ->
        case e.event do
          {caller, :call, {:erts_internal, :port_command, [port, data, _opts]}} ->
            request(
              e.index,
              {caller, port, :command, request_payload(:command, data)},
              grouped,
              bound,
              counts
            )

          {caller, :call, {:erts_internal, :port_control, [port, command, data]}} ->
            request(
              e.index,
              {caller, port, :control, request_payload(:control, {command, data})},
              grouped,
              bound,
              counts
            )

          _ ->
            {bound, counts}
        end
      end)

    bound
  end

  defp request(index, key, grouped, bound, counts) do
    ordinal = Map.get(counts, key, 0)

    case Enum.at(Map.get(grouped, key, []), ordinal) do
      nil -> {bound, Map.put(counts, key, ordinal + 1)}
      source -> {Map.put(bound, index, source), Map.put(counts, key, ordinal + 1)}
    end
  end

  defp request_payload(:control, {command, data}), do: {command, IO.iodata_to_binary(data)}
  defp request_payload(:command, data), do: IO.iodata_to_binary(data)

  defp result(events) do
    %{event: {_, :return_from, @root, value}} =
      Enum.find(events, &match?(%{event: {_, :return_from, @root, _}}, &1))

    value
  end
end
