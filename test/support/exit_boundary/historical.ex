defmodule AshOnetime.Test.ExitBoundary.Historical do
  alias AshOnetime.Test.ExitBoundary.ConnectionHistory
  alias AshOnetime.Test.ExitBoundary.ConnectionProtocol
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  import Postgrex.Messages, only: [row_field: 1]
  @moduledoc false

  def capture(prefix) do
    %{rows: relations} =
      SQL.query!(
        Repo.get_dynamic_repo(),
        "SELECT c.oid::bigint, c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1",
        [prefix]
      )

    %{rows: payload_children} =
      SQL.query!(
        Repo.get_dynamic_repo(),
        "SELECT child.relname FROM pg_catalog.pg_inherits i JOIN pg_catalog.pg_class child ON child.oid = i.inhrelid JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent JOIN pg_catalog.pg_namespace n ON n.oid = parent.relnamespace WHERE n.nspname = $1 AND parent.relname = $2",
        [prefix, AshOnetime.Test.ExitBoundary.Registry.database_statements().payload.table]
      )

    %{pid: pool} = Ecto.Repo.Registry.lookup(Repo.get_dynamic_repo())
    DBConnection.get_connection_metrics(pool)

    tables =
      for table <- :ets.all(),
          :ets.info(table, :name) in [DBConnection.Holder, DBConnection.ConnectionPool.Queue],
          do: {table, readable(table)}

    connections =
      for {table, rows} <- tables,
          {:conn, owner, Postgrex.Protocol, %Postgrex.Protocol{} = protocol, lock, clock,
           deadline, status} <- rows,
          into: %{},
          do:
            {table,
             %{
               owner: owner,
               port_owner: port_owner(protocol),
               protocol: protocol,
               lock: lock,
               clock: clock,
               deadline: deadline,
               status: status
             }}

    cache_expiries =
      if :ets.whereis(AshOnetime.Cache.Ets) == :undefined,
        do: %{},
        else:
          Map.new(
            for {key, %AshOnetime.Cache.Entry{}, expiry} <- :ets.tab2list(AshOnetime.Cache.Ets),
                do: {key, expiry}
          )

    metadata = Ecto.Repo.Registry.lookup(Repo.get_dynamic_repo())
    query_cache = %{table: metadata.cache, rows: readable(metadata.cache)}
    origins = ConnectionHistory.snapshot()
    connections = Map.new(connections, fn {holder, c} -> {holder, descriptors(c, origins)} end)

    catalogs =
      for {_, %{protocol: %{sock: {:gen_tcp, port}}, descriptors: descriptors}} <- connections,
          into: %{} do
        statements =
          Map.new(descriptors, fn origin ->
            {origin.query.name,
             %{
               sql: IO.iodata_to_binary(origin.query.statement),
               statement: {:historical_statement, origin.query.name},
               parameter_types: origin.parameters,
               columns: origin.columns || [],
               description: if(is_nil(origin.columns), do: :none, else: :rows),
               binds: []
             }}
          end)

        {port, statements}
      end

    %{
      prepared_catalogs: catalogs,
      query_origins: origins,
      query_cache: query_cache,
      payload_children: Enum.map(payload_children, &hd/1),
      cache_expiries: cache_expiries,
      repo: Repo.get_dynamic_repo(),
      repo_metadata: Ecto.Repo.Registry.lookup(Repo.get_dynamic_repo()),
      connections: connections,
      relations: Map.new(relations, fn [oid, name] -> {oid, name} end),
      pool_clocks:
        for(
          {_table, rows} <- tables,
          {{at, holder}} <- rows,
          Map.has_key?(connections, holder),
          do: {holder, at}
        )
        |> Map.new()
    }
  end

  # A cut is the state strictly before its captured event. Native writes may
  # linearize anywhere between call and return, so a crossing write refuses the
  # cut instead of borrowing either its earlier row or its eventual result.
  def cut(historical, proof, before) when is_integer(before) do
    tables = MapSet.new(proof.states.table_commits, & &1.table)
    holders = MapSet.new(proof.states.commits, & &1.holder)

    crossing =
      proof.native.pairs
      |> Map.values()
      |> Enum.filter(fn pair ->
        pair.source.index < before and before <= pair.returned.index and
          cut_write?(pair.source.event, tables, holders)
      end)
      |> Enum.min_by(& &1.source.index, fn -> nil end)

    errors =
      proof.native.errors ++ proof.reads.errors ++ proof.decoders.errors ++ proof.states.errors

    cond do
      errors != [] ->
        {:error, %{rule: :cut_unvalidated_connection, index: before}}

      crossing ->
        {:error, %{rule: :cut_inflight_native_write, index: crossing.source.index}}

      true ->
        committed_cut(historical, proof, before)
    end
  end

  defp cut_write?({_, :call, {:ets, function, [table | _]}}, tables, holders)
       when function in [
              :insert,
              :insert_new,
              :update_element,
              :delete,
              :delete_object,
              :delete_all_objects,
              :give_away
            ],
       do: MapSet.member?(tables, table) or MapSet.member?(holders, table)

  defp cut_write?(_event, _tables, _holders), do: false

  defp committed_cut(historical, proof, before) do
    rows = committed_before(proof.states.commits, :holder, before)
    tables = committed_before(proof.states.table_commits, :table, before)
    catalogs = catalog_cut(historical.prepared_catalogs, proof.reads.connections, before)
    origins = descriptor_cut(historical.query_origins, proof, before)

    connections =
      for {holder, commit} <- rows,
          {:conn, owner, Postgrex.Protocol, protocol, lock, clock, deadline, status} <- [
            commit.row
          ],
          into: %{} do
        previous = Map.fetch!(historical.connections, holder)
        cache = cache_cut(protocol.queries, tables)

        descriptors =
          for origin <- origins,
              origin.sock === protocol.sock and origin.query.types === protocol.types,
              Enum.any?(cache.rows, fn row ->
                elem(row, 0) === origin.query.name and elem(row, 1) === origin.query.ref
              end),
              do: origin

        connection =
          Map.merge(previous, %{
            owner: owner,
            protocol: protocol,
            lock: lock,
            clock: clock,
            deadline: deadline,
            status: status,
            query_cache: cache,
            descriptors: descriptors
          })

        {holder, connection}
      end

    {:ok,
     %{
       historical
       | connections: connections,
         query_cache: cache_cut(historical.query_cache.table, tables),
         prepared_catalogs: catalogs,
         query_origins: origins,
         pool_clocks: pool_clock_cut(historical, proof.native.pairs, before)
     }}
  end

  defp committed_before(commits, key, before) do
    commits
    |> Enum.filter(&(&1.index < before))
    |> Enum.sort_by(& &1.index)
    |> Map.new(&{Map.fetch!(&1, key), &1})
  end

  defp cache_cut(nil, _tables), do: %{table: nil, rows: [], present?: false}

  defp cache_cut(table, tables) do
    commit = Map.fetch!(tables, table)
    %{table: table, rows: commit.rows, present?: commit.present?}
  end

  # Replay the already-validated messages at their actual native boundaries.
  # Catalog changes belong to successful server replies, never to Parse/Close
  # call arguments or a later driver's prepared-query return.
  defp catalog_cut(initial, connections, before) do
    Enum.reduce(connections, initial, fn {port, connection}, catalogs ->
      protocol =
        connection.protocol.messages
        |> Enum.filter(fn frame -> Enum.all?(frame.provenance, &(&1.index < before)) end)
        |> Enum.reduce(ConnectionProtocol.new(Map.get(initial, port, %{})), fn frame, state ->
          ConnectionProtocol.push(state, frame)
        end)

      Map.put(catalogs, port, protocol.statements)
    end)
  end

  # Decoder factories are native description facts. Keep all completed origins,
  # including queries later evicted from a cache; active descriptors are selected
  # separately by the cut's committed native table rows.
  defp descriptor_cut(initial, proof, before) do
    additions =
      for {index, %{query: %Postgrex.Query{ref: ref} = query, origin: {factory, _}}} <-
            proof.decoders.query_outputs,
          index < before and not is_nil(ref),
          {:ok, input} <- [Map.fetch(proof.decoders.query_inputs, factory)],
          root = Map.fetch!(proof.native.pairs, input.root).source,
          {_, :call, {_, _, arguments}} = root.event,
          %{sock: {:gen_tcp, port} = sock} <- [List.last(arguments)],
          source = Map.fetch!(proof.native.pairs, factory).returned,
          do: %{
            index: index,
            mfa: source.mfa,
            path: [3, 1],
            sock: sock,
            port: port,
            query: query,
            parameters: input.param_oids,
            columns: descriptor_columns(input.fields)
          }

    (initial ++ Enum.sort_by(additions, & &1.index))
    |> Map.new(&{{&1.sock, &1.query.ref}, &1})
    |> Map.values()
  end

  defp descriptor_columns(nil), do: nil

  defp descriptor_columns(fields) do
    for row_field(
          name: name,
          table_oid: table,
          column: number,
          type_oid: oid,
          type_size: width,
          type_mod: modifier,
          format: format
        ) <- fields,
        do: {name, {:table_oid, table}, number, oid, width, modifier, format}
  end

  defp pool_clock_cut(historical, pairs, before) do
    pool = historical.repo_metadata.pid

    pairs
    |> Map.values()
    |> Enum.filter(&(&1.returned.index < before))
    |> Enum.sort_by(& &1.returned.index)
    |> Enum.reduce(historical.pool_clocks, fn pair, clocks ->
      case {pair.source.event, pair.returned.event} do
        {{_, :call, {:ets, :give_away, [holder, ^pool, {:checkin, _queue, clock}]}},
         {_, :return_from, _, true}} ->
          Map.put(clocks, holder, clock)

        _ ->
          clocks
      end
    end)
  end

  defp port_owner(%{sock: {:gen_tcp, port}}) do
    case Port.info(port, :connected) do
      {:connected, owner} -> owner
      nil -> :closed
    end
  end

  defp port_owner(_protocol), do: :not_tcp

  defp descriptors(%{protocol: protocol} = connection, origins) do
    queries = if protocol.queries, do: readable(protocol.queries), else: []

    descriptors =
      for origin <- origins,
          origin.sock === protocol.sock and origin.query.types === protocol.types,
          origin.parameters === origin.query.param_oids,
          Enum.any?(queries, fn row ->
            elem(row, 0) === origin.query.name and elem(row, 1) === origin.query.ref
          end),
          {:gen_tcp, port} <- [origin.sock],
          do: Map.put(origin, :port, port)

    connection
    |> Map.put(:descriptors, descriptors)
    |> Map.put(:query_cache, %{table: protocol.queries, rows: queries})
  end

  defp readable(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end
end
