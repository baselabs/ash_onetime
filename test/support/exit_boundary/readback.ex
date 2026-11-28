defmodule AshOnetime.Test.ExitBoundary.Readback do
  @moduledoc false
  alias AshOnetime.Delivery
  alias AshOnetime.Store.Claim
  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.Capture
  alias AshOnetime.Test.ExitBoundary.{Comparator, Historical, Origins, Withheld}
  @root {AshOnetime.Store, :committed_completion, 2}

  # OPEN's read is checked against a second real, read-only execution with the
  # target and claim passed through the executed dictionary entry. The main trace
  # independently grounds them in the original target and admission. The reference
  # itself has no delivery dictionary, producer or delivered values. Its
  # complete trace is compared, including native calls and the SQL wire.
  def prepare(%{prior: prior} = side) when not is_nil(prior) do
    # A reference reads the same committed database through the main Repo.
    # Its own checkouts must follow every observed lease on this side, including
    # replay after a prior completion. Inserting the reference between those
    # invocations would change which physical member a later call borrows.
    side
    |> Map.put(:prior, prepare(prior))
    |> prepare_invocation()
  end

  def prepare(side), do: prepare_invocation(side)

  defp prepare_invocation(%{resource: Withheld, allocation_checkpoint?: true} = side) do
    {target, admitted} = admission(side.run.events)
    claim = done_claim(side.run.events, target) || admitted
    Map.put(side, :readback_reference, capture(side, target, claim))
  end

  defp prepare_invocation(side), do: side

  defp done_claim(events, target) do
    Enum.find_value(events, fn
      %{
        stack: stack,
        event:
          {_, :call,
           {:erlang, :put, [{Delivery, _}, {:done, _, :executed, _, {^target, %Claim{} = claim}}]}}
      } ->
        if {Delivery, :complete_entry, 3} in stack, do: claim

      _ ->
        nil
    end)
  end

  defp admission(events) do
    target =
      Enum.find_value(events, fn
        %{event: {_, :call, {AshOnetime.Store, function, [target | _]}}}
        when function in [:complete, :complete_external] ->
          target

        _ ->
          nil
      end)

    claim =
      Enum.find_value(events, fn
        %{
          event:
            {_, :return_from, {AshOnetime.Store, function, _},
             %AshOnetime.Store.Result{claim: %Claim{} = claim}}
        }
        when function in [:claim, :claim_committed] ->
          claim

        _ ->
          nil
      end)

    unless target && claim, do: raise("the prescribed OPEN reference has no admission origins")
    {target, claim}
  end

  defp capture(side, target, claim) do
    historical = Historical.capture(side.prefix)

    run =
      ExitBoundary.observe(
        fn ->
          target.repo_module.put_dynamic_repo(target.dynamic_repo)
        end,
        fn _ -> AshOnetime.Store.committed_completion(target, claim) end,
        %{host: [], callbacks: []}
      )

    %{run: run, historical: historical, claim: claim}
  end

  def check(%{allocation_checkpoint?: true} = side, indexed, bound) do
    side = Map.put(side, :bound, bound)

    case interval(indexed.events, side.connection_history) do
      [] ->
        %{claimed: MapSet.new(), errors: []}

      observed ->
        compare_interval(side, bound, observed)
    end
  end

  # An undeclared OPEN stays in the ordinary comparison. It cannot create its
  # own reference computation or acquire any claimed events.
  def check(_side, _indexed, _bound), do: %{claimed: MapSet.new(), errors: []}

  defp compare_interval(side, bound, observed) do
    prepared = Map.fetch!(side, :readback_reference)
    historical = prepared.historical
    reference = prepared.run
    proof = prepared.connection_history

    reference_side =
      %{side | run: reference, delta: %{}, historical: historical}
      |> Map.put(:connection_history, proof)
      |> Map.put(:origin_phase_override, :open)
      |> Map.put(:claim_origins, [prepared.claim])

    reference_events = Origins.build(reference_side).events |> interval(proof)

    reference = %{
      reference
      | events: Enum.map(reference_events, &Map.drop(&1, [:role, :phase]))
    }

    run = %{
      side.run
      | events: Enum.map(observed, &Map.drop(&1, [:role, :phase])),
        result: result(observed),
        residue: 0
    }

    run_side =
      %{side | run: run, delta: %{}}
      |> Map.put(:origin_phase_override, :open)
      |> Map.put(:claim_origins, [completion_claim(bound)])

    twin_side =
      %{reference_side | run: reference}

    result =
      Comparator.compare_reference(
        %{run: run_side, twin: twin_side, row: side.row},
        {side.connection_history, proof}
      )

    sources =
      for {key, origin} <- Origins.build(run_side).origins, into: %{} do
        {origin.index, %{key: key, value: origin.value}}
      end

    %{claimed: MapSet.new(observed, &Capture.address/1), errors: result.errors, sources: sources}
  end

  defp completion_claim(%{completion: {_target, %Claim{} = claim}}), do: claim
  defp completion_claim(%{c_admit: claim}), do: claim

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

  defp interval(events, proof) do
    case Enum.find_index(
           events,
           &match?(%{event: {_, :call, {AshOnetime.Store, :committed_completion, _}}}, &1)
         ) do
      nil ->
        []

      start ->
        interval_from(events, start, proof)
    end
  end

  defp interval_from(events, start, proof) do
    caller = Enum.at(events, start).pid
    tail = Enum.drop(events, start)

    roots = readback_call_indexes(tail, caller)

    writes = Enum.filter(proof.native.writes, &MapSet.member?(roots, &1.source.index))
    commands = MapSet.new(writes, & &1.command.index)

    # The protocol ledger associates replies with their actual frontend
    # instances. A native receive can carry unrelated messages in the same
    # chunk; that coalescing grants no claim on those logical messages.
    requests =
      for %{message_address: {:connection_message, port, :frontend, ordinal}, wire_frame: frame} <-
            events,
          Enum.all?(frame.provenance, &MapSet.member?(commands, &1.index)),
          into: MapSet.new(),
          do: {port, ordinal}

    logical =
      Enum.filter(events, fn
        %{message_address: {:connection_message, port, direction, ordinal}, wire_frame: frame} ->
          request = if direction == :frontend, do: ordinal, else: frame.request
          MapSet.member?(requests, {port, request})

        _ ->
          false
      end)

    receipts =
      for %{wire_frame: %{provenance: provenance}} <- logical,
          span <- provenance,
          into: MapSet.new(),
          do: span.index

    native =
      writes ++
        Enum.filter(proof.native.reads ++ proof.native.active, fn read ->
          MapSet.member?(roots, read.source.index) or
            MapSet.member?(receipts, read.delivered.index)
        end)

    selected = native |> Enum.flat_map(& &1.indexes) |> MapSet.new()
    addresses = MapSet.new(logical, &Capture.address/1)

    Enum.filter(events, fn event ->
      if Map.has_key?(event, :message_address),
        do: MapSet.member?(addresses, Capture.address(event)),
        else: MapSet.member?(roots, event.index) or MapSet.member?(selected, event.index)
    end)
  end

  defp readback_call_indexes(tail, caller) do
    stop =
      Enum.find_index(tail, fn e ->
        e.pid == caller and e.mfa == @root and elem(e.event, 1) == :return_from
      end)

    range = if is_nil(stop), do: tail, else: Enum.take(tail, stop + 1)
    for event <- range, event.pid == caller, into: MapSet.new(), do: event.index
  end

  defp result(events) do
    %{event: {_, :return_from, @root, value}} =
      Enum.find(events, &match?(%{event: {_, :return_from, @root, _}}, &1))

    value
  end
end
