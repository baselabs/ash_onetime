defmodule AshOnetime.Delivery.ExitBoundarySemanticsTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.ExitBoundary.{Analysis, Persisted}
  alias AshOnetime.Test.ExitBoundary.Analysis.Event

  @moduletag exit_boundary_semantics: true

  test "X2 and X3 preserve existing binary and numeric values" do
    for {left, right} <- [{"original", "inverted"}, {7, 8}] do
      refute Analysis.shape(%{value: left}, %{}) == Analysis.shape(%{value: right}, %{})
    end
  end

  test "X1 preserves same-width opaque binary values" do
    delta = fn bytes -> %{"records" => %{added: [%{"opaque" => bytes}], removed: []}} end
    left = Persisted.normalize(delta.(<<0, 1, 2, 3>>), "fixture", %{})
    right = Persisted.normalize(delta.(<<4, 5, 6, 7>>), "fixture", %{})
    refute Persisted.difference(left, right) == []
  end

  test "X1 preserves timestamps outside the declared database clock columns" do
    at = DateTime.from_unix!(1_000_000)
    delta = fn at -> %{"records" => %{added: [%{"expires" => at}], removed: []}} end
    left = Persisted.normalize(delta.(at), "fixture", %{})
    right = Persisted.normalize(delta.(DateTime.add(at, 1)), "fixture", %{})
    refute Persisted.difference(left, right) == []
  end

  test "X2 and X3 preserve noncanonical external-term encodings" do
    refute Analysis.shape(<<131, 97, 0>>, %{}) == Analysis.shape(<<131, 98, 0, 0, 0, 0>>, %{})
  end

  test "X2 preserves repeated non-transport events" do
    event = %Event{
      pid: self(),
      event: {self(), :call, {:logger, :update_process_metadata, [%{note: "same"}]}},
      mfa: {:logger, :update_process_metadata, 1},
      class: :e14,
      kind: :event,
      stack: [],
      region: :body
    }

    side = %{host: [], package?: false}
    one = Analysis.emitted([event], side, %{})
    two = Analysis.emitted([event, event], side, %{})
    refute Analysis.emitted_difference(one, two) == []
  end

  test "X2 and X3 preserve argument payloads in package and Ash entry frames" do
    for module <- [AshOnetime.Admission, Ash, AshOnetime.Delivery] do
      stack = fn value -> [{module, :call, [value], [file: ~c"fixture.ex", line: 1]}] end
      refute Analysis.shape(stack.("original"), %{}) == Analysis.shape(stack.("inverted"), %{})
    end
  end

  test "X2 compares every protection setting outside the declared fixture differences" do
    protection = %AshOnetime.Resource.Protection{retention: 60, scope: [{:static, "boundary"}]}

    for changed <- [
          %{protection | retention: 61},
          %{protection | scope: [{:static, "elsewhere"}]},
          %{protection | on_definite_store_failure: :execute_untracked}
        ] do
      refute Analysis.shape(protection, %{}) == Analysis.shape(changed, %{})
    end
  end

  test "stack filtering retains argument payloads and repeated configuration reads" do
    filter = fn value ->
      trace = [{AshOnetime.Delivery, :deliver, [value], []}]
      traced_call(Splode, :filter_stacktrace, [trace, ["Ash.", "Splode."]])
    end

    inspect_module = traced_call(Kernel, :inspect, [AshOnetime.Delivery, []])
    read = traced_call(:persistent_term, :get, [{Inspect.Opts, :inspect_fun}, &Inspect.inspect/2])
    read = %{read | kind: :event, class: :e6}
    side = %{host: [], package?: false}
    base = [filter.("original"), inspect_module, read]

    for changed <- [
          [filter.("inverted"), inspect_module, read],
          base ++ [read]
        ] do
      refute Analysis.emitted_difference(
               Analysis.emitted(base, side, %{}),
               Analysis.emitted(changed, side, %{})
             ) == []
    end
  end

  test "pool deadlines normalize only an identified real clock origin" do
    event =
      traced_call(:erlang, :start_timer, [
        105,
        self(),
        {make_ref(), make_ref(), self(), 5},
        [abs: true]
      ])

    event = %{event | kind: :event, class: :e10}
    side = %{host: [], package?: false}
    clocks = %{clock_values: MapSet.new([100])}
    refute Analysis.emitted([event], side, clocks) == Analysis.emitted([event], side, %{})

    changed = %{
      event
      | event:
          {self(), :call,
           {:erlang, :start_timer,
            [106, self(), {make_ref(), make_ref(), self(), 5}, [abs: true]]}}
    }

    refute Analysis.emitted([changed], side, clocks) == Analysis.emitted([event], side, clocks)
  end

  test "PostgreSQL transport chunking retains bytes and protocol message counts" do
    [port | _] = Port.list()
    command = <<?C, 13::32, "SELECT 1", 0>>
    ready = <<?Z, 5::32, ?I>>
    bytes = command <> ready

    tcp = fn bytes ->
      %Event{
        pid: self(),
        event: {self(), :receive, {:tcp, port, bytes}},
        class: :e20,
        kind: :event,
        stack: [],
        region: :body
      }
    end

    passive = fn bytes ->
      %Event{
        pid: self(),
        event: {self(), :receive, {:inet_async, port, 1, {:ok, bytes}}},
        class: :e20,
        kind: :event,
        stack: [],
        region: :body
      }
    end

    <<head::binary-size(3), tail::binary>> = bytes
    side = %{host: [], package?: false}
    whole = Analysis.emitted([tcp.(bytes)], side, %{})
    assert whole == Analysis.emitted([tcp.(head), passive.(tail)], side, %{})
    refute whole == Analysis.emitted([tcp.(bytes), tcp.(bytes)], side, %{})
    changed = <<?C, 13::32, "SELECT 2", 0>> <> ready
    refute whole == Analysis.emitted([tcp.(changed)], side, %{})
  end

  test "native TCP receive identities retain reply counts and other control bytes" do
    [port | _] = Port.list()

    reply = fn bytes ->
      %Event{
        pid: port,
        event: {port, :send, {port, {:control, bytes}}, self()},
        class: :e8,
        kind: :event,
        stack: [],
        region: :body
      }
    end

    side = %{host: [], package?: false}
    names = %{tcp_receive_replies: MapSet.new([{port, self(), 7}, {port, self(), 8}])}
    one = Analysis.emitted([reply.(<<1, 7::16>>)], side, names)
    assert one == Analysis.emitted([reply.(<<1, 8::16>>)], side, names)

    for events <- [
          [reply.(<<1, 9::16>>)],
          [reply.(<<0, 7::16>>)],
          [reply.(<<1, 7::16>>), reply.(<<1, 7::16>>)]
        ] do
      refute one == Analysis.emitted(events, side, names)
    end
  end

  # Mutation controls use a fresh transformed canary: none of the raw, encoded, or
  # integer needles matches it. They exercise the same comparators as X1/X2/X3.
  @tag exit_boundary_review: true
  test "review mutation: overwrite an existing result field" do
    secret = :crypto.strong_rand_bytes(32)
    twin = %{note: "existing note"}
    run = %{twin | note: "existing note"}
    assert_not_raw_canary(run, secret)

    assert is_nil(Analysis.divergence(Analysis.shape(run, %{}), Analysis.shape(twin, %{}))),
           "X3: an existing result field changed"
  end

  @tag exit_boundary_review: true
  test "review mutation: replace an opaque binary at the same width" do
    secret = :crypto.strong_rand_bytes(32)
    twin = :crypto.hash(:sha256, "public payload")
    run = :crypto.hash(:sha256, "public payload")
    assert_not_raw_canary(run, secret)
    delta = fn bytes -> %{"records" => %{added: [%{"opaque" => bytes}], removed: []}} end

    difference =
      Persisted.difference(
        Persisted.normalize(delta.(run), "fixture", %{}),
        Persisted.normalize(delta.(twin), "fixture", %{})
      )

    assert difference == [], "X1: a same-width opaque binary changed"
  end

  @tag exit_boundary_review: true
  test "review mutation: repeat an existing event" do
    event = log_event("existing note")
    twin = [event]
    run = [event]
    side = %{host: [], package?: false}

    difference =
      Analysis.emitted_difference(
        Analysis.emitted(run, side, %{}),
        Analysis.emitted(twin, side, %{})
      )

    assert difference == [], "X2: an existing event was repeated"
  end

  @tag exit_boundary_review: true
  test "review mutation: retain a package frame argument" do
    secret = :crypto.strong_rand_bytes(32)

    frame =
      {AshOnetime.Delivery, :deliver, ["existing argument"], [file: ~c"fixture.ex", line: 1]}

    twin = [frame]
    run = [frame]
    assert_not_raw_canary(run, secret)

    assert is_nil(Analysis.divergence(Analysis.shape(run, %{}), Analysis.shape(twin, %{}))),
           "X3: a package frame argument changed"
  end

  @tag exit_boundary_review: true
  test "review mutation: retain a protection setting" do
    twin = %AshOnetime.Resource.Protection{retention: 3600, scope: [{:static, "boundary"}]}
    run = %{twin | retention: 3600}

    assert is_nil(Analysis.divergence(Analysis.shape(run, %{}), Analysis.shape(twin, %{}))),
           "X2: a protection setting changed"
  end

  defp assert_not_raw_canary(term, secret) do
    refute Analysis.contains?(term, Analysis.needles([secret])),
           "control must evade the raw canary search"
  end

  defp traced_call(module, function, args) do
    %Event{
      pid: self(),
      event: {self(), :call, {module, function, args}},
      mfa: {module, function, length(args)},
      class: :marker,
      kind: :frame_call,
      stack: [],
      region: :body
    }
  end

  defp log_event(note) do
    %Event{
      pid: self(),
      event: {self(), :call, {:logger, :update_process_metadata, [%{note: note}]}},
      mfa: {:logger, :update_process_metadata, 1},
      class: :e14,
      kind: :event,
      stack: [],
      region: :body
    }
  end
end
