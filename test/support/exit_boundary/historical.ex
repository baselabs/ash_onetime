defmodule AshOnetime.Test.ExitBoundary.Historical do
  @moduledoc false
  alias AshOnetime.Test.Repo

  def capture(prefix) do
    %{rows: relations} =
      Ecto.Adapters.SQL.query!(
        Repo.get_dynamic_repo(),
        "SELECT c.oid::bigint, c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1",
        [prefix]
      )

    %{rows: payload_children} =
      Ecto.Adapters.SQL.query!(
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

    %{
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

  defp readable(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end
end
