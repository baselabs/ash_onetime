defmodule AshOnetime.Test.ExitBoundary.Origins do
  alias AshOnetime.Test.ExitBoundary.FailureTwins
  alias AshOnetime.Test.ExitBoundary.HostCall
  alias AshOnetime.Test.ExitBoundary.PermittedTrace
  alias AshOnetime.Test.ExitBoundary.Registry
  @moduledoc false

  def build(side) do
    initial = %{
      roles: %{side.run.snapshot.root => :caller},
      role_counts: %{},
      counts: %{},
      origins: %{},
      reads: %{},
      phase: %{},
      events: [],
      index: 0,
      pending: %{},
      identities: %{},
      relations: side.historical.relations,
      query_cache: side.historical.query_cache
    }

    used_keys =
      for %{event: {_, :call, {:ets, :lookup, [table, key]}}} <- side.run.events,
          table == side.historical.query_cache.table,
          do: key

    initial =
      put_in(
        initial.query_cache.rows,
        Enum.filter(initial.query_cache.rows, &(elem(&1, 0) in used_keys))
      )

    Enum.reduce(side.run.events, initial, &event(&1, &2, side))
    |> Map.update!(:events, &Enum.reverse/1)
    |> existing_identities(side)
  end

  defp event(e, state, side) do
    state = spawn_role(e.event, state)
    {role, state} = role(e.pid, state)
    phase = Map.get(state.phase, role, Map.get(side, :origin_phase_override, :pre_arm))
    phase = Registry.phase(e.event, phase)
    phase = Registry.hook_phase(e.event, phase, side.hooks, side.hook_frames)

    stack =
      Enum.reject(
        e.stack,
        &(PermittedTrace.frame?(&1) or FailureTwins.fault_frame?(&1))
      )
      |> Enum.map(&rename_frame(&1, side))

    e = Map.merge(e, %{role: role, phase: phase, index: state.index})

    state = %{
      state
      | phase: Map.put(state.phase, role, phase),
        events: [e | state.events],
        index: state.index + 1
    }

    case e.event do
      {_, :return_from, mfa, value} ->
        cond do
          mfa in Registry.generators() ->
            origin(state, :generated, role, phase, stack, mfa, value, e.index)

          mfa in Registry.clocks() ->
            origin(state, :clock, role, phase, stack, mfa, value, e.index)

          true ->
            state
        end

      _ ->
        state
    end
  end

  defp origin(state, type, role, phase, stack, mfa, value, index) do
    base = {role, phase, stack, mfa}
    ordinal = Map.get(state.counts, base, 0)
    key = {role, phase, stack, mfa, ordinal}
    field = if type == :clock, do: :reads, else: :origins

    state
    |> Map.update!(field, &Map.put(&1, key, %{value: value, index: index}))
    |> Map.update!(:counts, &Map.put(&1, base, ordinal + 1))
  end

  defp rename_frame({m, f, a}, side) do
    case Map.get(side.hook_frames, {m, f, a}) do
      nil when f == :install_delivery and m in [AshOnetime.Change, AshOnetime.GenericAction] ->
        {m, :install, a - 1}

      nil ->
        {Map.get(Registry.rename(), m, m), f, a}

      canonical ->
        canonical
    end
  end

  defp spawn_role({parent, :spawn, child, _}, state) do
    {parent_role, state} = role(parent, state)
    count = Map.get(state.role_counts, {:spawn, parent_role}, 0)

    %{
      state
      | roles: Map.put(state.roles, child, {:spawned, parent_role, count}),
        role_counts: Map.put(state.role_counts, {:spawn, parent_role}, count + 1)
    }
  end

  defp spawn_role(_, state), do: state

  defp existing_identities(state, side) do
    state =
      Enum.reduce(side.run.fixture || %{}, state, fn {name, id}, s ->
        %{s | roles: Map.put(s.roles, id, {:fixture, name})}
      end)

    generated =
      MapSet.new(Enum.flat_map(state.origins, fn {_, %{value: value}} -> identities(value) end))

    state =
      Enum.reduce(state.events, state, fn e, acc ->
        Enum.reduce(identities(e.event), acc, &existing_identity(&1, &2, generated, side))
      end)

    state
  end

  defp existing_identity(id, state, generated, side) do
    cond do
      Map.has_key?(state.roles, id) -> state
      MapSet.member?(generated, id) -> state
      is_pid(id) or is_port(id) -> elem(role(id, state), 1)
      historical_reference?(id, side) -> elem(role(id, state), 1)
      true -> state
    end
  end

  defp historical_reference?(ref, side) do
    Enum.any?(side.historical.connections, fn {table, c} ->
      ref == table or ref in identities(c.protocol) or ref in identities(c.lock)
    end)
  end

  defp identities(term) when is_pid(term) or is_reference(term) or is_port(term), do: [term]
  defp identities(term) when is_map(term), do: term |> Map.to_list() |> identities()
  defp identities([head | tail]), do: identities(head) ++ identities(tail)
  defp identities(term) when is_tuple(term), do: term |> Tuple.to_list() |> identities()
  defp identities(_), do: []

  defp role(identity, state) do
    case Map.fetch(state.roles, identity) do
      {:ok, role} ->
        {role, state}

      :error ->
        registered = if is_pid(identity), do: Process.info(identity, :registered_name)

        kind =
          cond do
            is_port(identity) -> :port
            is_reference(identity) -> :historical_ref
            true -> :preexisting
          end

        n = Map.get(state.role_counts, kind, 0)

        role =
          case registered do
            {:registered_name, name} when is_atom(name) -> {:registered, name}
            _ -> {kind, n}
          end

        {role,
         %{
           state
           | roles: Map.put(state.roles, identity, role),
             role_counts: Map.put(state.role_counts, kind, n + 1)
         }}
    end
  end

  def pair(run, twin, permitted) do
    initial = %{
      forward: %{},
      reverse: %{},
      uuid_forward: %{},
      uuid_reverse: %{},
      clocks: %{},
      errors: []
    }

    initial = Enum.reduce(run.roles, initial, &pair_role(&1, &2, twin.roles))

    initial =
      Enum.reduce(Registry.rename(), initial, fn {a, b}, acc -> bind(acc, a, b, :resource) end)

    initial =
      Enum.reduce(run.relations, initial, &pair_relation(&1, &2, twin.relations))

    initial =
      Enum.reduce(run.query_cache.rows, initial, fn
        {key, status, _select, {id, query}}, acc when status in [:cache, :cached] ->
          twin_key = rename_term(key)

          case Enum.find(twin.query_cache.rows, &(elem(&1, 0) === twin_key)) do
            {_, ^status, _, {twin_id, twin_query}} ->
              acc = bind(acc, id, twin_id, {:query_cache, key})

              bind_query_reference(acc, query, twin_query, key)

            _ ->
              acc
          end

        _, acc ->
          acc
      end)

    initial = pair_sources(run.origins, twin.origins, initial, permitted, :o1)
    pair_sources(run.reads, twin.reads, initial, permitted, :o3)
  end

  defp pair_role({id, role}, state, roles) do
    case Enum.find(roles, fn {_id, other_role} -> other_role == role end) do
      {other, ^role} -> bind(state, id, other, {:role, role})
      nil -> state
    end
  end

  defp pair_relation({id, name}, state, relations) do
    case Enum.find(relations, fn {_other, other_name} -> other_name == name end) do
      {other, ^name} -> bind(state, id, other, {:table_oid, name})
      nil -> error(state, {:table_oid, :missing, name})
    end
  end

  defp bind_query_reference(state, %Postgrex.Query{} = a, %Postgrex.Query{} = b, key),
    do: bind(state, a.ref, b.ref, {:query_cache_reference, key})

  defp bind_query_reference(state, _a, _b, _key), do: state

  def permitted_sources(indexed, other_claimed) do
    owned = HostCall.indexes(indexed.events)

    Enum.reduce(indexed.events, other_claimed, fn e, allowed ->
      if elem(e.event, 1) == :return_from and
           (MapSet.member?(owned, e.index) or delivery_source?(e)),
         do: MapSet.put(allowed, e.index),
         else: allowed
    end)
  end

  defp delivery_source?(%{mfa: {:erlang, :make_ref, 0}, stack: stack}),
    do: {AshOnetime.Delivery, :put_cell, 1} in stack

  defp delivery_source?(%{mfa: {:crypto, :strong_rand_bytes, 1}, stack: stack}),
    do:
      Enum.any?(
        stack,
        &(&1 in [{AshOnetime.Delivery, :armed_call, 4}, {AshOnetime.Delivery, :claim_entry, 6}])
      )

  defp delivery_source?(%{mfa: {:crypto, :generate_key, arity}, stack: stack})
       when arity in [2, 3],
       do:
         Enum.any?(
           stack,
           &(&1 in [
               {AshOnetime.Delivery, :armed_call, 4},
               {AshOnetime.Delivery.Envelope, :encrypt, 3}
             ])
         )

  defp delivery_source?(_), do: false

  defp pair_sources(left, right, state, permitted, rule) do
    allowed =
      if is_map(permitted) and not is_struct(permitted, MapSet),
        do: permitted[rule],
        else: permitted

    Enum.reduce(
      MapSet.union(MapSet.new(Map.keys(left)), MapSet.new(Map.keys(right))),
      state,
      fn key, acc ->
        pair_source({Map.get(left, key), Map.get(right, key)}, acc, key, rule, allowed, permitted)
      end
    )
  end

  defp pair_source({%{value: a}, %{value: b}}, state, key, :o1, _allowed, _permitted),
    do: bind_generated(state, a, b, key)

  defp pair_source({%{value: a}, %{value: b}}, state, key, _rule, _allowed, _permitted),
    do: %{state | clocks: Map.put(state.clocks, key, {a, b})}

  defp pair_source({%{index: n}, nil}, state, key, rule, allowed, _permitted),
    do: if(MapSet.member?(allowed, n), do: state, else: error(state, {rule, :unpaired_run, key}))

  defp pair_source({nil, %{index: n}}, state, key, rule, _allowed, permitted) do
    allowed =
      if is_map(permitted) and not is_struct(permitted, MapSet),
        do: Map.get(permitted, {:twin, rule}, MapSet.new()),
        else: MapSet.new()

    if MapSet.member?(allowed, n),
      do: state,
      else: error(state, {rule, :unpaired_twin, key, n})
  end

  # Pairing happens before event comparison, but an origin failure still belongs
  # to its captured return. Preserve that location and the native values instead
  # of reporting a registry key at an unrelated comparison cursor.
  def difference({rule, :unpaired_run, key}, run, twin) do
    origin_difference(rule, key, run, twin, :unpaired_run)
  end

  def difference({rule, :unpaired_twin, key, _index}, run, twin) do
    origin_difference(rule, key, run, twin, :unpaired_twin)
  end

  def difference({rule, :not_bijective, key}, run, twin)
      when is_tuple(key) and tuple_size(key) == 5 do
    origin_difference(rule, key, run, twin, :not_bijective)
  end

  def difference({:invalid_generated_uuid, key}, run, twin) do
    origin_difference(:o2_uuid, key, run, twin, :invalid_generated_uuid)
  end

  def difference({:o2, :not_bijective, {:allocation, role, ordinal, field, a, b}}, run, twin) do
    source = Enum.find(run.events, &(&1.index == a))
    other = Enum.find(twin.events, &(&1.index == b))

    %{
      at:
        Map.take(source, [:role, :mfa, :stack])
        |> Map.put(:run_index, a)
        |> Map.put(:twin_index, b),
      path: [:allocation, role, ordinal, field],
      run: source.event,
      twin: other.event
    }
  end

  def difference(reason, _run, _twin),
    do: %{at: nil, path: [], run: reason, twin: :paired_origins}

  defp origin_difference(rule, key, run, twin, reason) do
    field = if rule == :o3, do: :reads, else: :origins
    a = Map.get(Map.fetch!(run, field), key)
    b = Map.get(Map.fetch!(twin, field), key)

    {side, source, index_key} =
      if a,
        do: {run, a, :run_index},
        else: {twin, b, :twin_index}

    event = Enum.find(side.events, &(&1.index == source.index))
    at = event |> Map.take([:role, :phase, :mfa, :stack]) |> Map.put(index_key, source.index)

    %{
      at: at,
      path: [rule, reason, key],
      run: if(a, do: a.value, else: :missing_origin),
      twin: if(b, do: b.value, else: :missing_origin)
    }
  end

  defp rename_term(value) when is_atom(value), do: Map.get(Registry.rename(), value, value)

  defp rename_term(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&rename_term/1) |> List.to_tuple()

  defp rename_term(value) when is_list(value), do: Enum.map(value, &rename_term/1)
  defp rename_term(value), do: value

  defp bind_generated(state, {a, ar}, {b, br}, key),
    do: state |> bind(a, b, key) |> bind(ar, br, key)

  defp bind_generated(state, a, b, key) do
    state = bind(state, a, b, key)

    case key do
      {_, _, _, {module, function, 0}, _}
      when module in [Ecto.UUID, Ash.UUID] and function in [:generate, :bingenerate] ->
        bind_generated_uuid(state, a, b, key, function)

      _ ->
        state
    end
  end

  defp bind_generated_uuid(state, a, b, key, function) do
    case {Ecto.UUID.dump(a), Ecto.UUID.dump(b)} do
      {{:ok, _}, {:ok, _}} -> bind_uuid(state, a, b, key)
      _ when function == :bingenerate -> bind_binary_uuid(state, a, b, key)
      _ -> error(state, {:invalid_generated_uuid, key})
    end
  end

  defp bind_binary_uuid(state, a, b, key) do
    case {Ecto.UUID.load(a), Ecto.UUID.load(b)} do
      {{:ok, av}, {:ok, bv}} -> bind_uuid(state, av, bv, key)
      _ -> error(state, {:invalid_generated_uuid, key})
    end
  end

  defp bind_uuid(state, a, b, key) do
    case {Map.fetch(state.uuid_forward, a), Map.fetch(state.uuid_reverse, b)} do
      {:error, :error} ->
        %{
          state
          | uuid_forward: Map.put(state.uuid_forward, a, b),
            uuid_reverse: Map.put(state.uuid_reverse, b, a)
        }

      {{:ok, ^b}, {:ok, ^a}} ->
        state

      _ ->
        error(state, {:o2_uuid, :not_bijective, key})
    end
  end

  def bind(state, a, b, key) do
    case {Map.fetch(state.forward, a), Map.fetch(state.reverse, b)} do
      {:error, :error} ->
        %{state | forward: Map.put(state.forward, a, b), reverse: Map.put(state.reverse, b, a)}

      {{:ok, ^b}, {:ok, ^a}} ->
        state

      _ ->
        error(state, {:o2, :not_bijective, key})
    end
  end

  defp error(state, error), do: %{state | errors: [error | state.errors]}
end
