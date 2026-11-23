defmodule AshOnetime.Test.ExitBoundary.Historical do
  alias AshOnetime.Test.ExitBoundary.ConnectionHistory
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
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
