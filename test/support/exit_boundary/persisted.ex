defmodule AshOnetime.Test.ExitBoundary.Persisted do
  @moduledoc false

  # The complete authoritative store snapshot. Values remain as decoded PostgreSQL
  # terms; Comparator checks origins and every later copy against the captured wire.

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @doc "Every row of every table in `prefix`, as `%{table => [row]}`."
  def snapshot(prefix, repo \\ Repo) do
    %{rows: tables} =
      SQL.query!(
        repo,
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
        [prefix]
      )

    for [table] <- tables, into: %{} do
      relation = quote_identifier(prefix) <> "." <> quote_identifier(table)

      %{rows: fields} =
        SQL.query!(
          repo,
          "SELECT attname, atttypid = 'pg_catalog.aclitem'::regtype, atttypid = 'pg_catalog.aclitem[]'::regtype FROM pg_catalog.pg_attribute WHERE attrelid = pg_catalog.to_regclass($1) AND attnum > 0 AND NOT attisdropped ORDER BY attnum",
          [relation]
        )

      # Postgrex has no aclitem decoder. PostgreSQL's own text output preserves
      # every ACL element, array position and NULL; comparison stays exact.
      projection = Enum.map_join(fields, ", ", &project_column/1)

      %{columns: columns, rows: rows} =
        SQL.query!(repo, "SELECT " <> projection <> " FROM " <> relation, [])

      {table, Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))}
    end
  end

  defp project_column([name, true, _]),
    do: quote_identifier(name) <> "::text AS " <> quote_identifier(name)

  defp project_column([name, false, true]),
    do: quote_identifier(name) <> "::text[] AS " <> quote_identifier(name)

  defp project_column([name, false, false]), do: quote_identifier(name)

  defp quote_identifier(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""

  @doc "Rows added and removed between two snapshots, per table, only tables that changed."
  def delta(before, after_run) do
    tables = MapSet.union(MapSet.new(Map.keys(before)), MapSet.new(Map.keys(after_run)))

    for table <- tables,
        old = Map.get(before, table, []),
        new = Map.get(after_run, table, []),
        added = new -- old,
        removed = old -- new,
        added != [] or removed != [],
        into: %{} do
      {table, %{added: added, removed: removed}}
    end
  end
end
