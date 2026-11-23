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
