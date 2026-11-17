defmodule AshOnetime.Test.ExitBoundary.Persisted do
  @moduledoc false

  # X1 reads every table in the real installation. Normalization receives the
  # fixture's exact identity substitutions from Normalization; all semantic bytes,
  # numbers and multiplicities remain. Normalization identifies the authoritative
  # database-clock columns; timestamps elsewhere remain exact semantic values.
  # Failures report table/column names and counts, never values.

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @doc "Every row of every table in `prefix`, as `%{table => [row]}`."
  def snapshot(prefix) do
    %{rows: tables} =
      SQL.query!(
        Repo,
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
        [prefix]
      )

    for [table] <- tables, into: %{} do
      %{columns: columns, rows: rows} =
        SQL.query!(Repo, ~s[SELECT * FROM "#{prefix}"."#{table}"], [])

      {table, Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))}
    end
  end

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

  @doc "The delta in the twin's terms; see the module comment."
  def normalize(delta, prefix, renames) do
    Map.new(delta, fn {table, %{added: added, removed: removed}} ->
      {rename(table, prefix, renames),
       %{added: rows(added, prefix, renames), removed: rows(removed, prefix, renames)}}
    end)
  end

  defp rows(rows, prefix, renames) do
    rows
    |> Enum.map(fn row -> Map.new(row, fn {k, v} -> {k, value(v, prefix, renames)} end) end)
    |> Enum.sort_by(&:erlang.term_to_binary/1)
  end

  defp value(binary, prefix, renames) when is_binary(binary) do
    if String.valid?(binary) and String.printable?(binary),
      do: {:text, rename(binary, prefix, renames)},
      else: {:bytes, binary}
  end

  defp value(list, prefix, renames) when is_list(list),
    do: Enum.map(list, &value(&1, prefix, renames))

  defp value(%{__struct__: _} = struct, _prefix, _renames), do: struct

  defp value(%{} = map, prefix, renames),
    do: Map.new(map, fn {k, v} -> {value(k, prefix, renames), value(v, prefix, renames)} end)

  defp value(other, _prefix, _renames), do: other

  defp rename(text, prefix, renames) do
    Enum.reduce(renames, String.replace(text, prefix, "<prefix>"), fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  @doc """
  The tables whose normalized deltas differ, with their added and removed counts and the
  names of the columns whose values differ row for row. Never a value.
  """
  def difference(run, twin) do
    tables = MapSet.union(MapSet.new(Map.keys(run)), MapSet.new(Map.keys(twin)))
    empty = %{added: [], removed: []}

    for table <- Enum.sort(tables),
        run_rows = Map.get(run, table, empty),
        twin_rows = Map.get(twin, table, empty),
        not equivalent?(run_rows, twin_rows) do
      {table,
       run: counts(run_rows), twin: counts(twin_rows), columns: columns(run_rows, twin_rows)}
    end
  end

  defp counts(%{added: added, removed: removed}), do: {length(added), length(removed)}

  defp equivalent?(%{__struct__: _} = a, b), do: a == b

  defp equivalent?(%{} = a, %{} = b),
    do: map_size(a) == map_size(b) and Enum.all?(a, &equivalent_entry?(&1, b))

  defp equivalent?([a | as], [b | bs]), do: equivalent?(a, b) and equivalent?(as, bs)
  defp equivalent?(a, b), do: a == b

  defp equivalent_entry?({k, v}, map), do: Map.has_key?(map, k) and equivalent?(v, map[k])

  defp columns(run_rows, twin_rows) do
    for side <- [:added, :removed],
        {run_row, twin_row} <- Enum.zip(run_rows[side], twin_rows[side]),
        column <- Enum.uniq(Map.keys(run_row) ++ Map.keys(twin_row)),
        not equivalent?(Map.get(run_row, column), Map.get(twin_row, column)),
        uniq: true,
        do: column
  end
end
