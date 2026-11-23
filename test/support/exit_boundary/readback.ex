defmodule AshOnetime.Test.ExitBoundary.Readback do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.{Comparator, Historical, Origins}
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
    side = Map.put(side, :bound, bound)

    case interval(indexed.events) do
      [] ->
        %{claimed: MapSet.new(), errors: []}

      observed ->
        check_interval(side, bound, observed)
    end
  end

  defp check_interval(side, bound, observed) do
    start =
      Enum.find(
        observed,
        &match?(%{event: {_, :call, {AshOnetime.Store, :committed_completion, _}}}, &1)
      ).index

    case Historical.cut(side.historical, side.connection_history, start) do
      {:ok, checkpoint} -> compare_interval(side, bound, observed, checkpoint)
      {:error, failure} -> cut_failure(observed, start, failure)
    end
  end

  defp compare_interval(side, bound, observed, checkpoint) do
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
          historical: checkpoint
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

    errors = Enum.map(result.errors, &reference_error(&1, observed))

    sources =
      for {key, origin} <- Origins.build(run_side).origins, into: %{} do
        {Enum.fetch!(observed, origin.index).index, %{key: key, value: origin.value}}
      end

    %{claimed: MapSet.new(observed, & &1.index), errors: errors, sources: sources}
  end

  defp cut_failure(observed, start, failure) do
    at = Map.take(hd(observed), [:role, :mfa, :stack]) |> Map.put(:run_index, start)

    %{
      claimed: MapSet.new(),
      errors: [
        %{at: at, rule: failure.rule, path: [], run: failure, twin: :committed_history_cut}
      ]
    }
  end

  defp reference_error(error, observed) do
    at =
      case error.at do
        %{run_index: n} = at -> %{at | run_index: Enum.at(observed, n, hd(observed)).index}
        other -> other
      end

    %{error | at: at}
  end

  # The third execution is a read-only SQL/program witness. Its private origin
  # pairing has no authority over run -> twin allocation. Export a source only
  # through the whole observation's map and its actual twin origin. In particular
  # OPEN's monitor/timer/connection identities pair with the proved checkpoint,
  # and retain that image at every subsequent lease and copied occurrence.
  def whole_sources(readback, pairing, twin) do
    for {index, source} <- Map.get(readback, :sources, %{}),
        {:ok, image} <- [Map.fetch(pairing.forward, source.value)],
        {_key, origin} <- twin.origins,
        origin.value === image,
        into: %{},
        do: {index, Map.merge(source, %{twin: origin, pairing: pairing})}
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
        interval_from(events, start)
    end
  end

  defp interval_from(events, start) do
    caller = Enum.at(events, start).pid
    tail = Enum.drop(events, start)

    stop =
      Enum.find_index(tail, fn e ->
        e.pid == caller and e.mfa == @root and elem(e.event, 1) == :return_from
      end)

    range = if stop == nil, do: tail, else: Enum.take(tail, stop + 1)
    caller_events = Enum.filter(range, &(&1.pid == caller))
    native = Enum.sort_by(events, & &1.index)
    requests = driver_requests(native)

    owned_requests =
      for e <- caller_events, Map.has_key?(requests, e.index), do: requests[e.index]

    replies = control_replies(native)
    messages = received_messages(native)

    control_replies =
      for index <- owned_requests, Map.has_key?(replies, index), do: replies[index]

    received =
      for e <- caller_events, Map.has_key?(messages, e.index), do: messages[e.index]

    roots = MapSet.new(caller_events, & &1.index)
    selected = MapSet.new(owned_requests ++ control_replies ++ received)

    Enum.filter(events, fn e ->
      MapSet.member?(roots, e.index) or MapSet.member?(selected, e.index)
    end)
  end

  # Match occurrences in native timestamp order before scheduling moves. Equal
  # payloads in other queries never become part of OPEN's reference execution.
  defp received_messages(events) do
    sent =
      for %{event: {port, :send, message, caller}, index: index} <- events,
          is_port(port),
          do: {{caller, message}, index}

    grouped = Enum.group_by(sent, &elem(&1, 0), &elem(&1, 1))

    {bound, _} =
      Enum.reduce(events, {%{}, %{}}, fn
        %{event: {caller, :receive, message}, index: index}, {bound, counts} ->
          request(index, {caller, message}, grouped, bound, counts)

        _, state ->
          state
      end)

    bound
  end

  defp control_replies(events) do
    replies =
      for %{event: {port, :send, {port, {:control, _}}, caller}, index: index} <- events,
          is_port(port),
          do: {{caller, port}, index}

    grouped = Enum.group_by(replies, &elem(&1, 0), &elem(&1, 1))

    {bound, _} =
      Enum.reduce(events, {%{}, %{}}, fn
        %{event: {port, :receive, {caller, {:control, _}}}, index: index}, {bound, counts}
        when is_port(port) ->
          request(index, {caller, port}, grouped, bound, counts)

        _, state ->
          state
      end)

    bound
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
