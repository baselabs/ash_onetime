defmodule AshOnetime.Test.ExitBoundary.Persisted do
  @moduledoc false

  # §2.7.8 rule 4, X1: the exact persisted projection. `snapshot/1` reads every row of
  # every table in an installation's schema, as the test's sandboxed connection sees it;
  # `delta/2` is what a run added and removed, table by table; `normalize/3` makes the
  # run's delta comparable with its twin's (each in its own installation):
  #
  # - the schema name becomes `:prefix`, and the withheld resource's names the twin's;
  # - UUIDs become their position in the delta (equal UUIDs stay equal), binaries and
  #   byte strings their size, so a digest or an encrypted payload compares by width; the
  #   response codec binding (`ao:<tag>:<contract digest>`) keeps its tag and compares its
  #   digest by width too, since each resource's contract digests its own name;
  # - timestamps, which the database clock stamps, become their offset in microseconds
  #   from the delta's earliest timestamp, and two offsets are equal within
  #   `@clock_tolerance`: the trace slows a run by an amount the run does not control, so
  #   an offset rounded to whole seconds could fall either side of a boundary, while a
  #   retention or an expiry (minutes to days) still compares exactly.
  #
  # Failures name tables and counts only.

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @clock_tolerance 5_000_000

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
    tokens =
      delta
      |> Map.new(fn {table, %{added: added, removed: removed}} ->
        {rename(table, prefix, renames),
         %{added: rows(added, prefix, renames), removed: rows(removed, prefix, renames)}}
      end)

    {positioned, _uuids} = position(tokens, %{})
    offsets(positioned)
  end

  defp rows(rows, prefix, renames) do
    rows
    |> Enum.map(fn row -> Map.new(row, fn {k, v} -> {k, value(v, prefix, renames)} end) end)
    |> Enum.sort_by(&:erlang.term_to_binary(mask(&1)))
  end

  defp value(<<_::128>> = uuid, _prefix, _renames), do: {:uuid, uuid}

  defp value(binary, prefix, renames) when is_binary(binary) do
    cond do
      not (String.valid?(binary) and String.printable?(binary)) -> {:bytes, byte_size(binary)}
      binding = codec_binding(binary) -> binding
      true -> {:text, rename(binary, prefix, renames)}
    end
  end

  defp value(list, prefix, renames) when is_list(list),
    do: Enum.map(list, &value(&1, prefix, renames))

  defp value(%DateTime{} = at, _prefix, _renames), do: {:at, DateTime.to_unix(at, :microsecond)}

  defp value(%NaiveDateTime{} = at, _prefix, _renames),
    do: {:at, at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)}

  defp value(%{__struct__: _} = struct, _prefix, _renames), do: struct

  defp value(%{} = map, prefix, renames),
    do: Map.new(map, fn {k, v} -> {value(k, prefix, renames), value(v, prefix, renames)} end)

  defp value(other, _prefix, _renames), do: other

  defp codec_binding(text) do
    with ["ao", tag, encoded] <- String.split(text, ":"),
         {:ok, digest} <- Base.url_decode64(encoded, padding: false) do
      {:binding, tag, {:bytes, byte_size(digest)}}
    else
      _other -> nil
    end
  end

  defp rename(text, prefix, renames) do
    Enum.reduce(renames, String.replace(text, prefix, "<prefix>"), fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  # The sort key with every UUID masked, so the order does not depend on the UUIDs.
  defp mask({:uuid, _uuid}), do: :uuid
  defp mask({:at, _at}), do: :at
  defp mask(%{__struct__: _} = struct), do: struct
  defp mask(%{} = map), do: Map.new(map, fn {k, v} -> {k, mask(v)} end)
  defp mask(list) when is_list(list), do: Enum.map(list, &mask/1)
  defp mask(other), do: other

  defp position({:uuid, uuid}, seen) do
    case seen do
      %{^uuid => n} -> {{:uuid, n}, seen}
      _new -> {{:uuid, map_size(seen)}, Map.put(seen, uuid, map_size(seen))}
    end
  end

  defp position(%{__struct__: _} = struct, seen), do: {struct, seen}

  defp position(%{} = map, seen) do
    {pairs, seen} =
      map
      |> Enum.sort()
      |> Enum.map_reduce(seen, fn {k, v}, acc ->
        {v, acc} = position(v, acc)
        {{k, v}, acc}
      end)

    {Map.new(pairs), seen}
  end

  defp position(list, seen) when is_list(list), do: Enum.map_reduce(list, seen, &position/2)
  defp position(other, seen), do: {other, seen}

  defp offsets(delta) do
    case stamps(delta, []) do
      [] -> delta
      stamps -> offset(delta, Enum.min(stamps))
    end
  end

  defp stamps({:at, at}, acc), do: [at | acc]
  defp stamps(%{__struct__: _}, acc), do: acc
  defp stamps(%{} = map, acc), do: Enum.reduce(map, acc, fn {_k, v}, a -> stamps(v, a) end)
  defp stamps(list, acc) when is_list(list), do: Enum.reduce(list, acc, &stamps/2)
  defp stamps(_other, acc), do: acc

  defp offset({:at, at}, base), do: {:at, at - base}
  defp offset(%{__struct__: _} = struct, _base), do: struct
  defp offset(%{} = map, base), do: Map.new(map, fn {k, v} -> {k, offset(v, base)} end)
  defp offset(list, base) when is_list(list), do: Enum.map(list, &offset(&1, base))
  defp offset(other, _base), do: other

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

  # Equality, except that two timestamp offsets within the clock tolerance are equal.
  defp equivalent?({:at, a}, {:at, b}), do: abs(a - b) <= @clock_tolerance
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
