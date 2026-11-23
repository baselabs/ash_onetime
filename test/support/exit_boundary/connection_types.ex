defmodule AshOnetime.Test.ExitBoundary.ConnectionTypes do
  @moduledoc false

  # Shared type owners exist outside an invocation's descendants. Bind every
  # existing table to its actual owner before root release; the collector keeps
  # that owner's independent pre-observation state and every later dispatch.
  def services do
    for table <- :ets.all(),
        :ets.info(table, :name) == Postgrex.Types,
        owner = :ets.info(table, :owner),
        is_pid(owner),
        key <- Registry.keys(Postgrex.TypeManager, owner),
        into: %{},
        do:
          {{:native_type_owner, key},
           %{pid: owner, table: table, callback: {Postgrex.TypeServer, :handle_call, 3}}}
  end

  # Existing owners have independent pre-arm roots. A new owner instead needs
  # the complete native factory chain, from the locating caller through the
  # shared supervisor, registration and the owning ETS creation. The Types.new
  # return is retained only after its primitive origin has been checked.
  def history(indexed, pairs, services) do
    roots =
      for {owner, %{table: table, initial_state: %Postgrex.TypeServer{types: types} = root}} <-
            services,
          into: %{},
          do: {owner, %{table: table, types: types, state: root, index: -1}}

    pairs
    |> Map.values()
    |> Enum.filter(&(&1.source.mfa == {Postgrex.TypeServer, :init, 1}))
    |> Enum.sort_by(& &1.source.index)
    |> Enum.reduce(%{roots: roots, births: [], errors: []}, fn pair, history ->
      case birth(indexed.events, pairs, services, pair) do
        {:ok, owner, root} ->
          %{history | roots: Map.put(history.roots, owner, root), births: history.births ++ [root]}

        :error ->
          error = %{
            index: pair.source.index,
            at: Map.take(pair.source, [:mfa, :role, :stack]),
            rule: :type_service_birth
          }

          %{history | errors: history.errors ++ [error]}
      end
    end)
  end

  defp birth(events, pairs, services, init) do
    owner = init.source.pid

    with {^owner, :call, {_, _, [{module, starter}]}} <- init.source.event,
         [types_new] <- children(pairs, init, {Postgrex.Types, :new, 1}),
         {^owner, :call, {_, _, [^module]}} <- types_new.source.event,
         [table_new] <- children(pairs, types_new, {:ets, :new, 2}),
         {^owner, :call, {:ets, :new, [Postgrex.Types, options]}} <- table_new.source.event,
         true <- options === [:protected, {:read_concurrency, true}],
         {^owner, :return_from, _, table} <- table_new.returned.event,
         {^owner, :return_from, _, {^module, ^table} = types} <- types_new.returned.event,
         root <- %Postgrex.TypeServer{
           types: types,
           connections: MapSet.new([starter]),
           waiting: :queue.new()
         },
         {^owner, :return_from, _, {:ok, ^root}} <- init.returned.event,
         {:ok, key, registration} <- registration(pairs, owner, module, init.source.index),
         {:ok, supervisor, factory} <- factory(pairs, services, owner, starter, key, init),
         true <- spawned?(events, supervisor, owner, factory, init) do
      retirement = Enum.find(events, &match?(%{event: {^owner, :exit, _}}, &1))

      {:ok, owner,
       %{
         owner: owner,
         table: table,
         types: types,
         state: root,
         key: key,
         index: types_new.returned.index,
         registration: registration,
         factory: factory.source.index,
         initialized: init.returned.index,
         retired: if(retirement, do: retirement.index)
       }}
    else
      _ -> :error
    end
  end

  defp children(pairs, parent, mfa) do
    pairs
    |> Map.values()
    |> Enum.filter(fn pair ->
      pair.source.pid == parent.source.pid and pair.source.mfa == mfa and
        pair.source.index > parent.source.index and pair.returned.index < parent.returned.index
    end)
  end

  defp registration(pairs, owner, module, before) do
    registrations =
      for {_index, pair} <- pairs,
          pair.returned.index < before,
          {^owner, :call, {Registry, :register, [Postgrex.TypeManager, {^module, _} = key, nil]}} <-
            [pair.source.event],
          {^owner, :return_from, _, {:ok, _}} <- [pair.returned.event],
          do: {key, pair.returned.index}

    case registrations do
      [{key, index}] -> {:ok, key, index}
      _ -> :error
    end
  end

  defp factory(pairs, services, owner, starter, {module, _endpoint} = key, init) do
    options = [name: {:via, Registry, {Postgrex.TypeManager, key}}]
    arguments = {module, starter, options}

    factories =
      for {_index, pair} <- pairs,
          pair.source.index < init.source.index and pair.returned.index > init.returned.index,
          {supervisor, :call, {Postgrex.TypeServer, :start_link, [^arguments]}} <-
            [pair.source.event],
          %{name: Postgrex.TypeSupervisor} <- [services[supervisor]],
          {^supervisor, :return_from, _, {:ok, ^owner}} <- [pair.returned.event],
          do: {supervisor, pair}

    case factories do
      [{supervisor, pair}] ->
        if supervisor_request?(pairs, supervisor, starter, arguments, owner, pair),
          do: {:ok, supervisor, pair},
          else: :error

      _ ->
        :error
    end
  end

  defp supervisor_request?(pairs, supervisor, starter, arguments, owner, factory) do
    request =
      {:start_child,
       {{Postgrex.TypeServer, :start_link, [arguments]}, :temporary, 5000, :worker,
        [Postgrex.TypeServer]}}

    Enum.any?(pairs, fn {_index, pair} ->
      pair.source.pid == starter and pair.source.index < factory.source.index and
        pair.returned.index > factory.returned.index and
        pair.source.event ===
          {starter, :call,
           {DynamicSupervisor, :start_child,
            [Postgrex.TypeSupervisor, {Postgrex.TypeServer, arguments}]}} and
        pair.returned.event ===
          {starter, :return_from, {DynamicSupervisor, :start_child, 2}, {:ok, owner}} and
        Enum.any?(pairs, fn {_index, callback} ->
          callback.source.pid == supervisor and
            callback.source.index < factory.source.index and
            callback.returned.index > factory.returned.index and
            match?(
              {^supervisor, :call,
               {DynamicSupervisor, :handle_call, [^request, {^starter, _tag}, _state]}},
              callback.source.event
            )
        end)
    end)
  end

  defp spawned?(events, supervisor, owner, factory, init) do
    Enum.any?(events, fn source ->
      source.index > factory.source.index and source.index < init.source.index and
        match?({^supervisor, :spawn, ^owner, _}, source.event)
    end)
  end

  # Expectations cross the native boundary at the owning ETS operation, never
  # at the helper return under examination. Its caller supplies module and OID
  # from the independently decoded description or catalog dependency.
  def fetch(pairs, pair, oid, {module, table}) do
    lookups =
      pairs
      |> Map.values()
      |> Enum.filter(fn lookup ->
        lookup.source.pid == pair.source.pid and lookup.source.index > pair.source.index and
          lookup.returned.index < pair.returned.index and
          lookup.source.mfa == {:ets, :lookup_element, 3}
      end)
      |> Enum.sort_by(& &1.source.index)

    fetch_result(lookups, module, table, oid)
  end

  defp fetch_result([lookup], module, table, oid) do
    case native_lookup(lookup, table, oid, 3) do
      {:ok, {_, _} = info} -> {:ok, {:ok, info}, [lookup.source.index]}
      {:ok, :associating} -> {:ok, {:error, nil, module}, [lookup.source.index]}
      :missing -> {:ok, {:error, nil, module}, [lookup.source.index]}
      _ -> :error
    end
  end

  defp fetch_result([first, second], module, table, oid) do
    with {:ok, nil} <- native_lookup(first, table, oid, 3),
         result when result != :error <- native_lookup(second, table, oid, 2) do
      info = if result == :missing, do: nil, else: elem(result, 1)
      {:ok, {:error, info, module}, [first.source.index, second.source.index]}
    else
      _ -> :error
    end
  end

  defp fetch_result(_lookups, _module, _table, _oid), do: :error

  defp native_lookup(%{source: source, returned: returned}, table, oid, field) do
    case {source.event, returned.event} do
      {{_, :call, {:ets, :lookup_element, [^table, ^oid, ^field]}},
       {_, :return_from, {:ets, :lookup_element, 3}, value}} ->
        {:ok, value}

      {{_, :call, {:ets, :lookup_element, [^table, ^oid, ^field]}},
       {_, :exception_from, {:ets, :lookup_element, 3}, {:error, :badarg}}} ->
        :missing

      _ ->
        :error
    end
  end

  # The catalog uses text DataRow columns. These are the source-version schemas,
  # including the category added in 0.23 and only send's pg_catalog qualification.
  def catalog(bytes) do
    case columns(bytes) do
      [oid, type, category, send, receive, output, input, array, base, composite] ->
        fields = fields([oid, type, send, receive, output, input, array, base, composite])

        category =
          Map.get(
            %{
              "b" => :base,
              "c" => :composite,
              "d" => :domain,
              "e" => :enum,
              "p" => :pseudo,
              "r" => :range,
              "m" => :multirange
            },
            category,
            :unknown
          )

        struct!(Postgrex.TypeInfo, Map.put(fields, :category, category))

      [oid, type, send, receive, output, input, array, base, composite] ->
        fields = fields([oid, type, send, receive, output, input, array, base, composite])
        struct!(Postgrex.TypeInfo, %{fields | send: send})
    end
  end

  defp fields([oid, type, send, receive, output, input, array, base, composite]) do
    %{
      oid: String.to_integer(oid),
      type: type,
      send: unqualify(send),
      receive: receive,
      output: output,
      input: input,
      array_elem: String.to_integer(array),
      base_type: String.to_integer(base),
      comp_elems: oids(composite)
    }
  end

  defp unqualify("pg_catalog." <> name), do: name
  defp unqualify(name), do: name
  defp columns(<<>>), do: []
  defp columns(<<-1::signed-32, rest::binary>>), do: [nil | columns(rest)]

  defp columns(<<size::32, value::binary-size(size), rest::binary>>),
    do: [value | columns(rest)]

  defp oids(nil), do: []
  defp oids("{}"), do: []

  defp oids("{" <> rest) do
    rest |> String.trim_trailing("}") |> String.split(",") |> Enum.map(&String.to_integer/1)
  end
end
