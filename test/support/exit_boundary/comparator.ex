defmodule AshOnetime.Test.ExitBoundary.Comparator do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.{
    AttributeCopies,
    ClockExpressions,
    ContextCopies,
    Declarations,
    Hooks,
    Origins,
    PathFrames,
    PermittedTrace,
    Registry,
    Returns,
    Wire,
    References,
    TransportReferences,
    DatabaseOrigins
  }

  def compare(%{run: run, twin: twin, row: row}, options \\ []) do
    reference? = Keyword.get(options, :readback_reference?, false)

    prior =
      if not reference? and Map.get(run, :prior) do
        compare(%{run: run.prior, twin: twin.prior, row: run.prior.row})
      end

    run = inherit(run, prior, :run)
    twin = inherit(twin, prior, :twin)

    declarations =
      if reference?,
        do: %{errors: [], declarations: []},
        else: Declarations.pair(run.resource, twin.resource)

    ri = Origins.build(run)
    ti = Origins.build(twin)
    rs = AshOnetime.Test.ExitBoundary.Scheduling.build(ri)
    ts = AshOnetime.Test.ExitBoundary.Scheduling.build(ti)
    ri = %{ri | events: rs.events}
    ti = %{ti | events: ts.events}

    permitted =
      if reference?,
        do: %{bound: run.bound, claimed: MapSet.new(), errors: []},
        else: PermittedTrace.match(run, ri)

    run =
      run
      |> Map.put(:bound, permitted.bound)
      |> Map.put(:operation_slots, References.operation_slots(ri.events, run.operation_reference))
      |> Map.put(:operation_copies, References.locator_copies(ri.events))

    twin =
      twin
      |> Map.put(:bound, %{})
      |> Map.put(
        :operation_slots,
        References.operation_slots(ti.events, twin.operation_reference)
      )
      |> Map.put(:operation_copies, References.locator_copies(ti.events))

    rf =
      if reference?,
        do: %{claimed: MapSet.new(), errors: [], sources: %{}},
        else: AshOnetime.Test.ExitBoundary.FailureTrace.check(run, ri)

    tf =
      if reference?,
        do: %{claimed: MapSet.new(), errors: [], sources: %{}},
        else: AshOnetime.Test.ExitBoundary.FailureTrace.check(twin, ti)

    run = Map.put(run, :failure, rf)
    twin = Map.put(twin, :failure, tf)

    readback =
      if reference?,
        do: %{claimed: MapSet.new(), errors: []},
        else: AshOnetime.Test.ExitBoundary.Readback.check(run, ri, permitted.bound)

    checkpoint =
      if reference?,
        do: %{claimed: MapSet.new(), errors: []},
        else: Registry.compute(:allocation_checkpoint, [twin, ti])

    refusal =
      if reference?,
        do: %{claimed: MapSet.new(), errors: []},
        else: AshOnetime.Test.ExitBoundary.Refusals.check(run, ri)

    claimed =
      permitted.claimed
      |> MapSet.union(readback.claimed)
      |> MapSet.union(refusal.claimed)
      |> MapSet.union(rf.claimed)

    source_claims = readback.claimed |> MapSet.union(refusal.claimed) |> MapSet.union(rf.claimed)

    sources = %{
      {:twin, :o1} => checkpoint.claimed,
      {:twin, :o3} => checkpoint.claimed,
      o1: Origins.permitted_sources(ri, source_claims),
      o3: claimed
    }

    pairing = Origins.pair(ri, ti, sources) |> inherit_pairing(prior)

    allocation =
      if reference?,
        do: %{pairing: pairing, errors: []},
        else: Registry.compute(:o2_allocation, [pairing, run, twin, ri, ti])

    pairing = allocation.pairing
    rq = AshOnetime.Test.ExitBoundary.QueryOrigins.build(ri, run)
    tq = AshOnetime.Test.ExitBoundary.QueryOrigins.build(ti, twin)
    rd = Registry.compute(:o2a_computations, [ri, run])
    td = Registry.compute(:o2a_computations, [ti, twin])
    rc = Registry.compute(:o3, [ri, run])
    tc = Registry.compute(:o3, [ti, twin])

    state = %{
      run: run,
      twin: twin,
      row: row,
      pairing: pairing,
      query_contexts: %{},
      attribute_copies: {
        Registry.compute(:attribute_copy, [ri, run.resource]),
        Registry.compute(:attribute_copy, [ti, twin.resource])
      },
      current: nil,
      errors: [],
      queries: {rq, tq},
      clocks: {rc, tc},
      derivations: {rd, td},
      at: nil,
      backtrace_depth: run.run.backtrace_depth,
      path_frames: if(reference?, do: [], else: Registry.compute(:o5a, [row, run.hooks]))
    }

    state =
      if prior do
        %{
          state
          | errors: Enum.map(prior.errors, &Map.update!(&1, :at, fn at -> {:prior, at} end))
        }
      else
        state
      end

    state =
      if not reference? and Map.get(checkpoint, :lease) do
        backend = checkpoint.lease.protocol.connection_id

        Enum.reduce(ri.events, state, fn e, s ->
          if MapSet.member?(readback.claimed, e.index) do
            at = Map.take(e, [:role, :mfa, :stack]) |> Map.put(:run_index, e.index)
            readback_backends(e.event, backend, %{s | at: at}, [:event])
          else
            s
          end
        end)
      else
        state
      end

    state = Enum.reduce(declarations.errors, state, &error(&2, :u13, &1.path, &1.run, &1.twin))

    state =
      Enum.reduce(permitted.errors, state, fn e, s ->
        error(
          %{s | at: Map.put(e.at, :run_index, e.index)},
          e.rule,
          [e.index],
          e.actual,
          e.expected
        )
      end)

    state =
      Enum.reduce(
        readback.errors ++ refusal.errors ++ checkpoint.errors ++ allocation.errors,
        state,
        fn e, s ->
          %{s | errors: [e | s.errors]}
        end
      )

    state =
      Enum.reduce(rf.errors ++ tf.errors, state, fn e, s ->
        error(%{s | at: Map.put(e.at, :run_index, e.index)}, e.rule, [], e.actual, e.expected)
      end)

    state =
      Enum.reduce(rs.errors ++ ts.errors, state, fn e, s ->
        error(
          %{s | at: Map.put(e.at, :run_index, e.index)},
          :scheduling,
          [e.rule],
          e.actual,
          e.expected
        )
      end)

    state =
      Enum.reduce(rq.errors ++ tq.errors, state, fn {e, value, expected}, s ->
        error(
          %{s | at: %{mfa: e.mfa, role: e.role, run_index: e.index, stack: e.stack}},
          :query_origin,
          [],
          value,
          expected
        )
      end)

    state =
      Enum.reduce(pairing.errors, state, fn reason, s ->
        e = Origins.difference(reason, ri, ti)
        error(%{s | at: e.at}, :origin, e.path, e.run, e.twin)
      end)

    state =
      Enum.reduce(rc.errors ++ tc.errors, state, fn e, s ->
        error(%{s | at: Map.put(e.at, :run_index, e.index)}, :o3, [e.rule], e.actual, e.expected)
      end)

    state =
      Enum.reduce(rd.errors ++ td.errors, state, fn e, s ->
        error(
          %{s | at: Map.put(e.at, :run_index, e.index)},
          :o2a_derivation,
          [e.rule],
          e.actual,
          e.expected
        )
      end)

    rt = TransportReferences.build(ri, readback.claimed)
    tt = TransportReferences.build(ti)

    state =
      Enum.reduce(rt.errors ++ tt.errors, state, fn e, s ->
        error(
          %{s | at: Map.put(e.at, :run_index, e.index)},
          :o2_transport,
          [e.rule],
          e.actual,
          e.expected
        )
      end)

    rw = Wire.build(rt, readback.claimed)
    tw = Wire.build(tt)
    rdb = Registry.compute(:o4, [rw, run])
    tdb = Registry.compute(:o4, [tw, twin])

    state =
      state
      |> Map.put(:databases, {rdb, tdb})
      |> Map.put(:query_contexts, %{
        run: DatabaseOrigins.sql_contexts(rw),
        twin: DatabaseOrigins.sql_contexts(tw)
      })

    state =
      Enum.reduce(rdb.errors ++ tdb.errors, state, fn e, s ->
        error(%{s | at: Map.put(e.at, :run_index, e.index)}, :o4, [e.rule], e.actual, e.expected)
      end)

    left =
      rw
      |> Enum.map(fn e ->
        %{
          e
          | event:
              e.event
              |> ClockExpressions.project(e.index, rc)
              |> DatabaseOrigins.project(e.index, rdb)
        }
      end)
      |> Enum.reject(&MapSet.member?(claimed, &1.index))
      |> Enum.group_by(& &1.role)

    twin_claimed =
      if reference?,
        do: MapSet.new(),
        else:
          AshOnetime.Test.ExitBoundary.HostCall.indexes(ti.events)
          |> MapSet.union(tf.claimed)
          |> MapSet.union(checkpoint.claimed)

    right =
      tw
      |> Enum.map(fn e ->
        %{
          e
          | event:
              e.event
              |> ClockExpressions.project(e.index, tc)
              |> DatabaseOrigins.project(e.index, tdb)
        }
      end)
      |> Enum.reject(&MapSet.member?(twin_claimed, &1.index))
      |> Enum.group_by(& &1.role)

    state = if reference?, do: state, else: entry(state, ri.events, ti.events)
    state = if reference?, do: state, else: raw_return(state, ri.events)
    state = if reference?, do: state, else: reraise_terms(state, ri.events, ti.events)
    roles = (Map.keys(left) ++ Map.keys(right)) |> Enum.uniq() |> Enum.sort()

    state =
      Enum.reduce(roles, state, fn role, s ->
        sequence(Map.get(left, role, []), Map.get(right, role, []), s)
      end)

    state = store(run.delta, twin.delta, %{state | at: :store})
    state = term(run.run.residue, twin.run.residue, %{state | at: :residue}, [:residue])

    state =
      case Returns.raw(run) do
        {:found, raw} -> term(raw, twin.run.result, %{state | at: :return}, [:return, :raw])
        nil -> term(run.run.result, twin.run.result, %{state | at: :return}, [:return])
      end

    %{
      errors: state.errors |> Enum.reverse() |> Enum.sort_by(&error_order/1),
      bindings: permitted.bound,
      origin_count: map_size(ri.origins),
      clock_count: map_size(ri.reads),
      events: {length(ri.events), length(ti.events)},
      pairing: state.pairing,
      readback_sources:
        AshOnetime.Test.ExitBoundary.Readback.whole_sources(readback, state.pairing, ti),
      databases: state.databases,
      derivations: state.derivations,
      clocks: state.clocks
    }
  end

  # Whole-observation comparisons (entry, return and store) need not have a
  # paired event index. An absent occurrence has no projected clock/database slot
  # and its closure environment therefore stays in the exact comparison.
  defp at_index(at, key) when is_map(at), do: Map.get(at, key)
  defp at_index(_at, _key), do: nil

  defp error_order(%{at: %{run_index: n}}) when is_integer(n), do: {0, n}
  defp error_order(%{at: %{twin_index: n}}) when is_integer(n), do: {0, n}
  defp error_order(%{at: {:prior, _}}), do: {-1, 0}
  defp error_order(%{at: :store}), do: {2, 0}
  defp error_order(%{at: :residue}), do: {3, 0}
  defp error_order(%{at: :return}), do: {4, 0}
  defp error_order(_), do: {1, 0}

  defp reraise_terms(state, run, twin) do
    expected =
      Enum.find_value(twin, fn
        %{event: {_, :exception_from, {AshOnetime.Test.ExitBoundary.Root, :invoke, 2}, value}} ->
          {:found, value}

        _ ->
          nil
      end)

    Enum.reduce(run, state, fn
      %{event: {_, :exception_from, {m, f, _}, value}} = source, s
      when (m == AshOnetime.Delivery and f in [:deliver, :armed_call, :armed, :dispatch]) or
             (m == AshOnetime and f == :deliver) ->
        s = %{
          s
          | at: %{
              role: source.role,
              run_index: source.index,
              mfa: source.mfa,
              stack: source.stack
            }
        }

        case expected do
          {:found, twin_value} -> term(value, twin_value, s, [:reraise])
          nil -> error(s, :reraise, [], value, :no_twin_exception)
        end

      _, s ->
        s
    end)
  end

  defp raw_return(state, events) do
    case Enum.find(
           events,
           &match?(%{event: {_, :call, {AshOnetime.Delivery, :normalize, [_, _, _]}}}, &1)
         ) do
      nil ->
        state

      %{event: {_, :call, {_, _, [raw, _, _]}}} = source ->
        at = %{role: source.role, run_index: source.index, mfa: source.mfa, stack: source.stack}
        term(raw, state.twin.run.result, %{state | at: at}, [:return, :raw])
    end
  end

  defp entry(%{row: %{branch: :direct}} = state, _run, _twin), do: state

  defp entry(state, run, twin) do
    source = Enum.find(run, &match?(%{event: {_, :call, {AshOnetime, :deliver, [_, _]}}}, &1))

    if source == nil do
      error(state, :entry, [], :absent, :deliver_call)
    else
      %{event: {_, :call, {_, _, [subject, opts]}}} = source

      twin_subject =
        if state.row.branch == :transaction do
          Map.fetch!(state.twin, :prepared_subject)
        else
          Enum.find_value(twin, fn
            %{pid: pid, event: {_, :call, {Ash, function, [input, _]}}}
            when function in [:create, :update, :destroy, :run_action] ->
              if pid == state.twin.run.snapshot.root, do: {:found, input}

            _ ->
              nil
          end)
          |> case do
            {:found, input} -> input
            nil -> :missing_twin_entry
          end
        end

      at = %{role: source.role, run_index: source.index, mfa: source.mfa, stack: source.stack}
      state = term(subject, twin_subject, %{state | at: at}, [:entry, :subject])
      term(opts, Map.get(state.row, :opts, []), state, [:entry, :opts])
    end
  end

  defp inherit(side, nil, _), do: side

  defp inherit(side, prior, name) do
    index = if name == :run, do: 0, else: 1

    side
    |> Map.put(:prior_database, elem(prior.databases, index))
    |> Map.put(:prior_derivations, elem(prior.derivations, index))
    |> Map.put(:prior_clocks, elem(prior.clocks, index))
  end

  defp inherit_pairing(pairing, nil), do: pairing

  defp inherit_pairing(pairing, prior) do
    Enum.reduce(prior.pairing.uuid_forward, pairing, fn {a, b}, p ->
      p = Origins.bind(p, a, b, :prior_uuid)

      case {Map.fetch(p.uuid_forward, a), Map.fetch(p.uuid_reverse, b)} do
        {:error, :error} ->
          %{
            p
            | uuid_forward: Map.put(p.uuid_forward, a, b),
              uuid_reverse: Map.put(p.uuid_reverse, b, a)
          }

        {{:ok, ^b}, {:ok, ^a}} ->
          p

        _ ->
          %{p | errors: [{:o2_uuid, :prior_not_bijective} | p.errors]}
      end
    end)
  end

  defp sequence([], [], state), do: state

  defp sequence(
         [%{event: {_, :call, {Splode, :filter_stacktrace, [stack, filters]}}} = a | as],
         [
           %{event: {_, :call, {Splode, :filter_stacktrace, [twin_stack, twin_filters]}}} = b | bs
         ],
         state
       ) do
    state = %{
      state
      | at: %{role: a.role, run_index: a.index, twin_index: b.index, mfa: a.mfa, stack: a.stack}
    }

    expected = PathFrames.expected(twin_stack, state.path_frames, state.backtrace_depth)

    state =
      if stack === expected, do: state, else: error(state, :o5a, [:args, 0], stack, expected)

    state = term(filters, twin_filters, state, [:args, 1]) |> term_owner(a.pid, b.pid)
    {run_tree, as} = subtree([a | as], a.mfa)
    {twin_tree, bs} = subtree([b | bs], b.mfa)
    state = check_filter_tree(run_tree, expected, filters, :run, state)
    state = check_filter_tree(twin_tree, twin_stack, twin_filters, :twin, state)
    sequence(as, bs, state)
  end

  defp sequence([a | as], [b | bs], state) do
    if descriptor(a, state.run) == descriptor(b, state.twin) do
      state = %{
        state
        | at: %{role: a.role, run_index: a.index, twin_index: b.index, mfa: a.mfa, stack: a.stack}
      }

      state = event(a, b, query_context(a, b, state))
      sequence(as, bs, state)
    else
      # Re-align only to collect all failures. The insertion/deletion remains an
      # error; this is never a passing scheduling alternative.
      da = descriptor(a, state.run)
      db = descriptor(b, state.twin)
      an = Enum.find_index(as, &(descriptor(&1, state.run) == db))
      bn = Enum.find_index(bs, &(descriptor(&1, state.twin) == da))

      state = %{
        state
        | at: %{role: a.role, run_index: a.index, twin_index: b.index, mfa: a.mfa, stack: a.stack}
      }

      cond do
        an != nil and (bn == nil or an < bn) ->
          sequence(as, [b | bs], error(state, :extra_event, [], a.event, :absent))

        bn != nil ->
          sequence([a | as], bs, error(state, :missing_event, [], :absent, b.event))

        true ->
          sequence(as, bs, error(state, :event_order, [], a.event, b.event))
      end
    end
  end

  defp sequence([a | as], [], state),
    do:
      sequence(
        as,
        [],
        error(
          %{state | at: %{mfa: a.mfa, role: a.role, run_index: a.index, stack: a.stack}},
          :extra_event,
          [],
          a.event,
          :absent
        )
      )

  defp sequence([], [b | bs], state),
    do:
      sequence(
        [],
        bs,
        error(
          %{state | at: %{mfa: b.mfa, role: b.role, twin_index: b.index, stack: b.stack}},
          :missing_event,
          [],
          :absent,
          b.event
        )
      )

  defp subtree(events, root) do
    n =
      Enum.find_index(events, fn e ->
        e.mfa == root and elem(e.event, 1) in [:return_from, :exception_from]
      end)

    Enum.split(events, if(n == nil, do: length(events), else: n + 1))
  end

  defp check_filter_tree(events, stack, filters, side, state) do
    reference =
      References.capture(
        fn -> Splode.filter_stacktrace(stack, filters) end,
        {Splode, :filter_stacktrace, 2}
      )

    if length(events) == length(reference) do
      Enum.zip(events, reference)
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{actual, expected}, n}, s ->
        av = Tuple.delete_at(actual.event, 0)
        ev = Tuple.delete_at(expected.event, 0)
        if av === ev, do: s, else: error(s, :o5a_filter, [side, n], av, ev)
      end)
    else
      error(state, :o5a_filter_length, [side], length(events), length(reference))
    end
  end

  defp descriptor(e, side) do
    tag = elem(e.event, 1)
    {tag, canonical_mfa(e.mfa, side)}
  end

  defp canonical_mfa(nil, _), do: nil

  defp canonical_mfa({m, f, a} = mfa, side) do
    cond do
      Map.has_key?(side.hook_frames, mfa) ->
        side.hook_frames[mfa]

      f == :install_delivery and m in [AshOnetime.Change, AshOnetime.GenericAction] ->
        {m, :install, a - 1}

      true ->
        {Map.get(Registry.rename(), m, m), f, a}
    end
  end

  defp event(a, b, state) do
    cond do
      external_return?(a, b) ->
        external_return(a, b, state)

      derived_event?(a, b, state) ->
        term_owner(state, a.pid, b.pid)

      declaration_event?(a) and declaration_event?(b) ->
        declaration_event(a, b, state)

      operation_event?(a) and operation_event?(b) ->
        operation_event(a, b, state)

      context_copy_event?(a) and context_copy_event?(b) ->
        context_copy_event(a, b, state)

      return_event?(a, state.run) and return_event?(b, state.twin) ->
        return_event(a, b, state)

      hook_event?(a, state.run) and hook_event?(b, state.twin) ->
        hook_event(a, b, state)

      origin_event?(a) and origin_event?(b) ->
        origin_event(a, b, state)

      true ->
        left = canonical_event(a.event, state.run)
        right = canonical_event(b.event, state.twin)
        {left, state} = claim_argument(left, right, a.mfa, state)
        term(left, right, state, [:event])
    end
  end

  defp declaration_event?(%{event: {_, :return_from, mfa, _}}),
    do:
      mfa in (Registry.readers() ++
                [{AshOnetime.Resource.Info, :protection, 2}, {Ash.Resource.Info, :action, 2}])

  defp declaration_event?(_), do: false

  defp declaration_event(a, b, state) do
    {module, function, arity} = a.mfa

    expected = fn side ->
      arguments =
        if arity == 1,
          do: [state[side].resource],
          else: [state[side].resource, state.row.action]

      apply(module, function, arguments)
    end

    run = elem(a.event, 3)
    twin = elem(b.event, 3)

    state =
      if run === expected.(:run) and twin === expected.(:twin),
        do: state,
        else: error(state, :o2b_reader, [:return], run, twin)

    term_owner(state, a.pid, b.pid)
  end

  defp external_return?(
         %{
           event:
             {_, :return_from, {AshOnetime.Test.ExitBoundary.External, :execute, 3}, {:ok, _, _}}
         },
         %{
           event:
             {_, :return_from, {AshOnetime.Test.ExitBoundary.ReturnedExternal, :execute, 3},
              {:ok, _}}
         }
       ),
       do: true

  defp external_return?(_, _), do: false

  defp external_return(
         %{event: {pa, _, _, {:ok, result, values}}},
         %{event: {pb, _, _, {:ok, twin}}},
         state
       ) do
    state =
      if values === state.run.values,
        do: state,
        else: error(state, :external_host_values, [:return, :values], values, state.run.values)

    state |> term_owner(pa, pb) |> then(&term(result, twin, &1, [:return, :result]))
  end

  defp derived_event?(a, b, %{derivations: {rd, td}}) do
    case {Map.fetch(rd.slots, a.index), Map.fetch(td.slots, b.index)} do
      {{:ok, token}, {:ok, token}} -> true
      _ -> false
    end
  end

  defp origin_event?(%{event: {_, :return_from, mfa, _}}),
    do: mfa in Registry.generators() or mfa == {:crypto, :strong_rand_bytes_nif, 1}

  defp origin_event?(_), do: false

  defp origin_event(%{event: {pa, _, _, value}}, %{event: {pb, _, _, twin}}, state) do
    state |> term_owner(pa, pb) |> then(&identity_return(value, twin, &1, [:return, :origin]))
  end

  defp identity_return({a, ar}, {b, br}, state, path),
    do:
      state
      |> then(&identity_return(a, b, &1, path ++ [0]))
      |> then(&identity_return(ar, br, &1, path ++ [1]))

  defp identity_return(a, b, state, path), do: identity(a, b, state, path)

  defp hook_event?(e, side), do: Map.has_key?(side.hook_frames, e.mfa)

  defp hook_event(
         %{event: {pa, :call, {_, _, aa}}, mfa: mfa},
         %{event: {pb, :call, {_, _, ba}}, mfa: twin_mfa},
         state
       ) do
    {slot, reference} =
      Enum.find(state.run.hooks, fn {_slot, info} -> Hooks.trace_mfa(info) == mfa end)

    {_, _, arity, _, _} = reference.identity
    {_, _, twin_arity, _, _} = state.twin.hooks[slot].identity
    {args, env} = Enum.split(aa, arity)
    {twin_args, twin_env} = Enum.split(ba, twin_arity)

    state =
      if env === Hooks.environment(slot, state.run),
        do: state,
        else:
          error(
            state,
            :o2c_frame_environment,
            [slot, :run],
            env,
            Hooks.environment(slot, state.run)
          )

    fault_frame? = elem(twin_mfa, 0) == AshOnetime.Test.ExitBoundary.FailureTwins

    expected_twin_env =
      if fault_frame?,
        do:
          AshOnetime.Test.ExitBoundary.FailureTwins.environment(
            state.row,
            Enum.find(twin_env, &is_function/1)
          ),
        else: Hooks.environment(slot, state.twin)

    state =
      if twin_env === expected_twin_env,
        do: state,
        else: error(state, :o2c_frame_environment, [slot, :twin], twin_env, expected_twin_env)

    {twin_args, state} =
      if state.row.branch == :producer_failure and state.row.type != :action do
        expected_callback =
          AshOnetime.Test.ExitBoundary.FailureTwins.failure_callback(
            AshOnetime.Test.ExitBoundary.FailureTwins.error(:producer_failure)
          )

        state =
          if Enum.at(twin_args, 1) === expected_callback,
            do: state,
            else:
              error(
                state,
                :failure_callback,
                [:args, 1],
                Enum.at(twin_args, 1),
                expected_callback
              )

        source = state.twin.failure.sources |> Map.fetch!(:entry_arguments) |> Enum.fetch!(1)
        {List.replace_at(twin_args, 1, source), state}
      else
        {twin_args, state}
      end

    state |> term_owner(pa, pb) |> then(&term(args, twin_args, &1, [:event, :args]))
  end

  defp hook_event(a, b, state),
    do:
      term(canonical_event(a.event, state.run), canonical_event(b.event, state.twin), state, [
        :event
      ])

  defp term_owner(state, a, b), do: term(a, b, state, [:owner])

  defp context_copy_event?(%{event: {_, :call, _}, mfa: mfa}), do: mfa in ContextCopies.slots()
  defp context_copy_event?(_), do: false

  defp context_copy_event(
         %{event: {pa, :call, {m, f, [ai, ao, ac]}}},
         %{event: {pb, :call, {m, f, [bi, bo, bc]}}},
         state
       ) do
    rs = ContextCopies.source(state.run)
    ts = ContextCopies.source(state.twin)

    state =
      if ContextCopies.validate(ac, rs),
        do: state,
        else: error(state, :context_copy, [:args, 2, :source_context], ac.source_context, rs)

    state =
      if ContextCopies.validate(bc, ts),
        do: state,
        else:
          error(state, :context_copy, [:twin, :args, 2, :source_context], bc.source_context, ts)

    state =
      state
      |> term_owner(pa, pb)
      |> then(&term(ai, bi, &1, [:args, 0]))
      |> then(&term(ao, bo, &1, [:args, 1]))

    state =
      case {rs, ts} do
        {{:source, a}, {:source, b}} -> context(a, b, state, [:context_copy, :source])
        _ -> state
      end

    term(%{ac | source_context: nil}, %{bc | source_context: nil}, state, [:args, 2])
  end

  defp return_event?(
         %{event: {pid, :return_from, {AshOnetime.Test.ExitBoundary.Root, :invoke, 2}, _}},
         side
       ),
       do: pid === side.run.snapshot.root

  defp return_event?(%{event: {pid, :send, {:result, root, _, :post_drain}, to}}, side),
    do: pid === side.run.snapshot.root and root === pid and to === side.run.fixture.observer

  defp return_event?(
         %{event: {pid, :call, {:erlang, :send, [to, {:result, root, _, :post_drain}]}}},
         side
       ),
       do: pid === side.run.snapshot.root and root === pid and to === side.run.fixture.observer

  defp return_event?(
         %{event: {pid, :return_from, {:erlang, :send, 2}, {:result, root, _, :post_drain}}},
         side
       ),
       do: pid === side.run.snapshot.root and root === pid

  defp return_event?(_, _), do: false

  defp return_event(a, b, state) do
    case Returns.raw(state.run) do
      {:found, raw} ->
        case {a.event, b.event} do
          {{pa, :call, {:erlang, :send, [to, {:result, root, value, residue}]}},
           {pb, :call, {:erlang, :send, [twin_to, {:result, twin_root, twin, twin_residue}]}}} ->
            state = exact_return(value, state)

            term(
              {pa, root, raw, residue, to},
              {pb, twin_root, twin, twin_residue, twin_to},
              state,
              [:send, :return]
            )

          {{pa, :return_from, {:erlang, :send, 2}, {:result, root, value, residue}},
           {pb, :return_from, {:erlang, :send, 2}, {:result, twin_root, twin, twin_residue}}} ->
            state = exact_return(value, state)

            term({pa, root, raw, residue}, {pb, twin_root, twin, twin_residue}, state, [
              :send,
              :return
            ])

          {{pa, :return_from, mfa, value}, {pb, :return_from, mfa, twin}} ->
            state = exact_return(value, state)
            term({pa, raw}, {pb, twin}, state, [:return])

          {{pa, :send, {:result, root, value, residue}, to},
           {pb, :send, {:result, twin_root, twin, twin_residue}, twin_to}} ->
            state = exact_return(value, state)

            term(
              {pa, root, raw, residue, to},
              {pb, twin_root, twin, twin_residue, twin_to},
              state,
              [:send, :return]
            )
        end

      nil ->
        term(a.event, b.event, state, [:event])
    end
  end

  defp exact_return(_projected, state) do
    # Per-side return equality uses the untouched native term. The sequence
    # comparison separately checks its statement-grounded database projections.
    source = Enum.fetch!(state.run.run.events, state.at.run_index).event

    value =
      case source do
        {_, :return_from, {:erlang, :send, 2}, {:result, _, value, _}} -> value
        {_, :return_from, _, value} -> value
        {_, :send, {:result, _, value, _}, _} -> value
        {_, :call, {:erlang, :send, [_, {:result, _, value, _}]}} -> value
      end

    expected = state.run.bound.delivered_return

    if value === expected,
      do: state,
      else: error(state, :return, [:return, :delivered], value, expected)
  end

  defp claim_argument({pid, :call, {m, f, args}} = event, {_, :call, {m, f, twins}}, mfa, state) do
    slots = Registry.rule!(:claim).slots

    case Map.fetch(slots, mfa) do
      {:ok, index} ->
        actual = Enum.at(args, index)
        expected = PermittedTrace.handle(state.run.bound, state.run)

        state =
          if actual === expected and Enum.at(twins, index) == nil,
            do: state,
            else: error(state, :claim, [:args, index], actual, expected)

        {{pid, :call, {m, f, List.replace_at(args, index, nil)}}, state}

      :error ->
        {event, state}
    end
  end

  defp claim_argument(event, _twin, _mfa, state), do: {event, state}

  defp operation_event?(e),
    do:
      ({AshOnetime.Admission, :operation_hash, 1} in e.stack and
         (e.mfa == {AshOnetime.Fingerprint, :compute, 1} or
            {AshOnetime.Fingerprint, :compute, 1} in e.stack)) or
        e.mfa == {AshOnetime.Admission, :operation_hash, 1}

  defp operation_event(
         %{event: {_, :call, {AshOnetime.Admission, :operation_hash, _}}} = a,
         b,
         state
       ),
       do: term(a.event, b.event, state, [:event])

  defp operation_event(a, b, state) do
    # Expected internals come from the package's own public function called with
    # trusted identity inputs. No checked output is decoded to recover an input.
    left = Map.get(state.run, :operation_reference, [])
    right = Map.get(state.twin, :operation_reference, [])
    state = validate_operation(a, left, :run, state)
    validate_operation(b, right, :twin, state) |> term_owner(a.pid, b.pid)
  end

  defp validate_operation(
         %{mfa: {AshOnetime.Admission, :operation_hash, 1}, event: {_, :return_from, _, value}},
         _,
         side,
         state
       ) do
    expected = Registry.operation(state[side].resource, state.row.action)

    if value === expected,
      do: state,
      else: error(state, :o2a_operation, [:return], value, expected)
  end

  defp validate_operation(e, _reference, side, state) do
    payload = Tuple.delete_at(e.event, 0)
    expected = Map.get(state[side].operation_slots, e.index, :missing_reference_occurrence)

    if expected === {:expected, payload},
      do: state,
      else: error(state, :o2a_operation, [side], payload, expected)
  end

  defp canonical_event(
         {pid, :call, {m, :install_delivery, [subject, protection, names, context]}},
         side
       )
       when m in [AshOnetime.Change, AshOnetime.GenericAction] do
    # Names are checked as a declaration copy before the constructor frame pairs.
    if names === side.protection.executing_only,
      do: {pid, :call, {m, :install, [subject, protection, context]}},
      else: {pid, :call, {m, :install_delivery, [subject, protection, names, context]}}
  end

  defp canonical_event({pid, :call, {m, f, args}}, side) do
    {cm, cf, _} = canonical_mfa({m, f, length(args)}, side)
    {pid, :call, {cm, cf, args}}
  end

  defp canonical_event({pid, tag, mfa, value}, side) when tag in [:return_from, :exception_from],
    do: {pid, tag, canonical_mfa(mfa, side), value}

  defp canonical_event(event, _), do: event

  # Compiled declarations are checked against their own reader even when an
  # altered run value happens to equal the twin value.
  defp term(
         %AshOnetime.Resource.Protection{} = a,
         %AshOnetime.Resource.Protection{} = b,
         state,
         path
       ) do
    action = state.row.action
    expected_run = AshOnetime.Resource.Info.protection(state.run.resource, action)
    expected_twin = AshOnetime.Resource.Info.protection(state.twin.resource, action)

    if a === expected_run and b === expected_twin,
      do: state,
      else: error(state, :o2b_protection, path, a, b)
  end

  defp term(%AshOnetime.Resource.Response{} = a, %AshOnetime.Resource.Response{} = b, state, path) do
    expected_run =
      Registry.compute(:o2b_response, [state.run.resource, state.row.action]).response

    expected_twin =
      Registry.compute(:o2b_response, [state.twin.resource, state.row.action]).response

    if a === expected_run and b === expected_twin,
      do: state,
      else: error(state, :o2b_response, path, a, b)
  end

  defp term(%{__struct__: module} = a, %{__struct__: module} = b, state, path)
       when module in [
              Ash.Resource.Actions.Create,
              Ash.Resource.Actions.Update,
              Ash.Resource.Actions.Destroy,
              Ash.Resource.Actions.Action,
              Ash.Resource.Actions.Read
            ] do
    expected_run = Ash.Resource.Info.action(state.run.resource, state.row.action)
    expected_twin = Ash.Resource.Info.action(state.twin.resource, state.row.action)

    if a === expected_run and b === expected_twin,
      do: state,
      else: error(state, :o2b_action, path, a, b)
  end

  defp term(
         %Ash.Resource.Actions.Argument{} = a,
         %Ash.Resource.Actions.Argument{} = b,
         state,
         path
       ) do
    run_action = Registry.compute(:o2b_argument, [state.run.resource, state.row.action])
    twin_action = Registry.compute(:o2b_argument, [state.twin.resource, state.row.action])
    expected_run = Enum.find(run_action.arguments, &(&1.name == a.name))
    expected_twin = Enum.find(twin_action.arguments, &(&1.name == b.name))

    if a.name === b.name and a === expected_run and b === expected_twin,
      do: state,
      else: error(state, :o2b_argument, path, a, b)
  end

  defp term(
         %{__struct__: module, stacktrace: a},
         %{__struct__: module, stacktrace: b},
         state,
         path
       )
       when module in [Ash.Error.Stacktrace, Splode.Stacktrace] do
    expected =
      PathFrames.expected(
        b,
        state.path_frames,
        state.backtrace_depth,
        Ash.Error.__stacktrace_filters__()
      )

    if a === expected, do: state, else: error(state, :o5a, path ++ [:stacktrace], a, expected)
  end

  defp term(%Postgrex.Query{} = a, %Postgrex.Query{} = b, state, path) do
    {rq, tq} = state.queries

    case {AshOnetime.Test.ExitBoundary.QueryOrigins.expected_name(rq, a),
          AshOnetime.Test.ExitBoundary.QueryOrigins.expected_name(tq, b)} do
      {{:ok, an}, {:ok, bn}} ->
        state =
          if a.name === b.name or (a.name === an and b.name === bn),
            do: state,
            else: error(state, :o2a_query_name, path ++ [:name], a.name, b.name)

        term(
          Map.delete(Map.from_struct(a), :name),
          Map.delete(Map.from_struct(b), :name),
          state,
          path
        )

      _ ->
        term(Map.from_struct(a), Map.from_struct(b), state, path)
    end
  end

  defp term(
         {key, status, selection, prepared} = a,
         {twin_key, status, twin_selection, twin_prepared} = b,
         state,
         path
       )
       when status in [:cache, :cached] do
    {rq, tq} = state.queries

    if MapSet.member?(rq.cache_events, at_index(state.at, :run_index)) and
         MapSet.member?(tq.cache_events, at_index(state.at, :twin_index)) do
      state = term(key, twin_key, state, path ++ [0])
      state = term(selection, twin_selection, state, path ++ [2])
      term(prepared, twin_prepared, state, path ++ [3])
    else
      list(Tuple.to_list(a), Tuple.to_list(b), state, path, 0)
    end
  end

  defp term({id, query} = a, {other, twin_query} = b, state, path)
       when is_integer(id) and is_integer(other) and
              (is_binary(query) or is_struct(query, Postgrex.Query)) and
              (is_binary(twin_query) or is_struct(twin_query, Postgrex.Query)) do
    {rq, tq} = state.queries

    if MapSet.member?(rq.cache_events, at_index(state.at, :run_index)) and
         MapSet.member?(tq.cache_events, at_index(state.at, :twin_index)) do
      state = identity(id, other, state, path ++ [0])
      term(query, twin_query, state, path ++ [1])
    else
      list(Tuple.to_list(a), Tuple.to_list(b), state, path, 0)
    end
  end

  defp term(a, b, state, path)
       when (is_pid(a) and is_pid(b)) or (is_reference(a) and is_reference(b)) or
              (is_port(a) and is_port(b)),
       do: identity(a, b, state, path)

  defp term({:bind_column, n, oid, format, a}, {:bind_column, n, oid, format, b}, state, path) do
    sql = current_sql(state, :run)
    column = parameter_columns(sql)[n]
    column_value(a, b, column, state, path ++ [4])
  end

  defp term({:data_row, a}, {:data_row, b}, state, path) do
    previous = state.current
    state = row_state(state, wire_claim_state(a), wire_claim_state(b))
    state = term(a, b, state, path ++ [1])
    %{state | current: previous}
  end

  defp term(
         {:data_column, sql, {ordinal, binds}, n, name, table, number, oid, format, a},
         {:data_column, twin_sql, {twin_ordinal, twin_binds}, n, name, twin_table, number, oid,
          format, b},
         state,
         path
       ) do
    state =
      term(
        {sql, ordinal, table},
        {twin_sql, twin_ordinal, twin_table},
        state,
        path ++ [:description]
      )

    previous = state.current
    current = Map.merge(previous || %{}, %{run_sql: sql, twin_sql: twin_sql})
    state = term(binds, twin_binds, %{state | current: current}, path ++ [2, 1])
    state = column_value(a, b, name, state, path ++ [9])
    %{state | current: previous}
  end

  defp term(%Ash.Changeset{} = a, %Ash.Changeset{} = b, state, path),
    do: subject(a, b, state, path)

  defp term(%Ash.ActionInput{} = a, %Ash.ActionInput{} = b, state, path),
    do: subject(a, b, state, path)

  defp term(%AshOnetime.Response.Contract{} = a, %AshOnetime.Response.Contract{} = b, state, path) do
    {:ok, ra} = state.run.contract_reference.result
    {:ok, rb} = state.twin.contract_reference.result
    state = if a === ra and b === rb, do: state, else: error(state, :o2a_contract, path, a, b)

    term(
      Map.delete(Map.from_struct(a), :digest),
      Map.delete(Map.from_struct(b), :digest),
      state,
      path
    )
  end

  defp term(%AshOnetime.Store.Claim{} = a, %AshOnetime.Store.Claim{} = b, state, path) do
    state = uuid_identity(a.id, b.id, state, path ++ [:id])

    state =
      derived_operation(a.operation_hash, b.operation_hash, state, path ++ [:operation_hash])

    previous = state.current
    state = row_state(state, a.state, b.state)

    state =
      Enum.reduce(
        [response_codec: :codec, response_digest: :digest],
        state,
        fn {field, key}, s ->
          response_value(Map.fetch!(a, field), Map.fetch!(b, field), key, s, path ++ [field])
        end
      )

    # Claim's unjoined INSERT/UPDATE projection leaves response_payload at its
    # declared default. Only the joined selector attaches payload bytes. Compare
    # the absent optional field exactly; a present copy still belongs to encode.
    default_payload = struct(AshOnetime.Store.Claim).response_payload

    state =
      if a.response_payload === default_payload and b.response_payload === default_payload,
        do: state,
        else:
          response_value(
            a.response_payload,
            b.response_payload,
            :payload,
            state,
            path ++ [:response_payload]
          )

    state = %{state | current: previous}
    {a, state} = claim_clock_copies(a, :run, state, path)
    {b, state} = claim_clock_copies(b, :twin, state, path)
    fields = [:id, :operation_hash, :response_codec, :response_digest, :response_payload]
    term(Map.drop(Map.from_struct(a), fields), Map.drop(Map.from_struct(b), fields), state, path)
  end

  defp term(%AshOnetime.Cache.Entry{} = a, %AshOnetime.Cache.Entry{} = b, state, path) do
    state = uuid_identity(a.claim_id, b.claim_id, state, path ++ [:claim_id])

    state =
      Enum.reduce([:codec, :digest, :payload], state, fn key, s ->
        response_value(Map.fetch!(a, key), Map.fetch!(b, key), key, s, path ++ [key])
      end)

    term(
      Map.drop(Map.from_struct(a), [:claim_id, :codec, :digest, :payload]),
      Map.drop(Map.from_struct(b), [:claim_id, :codec, :digest, :payload]),
      state,
      path
    )
  end

  defp term(%AshOnetime.Store.Result{} = a, %AshOnetime.Store.Result{} = b, state, path) do
    previous = state.current
    state = row_state(state, a.status, b.status)
    state = response_value(a.payload, b.payload, :payload, state, path ++ [:payload])
    state = %{state | current: previous}

    term(
      Map.delete(Map.from_struct(a), :payload),
      Map.delete(Map.from_struct(b), :payload),
      state,
      path
    )
  end

  defp term(%DBConnection.LogEntry{} = a, %DBConnection.LogEntry{} = b, state, path) do
    state = parameters(a.params, b.params, state, path ++ [:params])

    term(
      Map.delete(Map.from_struct(a), :params),
      Map.delete(Map.from_struct(b), :params),
      state,
      path
    )
  end

  defp term(%Postgrex.Protocol{} = a, %Postgrex.Protocol{} = b, state, path) do
    state =
      Enum.reduce([:connection_id, :connection_key, :scram], state, fn field, s ->
        s
        |> historical_protocol(a, field, :run, path)
        |> historical_protocol(b, field, :twin, path)
      end)

    term(
      Map.drop(a, [:__struct__, :connection_id, :connection_key, :scram]),
      Map.drop(b, [:__struct__, :connection_id, :connection_key, :scram]),
      state,
      path
    )
  end

  defp term(%Postgrex.Error{} = a, %Postgrex.Error{} = b, state, path) do
    state = historical_backend(a.connection_id, b.connection_id, state, path ++ [:connection_id])

    term(
      Map.delete(Map.from_struct(a), :connection_id),
      Map.delete(Map.from_struct(b), :connection_id),
      state,
      path
    )
  end

  defp term(%Postgrex.Result{} = a, %Postgrex.Result{} = b, state, path) do
    state = historical_backend(a.connection_id, b.connection_id, state, path ++ [:connection_id])

    if a.columns === b.columns and is_list(a.columns) and is_list(a.rows) and is_list(b.rows) and
         length(a.rows) == length(b.rows) do
      state =
        Enum.zip(a.rows, b.rows)
        |> Enum.with_index()
        |> Enum.reduce(state, fn {{ar, br}, n}, s ->
          if length(ar) == length(br) and length(ar) == length(a.columns) do
            previous = s.current
            run_row = Map.new(Enum.zip(a.columns, ar))
            twin_row = Map.new(Enum.zip(b.columns, br))
            s = row_state(s, run_row["state"], twin_row["state"])

            s =
              Enum.zip(ar, br)
              |> Enum.with_index()
              |> Enum.reduce(s, fn {{av, bv}, k}, s ->
                column_value(av, bv, Enum.at(a.columns, k), s, path ++ [:rows, n, k])
              end)

            %{s | current: previous}
          else
            error(s, :result_row_width, path ++ [:rows, n], ar, br)
          end
        end)

      term(
        Map.drop(Map.from_struct(a), [:connection_id, :rows]),
        Map.drop(Map.from_struct(b), [:connection_id, :rows]),
        state,
        path
      )
    else
      term(
        Map.delete(Map.from_struct(a), :connection_id),
        Map.delete(Map.from_struct(b), :connection_id),
        state,
        path
      )
    end
  end

  defp term({:uuid, a}, {:uuid, b}, state, path), do: uuid_identity(a, b, state, path)
  defp term({:table_oid, a}, {:table_oid, b}, state, path), do: identity(a, b, state, path)

  defp term(a, b, state, path) when is_function(a) and is_function(b) do
    ai = Map.new(Function.info(a))
    bi = Map.new(Function.info(b))
    {rc, tc} = state.clocks
    {rdb, tdb} = state.databases
    base = Enum.drop(path, 1) ++ [:function, :env]

    ai =
      Map.update!(ai, :env, fn env ->
        env
        |> ClockExpressions.project_at(at_index(state.at, :run_index), base, rc)
        |> DatabaseOrigins.project_at(at_index(state.at, :run_index), base, rdb)
      end)

    bi =
      Map.update!(bi, :env, fn env ->
        env
        |> ClockExpressions.project_at(at_index(state.at, :twin_index), base, tc)
        |> DatabaseOrigins.project_at(at_index(state.at, :twin_index), base, tdb)
      end)

    keys = [:module, :name, :arity, :new_uniq, :index, :type, :pid]
    state = term(Map.take(ai, keys), Map.take(bi, keys), state, path ++ [:function])

    slots =
      if ai.module == bi.module and ai.name == bi.name,
        do: Registry.function_slots(ai.module, ai.name),
        else: %{}

    if length(ai.env) == length(bi.env) do
      Enum.with_index(Enum.zip(ai.env, bi.env))
      |> Enum.reduce(state, fn {{av, bv}, n}, s ->
        at = path ++ [:function, :env, n]

        case slots[n] do
          :parameters -> parameters(av, bv, s, at)
          :cache_arguments -> cache_arguments(av, bv, s, at)
          :uuid -> uuid_identity(av, bv, s, at)
          {:response, key} -> response_value(av, bv, key, s, at)
          nil -> term(av, bv, s, at)
        end
      end)
    else
      error(state, :function_environment_length, path, length(ai.env), length(bi.env))
    end
  end

  defp term(
         %{__exception__: true, bread_crumbs: ac} = a,
         %{__exception__: true, bread_crumbs: bc} = b,
         state,
         path
       ) do
    kind =
      if state.row.branch == :consumer_failure and state.row.fault == :after_raise,
        do: :raise,
        else: :error

    expected_run = References.breadcrumbs(state.run, kind)
    expected_twin = References.breadcrumbs(state.twin, kind)

    state =
      if length(ac) == length(bc) do
        Enum.zip(ac, bc)
        |> Enum.with_index()
        |> Enum.reduce(state, fn {{av, bv}, n}, s ->
          if av === expected_run and bv === expected_twin,
            do: s,
            else: term(av, bv, s, path ++ [:bread_crumbs, n])
        end)
      else
        error(state, :diagnostic_breadcrumb_count, path, ac, bc)
      end

    term(Map.delete(a, :bread_crumbs), Map.delete(b, :bread_crumbs), state, path)
  end

  defp term(a, b, state, path) when is_map(a) and is_map(b) do
    if argument = AttributeCopies.slot(state.at, path) do
      {run_sources, twin_sources} = state.attribute_copies
      source_a = Map.get(run_sources, {at_index(state.at, :run_index), argument})
      source_b = Map.get(twin_sources, {at_index(state.at, :twin_index), argument})

      case {source_a, source_b} do
        {%{value: ^a, typed: typed}, %{value: ^b, typed: typed}} ->
          attributes(a, b, typed, state, path)

        _ ->
          error(state, :attribute_copy, path, a, b)
      end
    else
      map(a, b, state, path)
    end
  end

  defp term(a, b, state, path) when is_list(a) and is_list(b) do
    if stack_slot?(state, path) do
      expected =
        PathFrames.expected(b, state.path_frames, state.backtrace_depth, stack_filters(path))

      if a === expected, do: state, else: error(state, :o5a, path, a, expected)
    else
      cond do
        encoded_parameters?(state, path) ->
          encoded_parameters(a, b, state, path)

        parameter_list?(state, path) or cast_parameters?(state, path) ->
          parameters(a, b, state, path)

        cache_arguments?(state, path) ->
          cache_arguments(a, b, state, path)

        match?(
          %{mfa: {AshOnetime.Store.Postgres, f, _}}
          when f in [:decode_claim, :decode_selected_claim],
          state.at
        ) and
          path == [:event, 2, 2, 1] and
            match?({_, :call, {_, _, [:idempotency, _]}}, state.current.run.event) ->
          columns = Registry.database_statements().claim.columns

          columns =
            if elem(state.at.mfa, 1) == :decode_selected_claim,
              do: columns ++ ["encoded_response", "outcome"],
              else: columns

          if length(a) == length(columns) and length(b) == length(columns) do
            previous = state.current
            state = row_state(state, Enum.at(a, 6), Enum.at(b, 6))

            state =
              Enum.zip(a, b)
              |> Enum.with_index()
              |> Enum.reduce(state, fn {{av, bv}, n}, s ->
                column_value(av, bv, Enum.at(columns, n), s, path ++ [n])
              end)

            %{state | current: previous}
          else
            error(state, :claim_row_width, path, length(a), length(b))
          end

        true ->
          list(a, b, state, path, 0)
      end
    end
  end

  defp term({:cast_params, a}, {:cast_params, b}, state, path) do
    if sql_frame?(state),
      do: parameters(a, b, state, path ++ [1]),
      else: term({:ordinary_option, a}, {:ordinary_option, b}, state, path)
  end

  defp term(
         {:"$gen_call", af, {:put, ak, ae, at}},
         {:"$gen_call", bf, {:put, bk, be, bt}},
         state,
         path
       ) do
    # Only the real cache server's put protocol receives these slots.
    if cache_message?(state) do
      state
      |> then(&term(af, bf, &1, path ++ [1]))
      |> then(&cache_key(ak, bk, &1, path ++ [2, 1]))
      |> then(&term(ae, be, &1, path ++ [2, 2]))
      |> then(&term(at, bt, &1, path ++ [2, 3]))
    else
      list(
        [:"$gen_call", af, {:put, ak, ae, at}],
        [:"$gen_call", bf, {:put, bk, be, bt}],
        state,
        path,
        0
      )
    end
  end

  defp term({key, a}, {key, b}, state, path)
       when key in [
              :id,
              :claim_id,
              :operation_hash,
              :response_codec,
              :response_digest,
              :encoded_response,
              :payload,
              :digest
            ] do
    if keyword_slot?(state.at) do
      case key do
        :operation_hash -> derived_operation(a, b, state, path ++ [key])
        key when key in [:id, :claim_id] -> uuid_identity(a, b, state, path ++ [key])
        _ -> term(a, b, state, path ++ [key])
      end
    else
      list([key, a], [key, b], state, path, 0)
    end
  end

  defp term(a, b, state, path)
       when is_tuple(a) and is_tuple(b) and tuple_size(a) == tuple_size(b),
       do: list(Tuple.to_list(a), Tuple.to_list(b), state, path, 0)

  defp term(a, b, state, path) do
    cond do
      match?(%{mfa: {Postgrex, :prepare_execute, 5}}, state.at) and
          path == [:event, 2, 2, 1] ->
        prepared_query_name(a, b, state, path)

      scalar_operation?(state.at, path) ->
        derived_operation(a, b, state, path)

      locator_operation?(state, path) ->
        derived_operation(a, b, state, path)

      cache_key_slot?(state, path) ->
        cache_key(a, b, state, path)

      scalar_uuid?(state.at, path) ->
        uuid_identity(a, b, state, path)

      response_slot(state, path) != nil ->
        response_value(a, b, response_slot(state, path), state, path)

      a === b ->
        state

      is_atom(a) and Map.get(Registry.rename(), a, a) === b ->
        identity(a, b, state, path)

      true ->
        error(state, :o5, path, a, b)
    end
  end

  defp map(a, b, state, path) do
    fields = Registry.typed_fields(Map.get(a, :__struct__))

    {state, paired} =
      Enum.reduce(Enum.sort(Map.keys(a)), {state, MapSet.new()}, fn key, {s, paired} ->
        twin_key = map_key(key, s)

        case Map.fetch(b, twin_key) do
          {:ok, bv} ->
            s = term(key, twin_key, s, path ++ [{:key, key}])
            av = Map.fetch!(a, key)

            s =
              case Map.get(fields, key) do
                :uuid -> uuid_identity(av, bv, s, path ++ [key])
                :operation -> derived_operation(av, bv, s, path ++ [key])
                nil -> term(av, bv, s, path ++ [key])
              end

            {s, MapSet.put(paired, twin_key)}

          :error ->
            {error(s, :o5_map_key, path ++ [key], {:ok, Map.fetch!(a, key)}, :error), paired}
        end
      end)

    Enum.reduce(Enum.sort(Map.keys(b)), state, fn key, s ->
      if MapSet.member?(paired, key),
        do: s,
        else: error(s, :o5_map_key, path ++ [key], :error, {:ok, Map.fetch!(b, key)})
    end)
  end

  defp subject(a, b, state, path) do
    state = validate_subject_declaration(a, :run, state, path)
    state = validate_subject_declaration(b, :twin, state, path)
    state = context(a.context, b.context, state, path ++ [:context])
    {fields, state} = subject_attributes(a, b, state, path)
    slots = Registry.hook_slots(state.row.type)

    state =
      Enum.reduce(slots, state, fn {list, _} = slot, s ->
        index = Registry.subject_hook_index(state.row, slot)
        ah = a |> Map.get(list) |> Enum.at(index)
        bh = b |> Map.get(list) |> Enum.at(index)

        if ah == nil and bh == nil do
          s
        else
          s |> hook(ah, slot, :run, path) |> hook(bh, slot, :twin, path)
        end
      end)

    # A validated hook becomes the same declared slot on each side. Every other
    # list element, and the list's length, still goes through the exact comparison.
    a = replace_hooks(a, slots, state.row)
    b = replace_hooks(b, slots, state.row)

    term(
      Map.drop(Map.from_struct(a), [:context | fields]),
      Map.drop(Map.from_struct(b), [:context | fields]),
      state,
      path
    )
  end

  defp validate_subject_declaration(subject, side, state, path) do
    expected = Ash.Resource.Info.action(state[side].resource, state.row.action)

    if subject.action === expected,
      do: state,
      else: error(state, :o2b_action, path ++ [side, :action], subject.action, expected)
  end

  defp subject_attributes(%Ash.Changeset{} = a, b, state, path) do
    fields = [:attributes, :attribute_changes]
    typed = Registry.uuid_attributes(state.run.resource)

    state =
      Enum.reduce(fields, state, fn field, s ->
        attributes(Map.fetch!(a, field), Map.fetch!(b, field), typed, s, path ++ [field])
      end)

    {fields, state}
  end

  defp subject_attributes(_a, _b, state, _path), do: {[], state}

  defp attributes(a, b, typed, state, path) when is_map(a) and is_map(b) do
    keys = (Map.keys(a) ++ Map.keys(b)) |> Enum.uniq() |> Enum.sort()

    Enum.reduce(keys, state, fn key, s ->
      case {Map.fetch(a, key), Map.fetch(b, key)} do
        {{:ok, av}, {:ok, bv}} ->
          if key in typed,
            do: uuid_identity(av, bv, s, path ++ [key]),
            else: term(av, bv, s, path ++ [key])

        {av, bv} ->
          error(s, :o5_map_key, path ++ [key], av, bv)
      end
    end)
  end

  defp attributes(a, b, _typed, state, path), do: term(a, b, state, path)

  defp context(context, twin_context, state, path) do
    private = Map.get(context, :private, %{})

    expected = %{
      ash_onetime_delivery: %{ref: state.run.bound[:ref]},
      ash_onetime_delivery_cell: state.run.bound[:cell]
    }

    state =
      Enum.reduce(expected, state, fn {key, value}, s ->
        case Map.fetch(private, key) do
          {:ok, ^value} -> s
          :error -> s
          {:ok, actual} -> error(s, :context, path ++ [:context, :private, key], actual, value)
        end
      end)

    private = Map.drop(private, Map.keys(expected))
    twin_private = Map.get(twin_context, :private, %{})
    key = :ash_onetime_external_operation_key

    {private, state} =
      if Map.has_key?(private, key) or Map.has_key?(twin_private, key) do
        case {Map.fetch(private, key), Map.fetch(twin_private, key)} do
          {{:ok, av}, {:ok, bv}} ->
            {Map.put(private, key, bv), uuid_identity(av, bv, state, path ++ [:private, key])}

          {av, bv} ->
            {private, error(state, :o5_map_key, path ++ [:private, key], av, bv)}
        end
      else
        {private, state}
      end

    context =
      if private == %{} and not Map.has_key?(twin_context, :private),
        do: Map.delete(context, :private),
        else: Map.put(context, :private, private)

    term(context, twin_context, state, path)
  end

  defp stack_slot?(%{at: %{mfa: {Process, :info, 2}}}, [:event, 3, 1]), do: true
  defp stack_slot?(%{at: %{mfa: {:erlang, :process_info, 2}}}, [:event, 3, 1]), do: true
  defp stack_slot?(%{at: %{mfa: {:erlang, :raise, 3}}}, [:event, 2, 2, 2]), do: true

  defp stack_slot?(%{at: %{mfa: {Splode, :filter_stacktrace, 2}}}, path),
    do: path in [[:event, 2, 2, 0], [:event, 3]]

  defp stack_slot?(_state, _path), do: false

  defp stack_filters(path),
    do:
      if(Enum.count(path, &(&1 == :stacktrace)) > 1,
        do: Ash.Error.__stacktrace_filters__(),
        else: nil
      )

  defp hook(state, value, slot, side, path) do
    pre_fault? =
      case state.at do
        %{mfa: {m, f, _}} ->
          m in [AshOnetime.Change, AshOnetime.GenericAction] and
            f in [:change, :prepare, :install, :install_delivery]

        _ ->
          false
      end

    case Hooks.validate(value, slot, Map.put(state[side], :pre_fault?, pre_fault?)) do
      :ok ->
        state

      {:error, rule, expected, actual} ->
        error(state, rule, path ++ [side, slot], actual, expected)
    end
  end

  defp replace_hooks(subject, slots, row) do
    Enum.reduce(slots, subject, fn {list, _} = slot, value ->
      index = Registry.subject_hook_index(row, slot)

      Map.update!(value, list, fn hooks ->
        if length(hooks) > index,
          do: List.replace_at(hooks, index, {:declared_hook, slot}),
          else: hooks
      end)
    end)
  end

  defp historical_protocol(state, protocol, field, side, path) do
    connection =
      Enum.find_value(state[side].historical.connections, fn {_holder, c} ->
        if c.protocol.sock == protocol.sock, do: c
      end)

    expected =
      if connection, do: Map.fetch!(connection.protocol, field), else: :missing_connection_origin

    actual = Map.fetch!(protocol, field)

    if actual === expected,
      do: state,
      else: error(state, :historical_connection, path ++ [side, field], actual, expected)
  end

  defp historical_backend(a, b, state, path) do
    left =
      Enum.find_value(state.run.historical.connections, fn {holder, c} ->
        if c.protocol.connection_id === a, do: {holder, c}
      end)

    right =
      Enum.find_value(state.twin.historical.connections, fn {holder, c} ->
        if c.protocol.connection_id === b, do: {holder, c}
      end)

    case {left, right} do
      {{ah, _}, {bh, _}} -> identity(ah, bh, state, path)
      _ -> error(state, :historical_backend, path, a, b)
    end
  end

  # OPEN's SQL witness never gets to rename a backend independently of the
  # whole run. Every typed result copy also binds to the checkpoint's actual
  # allocation under that same map, including identities used by earlier leases.
  defp readback_backends(%Postgrex.Result{connection_id: id}, backend, state, path),
    do: historical_backend(id, backend, state, path ++ [:connection_id])

  defp readback_backends(%Postgrex.Error{connection_id: id}, backend, state, path),
    do: historical_backend(id, backend, state, path ++ [:connection_id])

  defp readback_backends(value, backend, state, path) when is_map(value),
    do:
      Enum.reduce(Map.to_list(value), state, fn {key, item}, s ->
        readback_backends(item, backend, s, path ++ [key])
      end)

  defp readback_backends(value, backend, state, path) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce(state, fn {item, n}, s ->
        readback_backends(item, backend, s, path ++ [n])
      end)

  defp readback_backends(value, backend, state, path) when is_function(value) do
    {:env, env} = Function.info(value, :env)
    readback_backends(env, backend, state, path ++ [:function, :env])
  end

  defp readback_backends([head | tail], backend, state, path) do
    state = readback_backends(head, backend, state, path ++ [0])
    readback_backends(tail, backend, state, path ++ [:tail])
  end

  defp readback_backends(_, _, state, _), do: state

  defp query_context(a, b, state) do
    run_sql = event_sql(a.event) || Map.fetch!(state.query_contexts.run, a.index)
    twin_sql = event_sql(b.event) || Map.fetch!(state.query_contexts.twin, b.index)

    %{state | current: %{run: a, twin: b, run_sql: run_sql, twin_sql: twin_sql}}
  end

  defp current_sql(%{current: nil}, _), do: nil
  defp current_sql(state, :run), do: state.current.run_sql
  defp current_sql(state, :twin), do: state.current.twin_sql

  defp event_sql(event), do: DatabaseOrigins.sql(event)

  defp parameter_columns(sql) when is_binary(sql) do
    assignments =
      Regex.scan(~r/([a-z_]+)\s*=\s*\$(\d+)/, sql)
      |> Map.new(fn [_, name, n] -> {String.to_integer(n), name} end)

    assignments =
      if String.starts_with?(sql, "INSERT INTO ") and
           String.contains?(sql, "ash_onetime_idempotency_claims") and
           String.contains?(sql, "transaction_timestamp() + ($7::bigint * interval '1 second')"),
         do: Map.put(assignments, 7, "claim_retention_seconds"),
         else: assignments

    case Regex.run(~r/INSERT INTO .*?\((.*?)\)\s*VALUES\s*\((.*?)\)/s, sql) do
      [_, names, expressions] ->
        Enum.zip(String.split(names, ","), String.split(expressions, ","))
        |> Enum.reduce(assignments, fn {name, expression}, acc ->
          case Regex.run(~r/^\s*\$(\d+)/, expression) do
            [_, n] ->
              Map.put(acc, String.to_integer(n), name |> String.trim() |> String.trim("\""))

            _ ->
              acc
          end
        end)

      _ ->
        assignments
    end
  end

  defp parameter_columns(_), do: %{}

  defp parameter_list?(%{at: %{mfa: mfa}}, [:event | path]),
    do: path in DatabaseOrigins.parameter_paths(mfa)

  defp parameter_list?(_, _), do: false

  defp encoded_parameters?(%{at: %{mfa: {Postgrex.Protocol, :handle_execute, 4}}}, [
         :event,
         2,
         2,
         1
       ]),
       do: true

  defp encoded_parameters?(_, _), do: false

  defp encoded_parameters(a, b, state, path) do
    query = state.current.run.event |> elem(2) |> elem(2) |> hd()
    twin_query = state.current.twin.event |> elem(2) |> elem(2) |> hd()

    if length(a) == length(b) and length(a) == length(query.param_oids) do
      columns = parameter_columns(current_sql(state, :run))

      Enum.zip(a, b)
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{a, b}, n}, s ->
        oid = Enum.at(query.param_oids, n)
        twin_oid = Enum.at(twin_query.param_oids, n)
        s = term(oid, twin_oid, s, path ++ [n, :oid])
        # Postgrex's binary-parameter representation has a documented four-byte
        # length prefix. Validate that framing before checking the typed payload.
        case {encoded_parameter(a, oid), encoded_parameter(b, twin_oid)} do
          {{:ok, av}, {:ok, bv}} -> column_value(av, bv, columns[n + 1], s, path ++ [n, :value])
          _ -> error(s, :encoded_parameter, path ++ [n], a, b)
        end
      end)
    else
      error(state, :encoded_parameter_count, path, length(a), length(b))
    end
  end

  defp encoded_parameter(value, oid) do
    case IO.iodata_to_binary(value) do
      <<-1::signed-32>> ->
        {:ok, nil}

      <<n::signed-32, bytes::binary-size(n)>> ->
        case {oid, bytes} do
          {2950, <<_::128>>} -> {:ok, Ecto.UUID.load!(bytes)}
          _ -> {:ok, bytes}
        end

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parameters(a, b, %{current: %{run_sql: nil}} = state, path)
       when is_list(a) and is_list(b) and (a != [] or b != []),
       do: error(state, :query_statement_origin, path, :missing_run_statement, :query_instance)

  defp parameters(a, b, %{current: %{twin_sql: nil}} = state, path)
       when is_list(a) and is_list(b) and (a != [] or b != []),
       do: error(state, :query_statement_origin, path, :missing_twin_statement, :query_instance)

  defp parameters(a, b, state, path) when is_list(a) and is_list(b) do
    if length(a) == length(b) do
      columns = parameter_columns(current_sql(state, :run))

      Enum.zip(a, b)
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{a, b}, n}, s ->
        column_value(a, b, columns[n + 1], s, path ++ [n])
      end)
    else
      error(state, :query_parameter_count, path, length(a), length(b))
    end
  end

  defp parameters(a, b, state, path) do
    if a === b, do: state, else: error(state, :query_parameters, path, a, b)
  end

  defp column_value(a, b, "claim_retention_seconds", state, path) do
    state = claim_bind_copy(a, :run, state, path)
    state = claim_bind_copy(b, :twin, state, path)
    term(a, b, state, path)
  end

  defp column_value(
         {:database_expression, _} = a,
         {:database_expression, _} = b,
         name,
         state,
         path
       )
       when name in ["partition_date", "response_partition"], do: term(a, b, state, path)

  defp column_value(a, b, name, state, path)
       when name in ["partition_date", "response_partition"] do
    if match?(%{mfa: {Postgrex.Protocol, :handle_execute, 4}}, state.at) and
         List.last(path) == :value do
      state = database_date_copy(a, :run, state, path)
      database_date_copy(b, :twin, state, path)
    else
      term(a, b, state, path)
    end
  end

  defp column_value(a, b, "operation_hash", state, path) do
    if a === nil and b === nil and plain_outcome_projection?(state),
      do: state,
      else: derived_operation(a, b, state, path)
  end

  # The observation query exposes optional physical outcome-key columns through
  # to_jsonb. Ground their absence in the independently captured complete rows,
  # not in the NULL value being checked. Hash-layout rows retain O2a binding.
  defp plain_outcome_projection?(state) do
    Enum.all?([:run, :twin], fn side ->
      database = elem(state.databases, if(side == :run, do: 0, else: 1))
      table = database.statements.outcome.table
      before = Map.get(state[side], :before, %{})

      rows =
        Map.get(before, table, []) ++
          Map.get(state[side].delta, table, %{added: []}).added

      current_sql(state, side) == database.outcome_probe_sql and rows != [] and
        Enum.all?(rows, &(not Map.has_key?(&1, "operation_hash")))
    end)
  end

  defp column_value({:uuid, a}, {:uuid, b}, _name, state, path),
    do: uuid_identity(a, b, state, path)

  defp column_value(a, b, name, state, path) when name in ["id", "claim_id", "operation_key"],
    do: uuid_identity(a, b, state, path)

  defp column_value(a, b, name, state, path)
       when name in ["response_codec", "encoded_response", "response_digest"],
       do:
         response_value(
           a,
           b,
           %{
             "response_codec" => :codec,
             "encoded_response" => :payload,
             "response_digest" => :digest
           }[name],
           state,
           path
         )

  defp column_value(a, b, _name, state, path), do: term(a, b, state, path)

  defp database_date_copy(value, side, state, path) do
    list_path =
      case List.last(path) do
        :value -> Enum.drop(path, -2)
        4 -> Enum.drop(path, -2)
        _ -> Enum.drop(path, -1)
      end

    source = state.current[side].event
    parameters = event_value(source, tl(list_path))
    database = elem(state.databases, if(side == :run, do: 0, else: 1))
    sql = current_sql(state, side)
    {actual, expected} = DatabaseOrigins.date_copy(value, parameters, sql, database)

    if actual === expected,
      do: state,
      else: error(state, :o4_date_copy, path ++ [side], actual, expected)
  end

  defp response_slot(%{at: %{mfa: {AshOnetime.Admission, f, _}}}, [
         :event,
         2,
         2,
         n,
         key
       ])
       when key in [:codec, :digest, :payload] do
    if (f in [:persist_encoded, :persist_completion] and n == 1) or
         (f == :validate_complete and n == 2),
       do: key
  end

  defp response_slot(%{at: %{mfa: {AshOnetime.Store, f, _}}}, [:event, 2, 2, n])
       when f in [:complete, :complete_external],
       do: %{2 => :codec, 3 => :digest, 4 => :payload}[n]

  defp response_slot(%{at: %{mfa: {AshOnetime.Store.Postgres, f, _}}}, [:event, 2, 2, n])
       when f in [
              :complete,
              :complete_external,
              :complete_transaction,
              :complete_mode,
              :"-complete_mode/7-fun-1-",
              :"-complete_external/7-fun-1-"
            ],
       do: %{2 => :codec, 3 => :digest, 4 => :payload}[n]

  defp response_slot(%{at: %{mfa: {AshOnetime.Store.Postgres, :validate_completion, 3}}}, [
         :event,
         2,
         2,
         n
       ]),
       do: %{0 => :codec, 1 => :digest, 2 => :payload}[n]

  defp response_slot(%{at: %{mfa: {AshOnetime.Store.Postgres, :insert_payload, 4}}}, [
         :event,
         2,
         2,
         3
       ]),
       do: :payload

  defp response_slot(%{at: %{mfa: {AshOnetime.Store.Postgres, :update_complete, 7}}}, [
         :event,
         2,
         2,
         n
       ]),
       do: %{3 => :codec, 4 => :digest}[n]

  defp response_slot(%{at: %{mfa: {m, :fixed_digest_equal?, 2}}}, [:event, 2, 2, n])
       when m in [AshOnetime.Admission, AshOnetime.Store.Postgres] and n in [0, 1], do: :digest

  defp response_slot(%{at: %{mfa: {:crypto, f, arity}, stack: stack}}, path)
       when f in [:hash, :hash_nif] and arity in [2, 4] do
    if Enum.any?(stack, fn {m, f, _} ->
         m in [AshOnetime.Admission, AshOnetime.Store.Postgres, AshOnetime.Cache] and
           f in [:validate_complete, :validate_completion, :loaded_result, :valid_entry?]
       end) do
      case path do
        [:event, 2, 2, 1] -> :payload
        [:event, 3] -> :digest
        _ -> nil
      end
    end
  end

  defp response_slot(%{at: %{mfa: {:crypto, f, 2}, stack: stack}} = state, [:event, 2, 2, n])
       when f in [:hash_equals, :hash_equals_nif] and n in [0, 1] do
    if not cache_fingerprint_comparison?(state) and
         Enum.any?(stack, fn {m, f, a} ->
           m in [AshOnetime.Admission, AshOnetime.Store.Postgres, AshOnetime.Cache] and
             f in [:fixed_digest_equal?, :fixed_equal?] and a == 2
         end),
       do: :digest
  end

  defp response_slot(%{at: %{mfa: {AshOnetime.Admission, :validate_collision_payload, 2}}}, [
         :event,
         2,
         2,
         1
       ]),
       do: :payload

  defp response_slot(%{at: %{mfa: {AshOnetime.Cache, :fixed_equal?, 2}}} = state, [
         :event,
         2,
         2,
         n
       ])
       when n in [0, 1] do
    if not cache_fingerprint_comparison?(state), do: :digest
  end

  defp response_slot(%{at: %{mfa: {AshOnetime.Cache, :store, 3}}}, [:event, 2, 2, 2]),
    do: :payload

  defp response_slot(%{at: %{mfa: {AshOnetime.Store.Postgres, function, _}}}, [:event, 2, 2, n]) do
    case Registry.function_slots(AshOnetime.Store.Postgres, function)[n] do
      {:response, key} -> key
      _ -> nil
    end
  end

  defp response_slot(%{at: %{mfa: {AshOnetime.Store.Result, _, _}}}, path) do
    if List.last(path) == :payload, do: :payload
  end

  defp response_slot(_, _), do: nil

  defp cache_fingerprint_comparison?(state) do
    # valid_entry?'s first equality checks the request fingerprint; its later
    # equalities check response digests. The source frame and occurrence select
    # the slot, never the compared bytes.
    Enum.all?([:run, :twin], fn side ->
      index = at_index(state.at, if(side == :run, do: :run_index, else: :twin_index))

      if is_integer(index) do
        events = Enum.take(state[side].run.events, index + 1)

        start =
          Enum.find_index(Enum.reverse(events), fn
            %{event: {_, :call, {AshOnetime.Cache, :valid_entry?, _}}} -> true
            _ -> false
          end)

        if start do
          events
          |> Enum.take(-start - 1)
          |> Enum.count(&match?(%{event: {_, :call, {AshOnetime.Cache, :fixed_equal?, _}}}, &1))
          |> Kernel.==(1)
        else
          false
        end
      else
        false
      end
    end)
  end

  defp row_state(state, a, b),
    do: %{state | current: Map.put(state.current || %{}, :row_states, {a, b})}

  defp wire_claim_state(columns) when is_list(columns) do
    names =
      Enum.map(columns, fn
        {:data_column, _, _, _, name, _, _, _, _, _} -> name
        _ -> :undeclared_column
      end)

    claim_columns = Registry.database_statements().claim.columns

    layouts = [claim_columns, claim_columns ++ ["encoded_response", "outcome"]]

    # SELECT * follows the installed relation's physical column order. Keep that
    # order in the comparison while recognizing the same complete projection.
    if Enum.any?(layouts, &(Enum.sort(names) == Enum.sort(&1))) do
      Enum.find_value(columns, fn
        {:data_column, _, _, _, "state", _, _, _, _, value} -> value
        _ -> nil
      end)
    end
  end

  defp wire_claim_state(_), do: nil

  defp nullable_response?(%{current: %{row_states: {a, b}}})
       when a in [:admitted, :processing, :collision, :failure, "processing", "collision"] and
              a == b,
       do: true

  defp nullable_response?(%{current: %{run: a, twin: b}}) do
    case {a.event, b.event} do
      {{_, :call, {AshOnetime.Admission, :validate_collision_payload, [status, _]}},
       {_, :call, {AshOnetime.Admission, :validate_collision_payload, [status, _]}}}
      when status in [:processing, :collision] ->
        true

      _ ->
        false
    end
  end

  defp nullable_response?(_), do: false

  defp response_value(a, b, key, state, path) do
    expected = fn side, derivations ->
      index =
        case state.at do
          %{run_index: n} when side == :run -> n
          %{twin_index: n} -> n
          _ -> 1_000_000_000
        end

      derivations.sources
      |> Enum.filter(fn {{root, n}, _} ->
        root == {AshOnetime.Response, :encode, 3} and n < index
      end)
      |> Enum.max_by(fn {{_, n}, _} -> n end, fn -> {nil, :missing_encode_source} end)
      |> elem(1)
      |> case do
        {:ok, encoded} -> Map.fetch!(encoded, key)
        other -> other
      end
    end

    {rd, td} = state.derivations
    ea = expected.(:run, rd)
    eb = expected.(:twin, td)

    # NULL belongs to a processing/collision row or its checked payload call.
    # Completed copies stay bound to encode, including a missing payload.
    empty? = a === nil and b === nil and nullable_response?(state)

    if empty? or (a === ea and b === eb),
      do: state,
      else: error(state, :response_copy, path, a, b)
  end

  defp locator_operation?(%{current: %{run: a, twin: b}} = state, path) do
    path in Map.get(state.run.operation_copies, a.index, []) and
      path in Map.get(state.twin.operation_copies, b.index, [])
  end

  defp locator_operation?(_, _), do: false

  defp sql_frame?(%{at: %{mfa: {m, _, _}}}),
    do:
      m in [
        Ecto.Adapters.SQL,
        Postgrex,
        DBConnection,
        Postgrex.Protocol,
        DBConnection.LogEntry,
        :telemetry
      ]

  defp sql_frame?(_), do: false
  defp cast_parameters?(state, path), do: sql_frame?(state) and List.last(path) == :cast_params

  defp cache_arguments?(%{at: %{mfa: {AshOnetime.Cache, f, 3}}}, [:event, 2, 2, 2])
       when f in [:invoke, :safe_apply], do: true

  defp cache_arguments?(%{at: %{mfa: {AshOnetime.Cache, :"-invoke/3-fun-0-", 3}}}, [
         :event,
         2,
         2,
         1
       ]),
       do: true

  defp cache_arguments?(_, _), do: false

  defp cache_arguments([ak | aa], [bk | ba], state, path) do
    state = cache_key(ak, bk, state, path ++ [0])
    list(aa, ba, state, path, 1)
  end

  defp cache_arguments(a, b, state, path), do: error(state, :cache_arguments, path, a, b)

  defp cache_key_slot?(%{at: %{mfa: {AshOnetime.Cache, :persist, 4}}}, [:event, 2, 2, 1]),
    do: true

  defp cache_key_slot?(%{at: %{mfa: {AshOnetime.Cache.Ets, f, _}}}, [:event, 2, 2, 0])
       when f in [:put, :get, :delete], do: true

  defp cache_key_slot?(%{at: %{mfa: {AshOnetime.Cache.Ets, :handle_call, 3}}}, [
         :event,
         2,
         2,
         0,
         1
       ]),
       do: true

  defp cache_key_slot?(%{at: %{mfa: {:ets, :insert, 2}, stack: stack}}, [:event, 2, 2, 1, 0]),
    do: {AshOnetime.Cache.Ets, :handle_call, 3} in stack

  defp cache_key_slot?(%{at: %{mfa: {:ets, :lookup, 2}, stack: stack}}, path) do
    {AshOnetime.Cache.Ets, :get, 1} in stack and
      path in [[:event, 2, 2, 1], [:event, 3, 0, 0]]
  end

  defp cache_key_slot?(_, _), do: false

  defp cache_message?(%{current: %{run: a}}),
    do:
      a.pid == Process.whereis(AshOnetime.Cache.Ets) or {AshOnetime.Cache.Ets, :put, 3} in a.stack

  defp cache_message?(_), do: false

  defp cache_key(a, b, state, path) do
    {rd, td} = state.derivations
    ea = latest_source(rd, {AshOnetime.Cache, :key, 1}, state, :run)
    eb = latest_source(td, {AshOnetime.Cache, :key, 1}, state, :twin)
    if a === ea and b === eb, do: state, else: error(state, :cache_key_copy, path, a, b)
  end

  defp latest_source(derivations, root, state, side) do
    index =
      case state.at do
        %{run_index: n} when side == :run -> n
        %{twin_index: n} -> n
        _ -> 1_000_000_000
      end

    derivations.sources
    |> Enum.filter(fn {{mfa, n}, _} -> mfa == root and n < index end)
    |> Enum.max_by(fn {{_, n}, _} -> n end, fn -> {nil, :missing_derived_source} end)
    |> elem(1)
  end

  defp store(a, b, state) do
    {a, state} = store_date_copies(a, :run, state)
    {b, state} = store_date_copies(b, :twin, state)
    tables = (Map.keys(a) ++ Map.keys(b)) |> Enum.uniq() |> Enum.sort()

    Enum.reduce(tables, state, fn table, s ->
      case {Map.fetch(a, table), Map.fetch(b, table)} do
        {{:ok, ar}, {:ok, br}} ->
          Enum.reduce([:added, :removed], s, fn direction, s ->
            if length(ar[direction]) == length(br[direction]) do
              Enum.zip(ar[direction], br[direction])
              |> Enum.with_index()
              |> Enum.reduce(s, fn {{x, y}, n}, s ->
                store_row(x, y, table, s, [:store, table, direction, n])
              end)
            else
              error(
                s,
                :store_row_count,
                [:store, table, direction],
                length(ar[direction]),
                length(br[direction])
              )
            end
          end)

        {av, bv} ->
          error(s, :store_table, [:store, table], av, bv)
      end
    end)
  end

  defp store_date_copies(delta, side, state) do
    database = elem(state.databases, if(side == :run, do: 0, else: 1))

    delta
    |> Enum.sort()
    |> Enum.reduce({%{}, state}, fn {table, changes}, {tables, state} ->
      Enum.reduce([:added, :removed], {tables, state}, fn direction, {tables, state} ->
        Enum.with_index(changes[direction])
        |> Enum.reduce({tables, state}, fn {row, n}, {tables, state} ->
          case DatabaseOrigins.payload_snapshot(table, row, database) do
            {:ok, relation, row} ->
              empty = %{added: [], removed: []}

              tables =
                Map.update(tables, relation, Map.put(empty, direction, [row]), fn old ->
                  Map.update!(old, direction, &(&1 ++ [row]))
                end)

              {tables, state}

            {:error, actual, expected} ->
              path = [:store, table, direction, n, :database_copy, side]
              state = error(state, :o4_payload_snapshot, path, actual, expected)
              empty = %{added: [], removed: []}

              tables =
                Map.update(tables, table, Map.put(empty, direction, [row]), fn old ->
                  Map.update!(old, direction, &(&1 ++ [row]))
                end)

              {tables, state}
          end
        end)
      end)
    end)
  end

  defp store_row(a, b, table, state, path) do
    {rdb, tdb} = state.databases
    statements = Registry.database_statements()
    claim? = table == statements.claim.table
    columns = (Map.keys(a) ++ Map.keys(b)) |> Enum.uniq() |> Enum.sort()
    previous = state.current
    state = if claim?, do: row_state(state, a["state"], b["state"]), else: state

    state =
      Enum.reduce(columns, state, fn column, s ->
        case {Map.fetch(a, column), Map.fetch(b, column)} do
          {{:ok, av}, {:ok, bv}} ->
            cond do
              claim? and column in (statements.claim.clocks ++ ["response_partition"]) ->
                ea = snapshot_origin(a, column, rdb)
                eb = snapshot_origin(b, column, tdb)

                if av === ea and bv === eb,
                  do: s,
                  else: error(s, :o4_snapshot_copy, path ++ [column], av, bv)

              table == statements.outcome.table and column in statements.outcome.clocks ->
                ea = DatabaseOrigins.outcome_snapshot(a, rdb)
                eb = DatabaseOrigins.outcome_snapshot(b, tdb)

                if av === ea and bv === eb,
                  do: s,
                  else: error(s, :o4_outcome_snapshot, path ++ [column], av, bv)

              table in statements.peer.tables and column in statements.peer.clocks ->
                ea = peer_snapshot_origin(a, table, rdb)
                eb = peer_snapshot_origin(b, table, tdb)

                if av === ea and bv === eb,
                  do: s,
                  else: error(s, :o4_peer_snapshot, path ++ [column], av, bv)

              true ->
                column_value(av, bv, column, s, path ++ [column])
            end

          {av, bv} ->
            error(s, :o5_map_key, path ++ [column], av, bv)
        end
      end)

    %{state | current: previous}
  end

  defp peer_snapshot_origin(row, table, database) do
    identity =
      row["event_id"] ||
        case row["operation_key"] do
          <<_::128>> = id -> Ecto.UUID.load!(id)
          id -> id
        end

    case Map.fetch(database.peer_rows, {table, identity}) do
      {:ok, source} -> source["inserted_at"]
      :error -> :missing_peer_returning
    end
  end

  defp snapshot_origin(row, column, database) do
    id =
      case row["id"] do
        <<_::128>> = id -> Ecto.UUID.load!(id)
        id -> id
      end

    case Map.fetch(database.rows, {id, row["state"]}) do
      {:ok, source} -> Map.fetch!(source, column)
      :error -> :missing_wire_row
    end
  end

  defp keyword_slot?(%{mfa: {module, _, _}}),
    do:
      module in [
        AshOnetime.Store.Claim,
        AshOnetime.Store.Claim.Request,
        AshOnetime.Store.Claim,
        AshOnetime.Store.Result
      ]

  defp keyword_slot?(_), do: false

  defp scalar_operation?(%{mfa: {AshOnetime.Admission, :claim_request, 6}}, [:event, 2, 2, 1]),
    do: true

  defp scalar_operation?(%{mfa: {AshOnetime.Store.Postgres, :logical_key, a}}, [:event, 3, 1])
       when a in [1, 2], do: true

  defp scalar_operation?(%{mfa: {AshOnetime.Store.Postgres, :select_claim, _}}, [
         :event,
         2,
         2,
         2,
         1
       ]),
       do: true

  defp scalar_operation?(_, _), do: false

  defp scalar_uuid?(%{mfa: {AshOnetime.Store.Postgres, f, 1}}, path)
       when f in [:dump_uuid, :decode_uuid],
       do: path in [[:event, 2, 2, 0], [:event, 3]]

  defp scalar_uuid?(%{mfa: {AshOnetime.Store.Postgres, :insert_payload, 4}}, [:event, 2, 2, 2]),
    do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.Store.Postgres, :caller_lock_mode, 1}}, [:event, 2, 2, 0]),
    do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.Admission, :valid_uuid?, 1}}, [:event, 2, 2, 0]), do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.ExternalRecovery, :validate_operation_key, 1}}, [
         :event,
         2,
         2,
         0
       ]),
       do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.ExternalRecovery, :safe_execute, 5}}, [:event, 2, 2, 1]),
    do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.ExternalRecovery, :settle_unknown_execute, 6}}, [
         :event,
         2,
         2,
         3
       ]),
       do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.ExternalRecovery, :execute_then_settle, 7}}, [
         :event,
         2,
         2,
         4
       ]),
       do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.Store.Postgres, :select_claim, arity}}, [:event, 2, 2, 3])
       when arity in [4, 5], do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.Store.Postgres, :select_claim_under_timeout, 4}}, [
         :event,
         2,
         2,
         2
       ]),
       do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.Test.ExitBoundary.External, :execute, 3}}, [
         :event,
         2,
         2,
         0
       ]),
       do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.ExternalEffect, :put_result, 3}}, [:event, 2, 2, 1]),
    do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.ExternalEffect, :operation_key, 1}}, [:event, 3, 1]),
    do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.Test.ExternalPeer, f, _}}, path) do
    case f do
      f when f in [:execute, :recover] ->
        path == [:event, 2, 2, 1]

      f
      when f in [
             :execute_in_transaction,
             :"-execute/4-fun-0-",
             :"-execute/4-fun-1-",
             :recover_in_transaction,
             :recover_transaction,
             :load_operation,
             :"-recover/4-fun-0-",
             :"-recover_transaction/4-fun-0-"
           ] ->
        path == [:event, 2, 2, 2]

      _ ->
        false
    end
  end

  defp scalar_uuid?(%{mfa: {AshOnetime.Cache, :valid_uuid?, 1}}, [:event, 2, 2, 0]), do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.ExternalRecovery, :recover_processing, 7}}, [
         :event,
         2,
         2,
         4
       ]),
       do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.ExternalRecovery, :safe_recover, 4}}, [:event, 2, 2, 1]),
    do: true

  defp scalar_uuid?(%{mfa: {AshOnetime.Test.ExitBoundary.External, :recover, 3}}, [
         :event,
         2,
         2,
         0
       ]),
       do: true

  defp scalar_uuid?(_, _), do: false

  defp prepared_query_name(a, b, state, path) do
    {run, twin} = state.queries

    case {AshOnetime.Test.ExitBoundary.QueryOrigins.expected_name(run, current_sql(state, :run)),
          AshOnetime.Test.ExitBoundary.QueryOrigins.expected_name(twin, current_sql(state, :twin))} do
      {{:ok, run_name}, {:ok, twin_name}} ->
        if a === run_name and b === twin_name,
          do: state,
          else: error(state, :o2a_query_name, path, a, b)

      _ ->
        if a === b, do: state, else: error(state, :o2a_query_name, path, a, b)
    end
  end

  defp derived_operation(a, b, state, path) do
    {:ok, expected_a} = Registry.operation(state.run.resource, state.row.action)
    {:ok, expected_b} = Registry.operation(state.twin.resource, state.row.action)

    if a === expected_a and b === expected_b,
      do: state,
      else: error(state, :o2a_operation, path, a, b)
  end

  defp uuid_identity(a, b, state, path) do
    normalize = fn
      <<_::128>> = uuid -> Ecto.UUID.load!(uuid)
      uuid -> uuid
    end

    a = normalize.(a)
    b = normalize.(b)

    exact? =
      a === b and
        Map.get(state.pairing.uuid_forward, a, a) === b and
        Map.get(state.pairing.uuid_reverse, b, b) === a

    if exact? or
         (Map.fetch(state.pairing.uuid_forward, a) === {:ok, b} and
            Map.fetch(state.pairing.uuid_reverse, b) === {:ok, a}),
       do: state,
       else: error(state, :o2_uuid, path, a, b)
  end

  defp map_key(key, state) when is_pid(key) or is_reference(key) or is_port(key),
    do: Map.get(state.pairing.forward, key, key)

  defp map_key(key, _state) when is_atom(key), do: Map.get(Registry.rename(), key, key)

  defp map_key(key, state) when is_tuple(key),
    do: key |> Tuple.to_list() |> Enum.map(&map_key(&1, state)) |> List.to_tuple()

  defp map_key([], _state), do: []
  defp map_key([head | tail], state), do: [map_key(head, state) | map_key(tail, state)]

  defp map_key(key, state) when is_map(key),
    do: Map.new(key, fn {k, v} -> {map_key(k, state), map_key(v, state)} end)

  defp map_key(key, _state), do: key

  defp identity(a, b, state, path) do
    exact? =
      a === b and Map.get(state.pairing.forward, a, a) === b and
        Map.get(state.pairing.reverse, b, b) === a

    if exact? or
         (Map.fetch(state.pairing.forward, a) === {:ok, b} and
            Map.fetch(state.pairing.reverse, b) === {:ok, a}),
       do: state,
       else: error(state, :o2_identity, path, a, b)
  end

  # Whole-return copies have no event index at which DatabaseOrigins can project
  # them. A typed Claim still has to equal its own captured wire fields first.
  defp claim_clock_copies(claim, side, state, path) do
    database = elem(state.databases, if(side == :run, do: 0, else: 1))

    case DatabaseOrigins.claim(claim, database) do
      {:ok, fields} ->
        Enum.reduce(fields, {claim, state}, fn {key, expected}, {copy, s} ->
          token = {:database_expression, {:claim_column, key}}
          actual = Map.fetch!(copy, key)

          if actual === expected or actual === token,
            do: {Map.put(copy, key, token), s},
            else: {copy, error(s, :o4_claim_copy, path ++ [side, key], actual, expected)}
        end)

      :error ->
        {claim, error(state, :o4_claim_origin, path ++ [side], claim.id, :captured_wire_claim)}
    end
  end

  defp claim_bind_copy(value, side, state, path) do
    source = state.current[side].event
    database = elem(state.databases, if(side == :run, do: 0, else: 1))
    sql = Map.fetch!(state.current, if(side == :run, do: :run_sql, else: :twin_sql))

    {list_path, encoded?} =
      case Enum.take(path, -1) do
        [:value] -> {Enum.drop(path, -2), true}
        [4] -> {Enum.drop(path, -2), false}
        _ -> {Enum.drop(path, -1), false}
      end

    parameters = event_value(source, tl(list_path))

    id =
      case hd(parameters) do
        {:bind_column, 1, 2950, _, {:uuid, id}} ->
          id

        first when encoded? ->
          {:ok, id} = encoded_parameter(first, 2950)
          id

        <<_::128>> = id ->
          Ecto.UUID.load!(id)

        id ->
          id
      end

    value =
      case value do
        <<seconds::signed-64>> -> seconds
        seconds -> seconds
      end

    case Map.fetch(database.claim_binds, {sql, id}) do
      {:ok, ^value} -> state
      expected -> error(state, :o4_bind_copy, path ++ [side], value, expected)
    end
  end

  defp event_value(value, []), do: value

  defp event_value(value, [:function, :env | rest]) when is_function(value) do
    {:env, environment} = Function.info(value, :env)
    event_value(environment, rest)
  end

  defp event_value(value, [key | rest]) when is_tuple(value),
    do: event_value(elem(value, key), rest)

  defp event_value(value, [key | rest]) when is_list(value),
    do: event_value(Enum.fetch!(value, key), rest)

  defp event_value(value, [key | rest]) when is_map(value),
    do: event_value(Map.fetch!(value, key), rest)

  defp list([], [], state, _, _), do: state

  defp list([a | as], [b | bs], state, path, n),
    do: list(as, bs, term(a, b, state, path ++ [n]), path, n + 1)

  defp list(a, b, state, path, n), do: term_tail(a, b, state, path ++ [n])

  defp term_tail(a, b, state, path) when not is_list(a) and not is_list(b),
    do: term(a, b, state, path)

  defp term_tail(a, b, state, path), do: error(state, :o5_list, path, a, b)

  defp error(state, rule, path, run, twin),
    do: %{
      state
      | errors: [%{at: state.at, rule: rule, path: path, run: run, twin: twin} | state.errors]
    }
end
