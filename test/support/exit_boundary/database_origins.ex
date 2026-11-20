defmodule AshOnetime.Test.ExitBoundary.DatabaseOrigins do
  @moduledoc false
  alias AshOnetime.Store.Claim
  alias AshOnetime.Test.ExitBoundary.Registry
  @epoch ~U[2000-01-01 00:00:00.000000Z]

  def build(events, side) do
    history = Map.get(side, :prior_database)
    prior = if history, do: Map.values(history.rows), else: []

    prior =
      prior ++
        Enum.map(Map.get(side, :claim_origins, []), fn claim ->
          Map.new(Map.from_struct(claim), fn {key, value} ->
            {Atom.to_string(key), if(key == :state, do: Atom.to_string(value), else: value)}
          end)
        end)

    rows = Map.new(prior, fn row -> {{uuid(row["id"]), row["state"]}, row} end)

    initial = %{
      host_owned: AshOnetime.Test.ExitBoundary.HostCall.indexes(events),
      relations: side.historical.relations,
      statements: Registry.database_statements(),
      rows: rows,
      latest: Map.new(prior, &{uuid(&1["id"]), &1}),
      peer_rows: if(history, do: history.peer_rows, else: %{}),
      peer_current: %{},
      slots: %{},
      errors: [],
      dates: %{},
      last_rows: %{},
      source_rows: %{},
      releases: %{},
      wire_sql: %{},
      claim_binds: %{}
    }

    Enum.reduce(events, initial, &event/2)
  end

  def project(event, index, state), do: project_at(event, index, [], state)

  def project_at(event, index, base, state),
    do:
      walk(event, base, fn value, path ->
        case Map.fetch(state.slots, {index, path}) do
          {:ok, token} -> {:replace, token}
          :error -> {:descend, value}
        end
      end)

  def claim(claim, state) do
    case Map.fetch(state.rows, {claim.id, Atom.to_string(claim.state)}) do
      {:ok, row} ->
        fields =
          for name <- state.statements.claim.clocks,
              into: %{},
              do: {String.to_existing_atom(name), row[name]}

        fields = Map.put(fields, :response_partition, row["response_partition"])
        {:ok, fields}

      :error ->
        :error
    end
  end

  defp event(e, s) do
    s = release(e, s)
    s = if wire_event?(e.event), do: data_rows(e.event, [], e, s), else: s

    s =
      case e.event do
        {_, :call, {AshOnetime.Store.Postgres, :decode_claim, [:idempotency, row]}} ->
          result_row(row, [2, 2, 1], e, s)

        _ ->
          s
      end

    if MapSet.member?(s.host_owned, e.index), do: s, else: typed_copies(e.event, [], e, s)
  end

  defp release(
         %{event: {_, :call, {AshOnetime.Store.Postgres, :release_query, [target, reference]}}} =
           e,
         s
       ) do
    # Release has no RETURNING clause. Its first subsequent SELECT is the native
    # wire origin of the new deadline; the paired UPDATE, binds and prior row close
    # its content route. No server timestamp is inferred from the deadline.
    rows =
      for {id, row} <- s.latest,
          row["logical_partition"] == target.logical_partition and
            row["hold_reference"] == reference,
          into: %{},
          do: {id, %{prior: row, source: e.index}}

    %{s | releases: Map.merge(s.releases, rows)}
  end

  defp release(_, s), do: s

  defp data_rows({:parse, _name, sql, _count, _types}, _path, e, s),
    do: put_in(s.wire_sql[e.role], sql)

  defp data_rows({:bind, _portal, _statement, _formats, binds, _result_formats}, _path, e, s) do
    sql = Map.get(s.wire_sql, e.role)

    if is_binary(sql) and String.starts_with?(sql, "INSERT INTO ") and
         String.contains?(sql, "ash_onetime_idempotency_claims") and length(binds) == 7 do
      {:bind_column, 1, 2950, _, id} = hd(binds)
      {:bind_column, 7, 20, _, retention} = Enum.at(binds, 6)
      key = {sql, uuid(value(id))}

      case Map.fetch(s.claim_binds, key) do
        {:ok, ^retention} -> s
        {:ok, previous} -> failure(s, e, :claim_bind_copy, retention, previous)
        :error -> put_in(s.claim_binds[key], retention)
      end
    else
      s
    end
  end

  defp data_rows({:data_row, columns}, path, e, s) when is_list(columns) and columns != [] do
    {:data_column, sql, {_ordinal, binds}, _, _, _, _, _, _, _} = hd(columns)

    row =
      Map.new(columns, fn {:data_column, _, _, _, name, _, _, _, _, value} ->
        {name, value(value)}
      end)

    cond do
      relation(columns, s) == s.statements.claim.table and
          Enum.sort(Map.keys(row)) == Enum.sort(s.statements.claim.columns) ->
        {expected, s} = row_origin(row, sql, binds, e, s)

        s =
          Enum.with_index(columns)
          |> Enum.reduce(s, fn {{:data_column, _, _, _, name, _, _, _, _, raw}, n}, acc ->
            if name in acc.statements.claim.clocks or name == "response_partition" do
              checked(
                acc,
                e,
                path ++ [1, n, 9],
                value(raw),
                expected[name],
                {:database_column, name}
              )
            else
              acc
            end
          end)

        s
        |> put_in([:last_rows, e.role], expected)
        |> put_in([:source_rows, {e.role, sql}], expected)

      relation(columns, s) in s.statements.peer.tables and
        Map.has_key?(row, "operation_key") and Map.has_key?(row, "inserted_at") ->
        table = relation(columns, s)
        identity = row["event_id"] || uuid(row["operation_key"])
        source = Map.get(s.peer_rows, {table, identity}, row)

        s =
          put_in(s.peer_rows[{table, identity}], source) |> put_in([:peer_current, e.role], table)

        Enum.with_index(columns)
        |> Enum.reduce(s, fn {{:data_column, _, _, _, name, _, _, _, _, raw}, n}, acc ->
          if name == "inserted_at",
            do:
              checked(
                acc,
                e,
                path ++ [1, n, 9],
                value(raw),
                source[name],
                {:peer_timestamp, table}
              ),
            else: acc
        end)

      sql in s.statements.date.statements and Map.keys(row) == s.statements.date.columns ->
        [{name, date}] = Map.to_list(row)
        s = put_in(s.dates[e.role], date)
        checked(s, e, path ++ [1, 0, 9], date, date, {:database_date, name})

      true ->
        s
    end
  end

  defp data_rows(value, path, e, s) when is_map(value),
    do:
      Enum.reduce(Map.to_list(value), s, fn {key, item}, acc ->
        data_rows(item, path ++ [key], e, acc)
      end)

  defp data_rows(value, path, e, s) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce(s, fn {item, n}, acc -> data_rows(item, path ++ [n], e, acc) end)

  defp data_rows(value, path, e, s) when is_list(value), do: data_list(value, path, e, s, 0)
  defp data_rows(_, _, _, s), do: s
  defp data_list([], _, _, s, _), do: s

  defp data_list([h | t], path, e, s, n),
    do: data_list(t, path, e, data_rows(h, path ++ [n], e, s), n + 1)

  defp data_list(t, path, e, s, n), do: data_rows(t, path ++ [n], e, s)

  defp row_origin(row, sql, binds, e, s) do
    id = uuid(row["id"])
    previous = Map.get(s.latest, id)

    cond do
      String.starts_with?(sql, "INSERT INTO ") and previous == nil ->
        # The first wire column is the native transaction-clock origin. The two
        # other columns are expressions of that origin, never new freedoms.
        admitted = row["admitted_at"]
        {:bind_column, 7, 20, _, retention} = Enum.at(binds, 6)

        expected =
          row
          |> Map.put("inserted_at", admitted)
          |> Map.put("retain_until", DateTime.add(admitted, retention, :second))

        {expected, remember(s, expected)}

      String.starts_with?(sql, "UPDATE ") and String.contains?(sql, "SET state = 'complete'") and
        previous != nil and previous["state"] == "processing" ->
        expected =
          row
          |> Map.put("admitted_at", previous["admitted_at"])
          |> Map.put("inserted_at", previous["inserted_at"])

        # External retain_until is the first wire value of the statement-clock
        # result. Exact paired SQL and binds close its content route (O4).
        expected =
          if String.contains?(sql, "retain_until = statement_timestamp()"),
            do: expected,
            else: Map.put(expected, "retain_until", previous["retain_until"])

        date = bind_value(binds, 1)
        expected = Map.put(expected, "response_partition", date)
        {expected, remember(s, expected)}

      Map.has_key?(s.releases, id) ->
        %{prior: prior} = s.releases[id]

        expected =
          prior
          |> Map.put("hold_reference", nil)
          |> Map.put("retain_until", row["retain_until"])

        s =
          if DateTime.compare(row["retain_until"], prior["retain_until"]) in [:eq, :gt],
            do: s,
            else: failure(s, e, :release_greatest, row["retain_until"], prior["retain_until"])

        s = %{s | releases: Map.delete(s.releases, id)}
        {expected, remember(s, expected)}

      previous != nil ->
        expected = Map.get(s.rows, {id, row["state"]}, previous)
        {expected, s}

      true ->
        {row, failure(s, e, :missing_prior_row, id, :captured_statement)}
    end
  end

  defp remember(s, row),
    do: %{
      s
      | latest: Map.put(s.latest, uuid(row["id"]), row),
        rows: Map.put(s.rows, {uuid(row["id"]), row["state"]}, row)
    }

  defp bind_value(binds, n), do: binds |> Enum.at(n - 1) |> elem(4) |> value()

  defp result_row(row, path, e, s) do
    id = row |> hd() |> uuid()
    status = Enum.at(row, 6)

    case Map.fetch(s.rows, {id, status}) do
      {:ok, source} ->
        Enum.with_index(s.statements.claim.columns)
        |> Enum.reduce(s, fn {name, n}, acc ->
          if name in acc.statements.claim.clocks or name == "response_partition",
            do:
              checked(acc, e, path ++ [n], Enum.at(row, n), source[name], {:decoded_column, name}),
            else: acc
        end)

      :error ->
        failure(s, e, :decode_before_wire, id, :wire_row)
    end
  end

  defp typed_copies(%Claim{id: id} = claim, path, e, s) when is_binary(id) do
    case claim(claim, s) do
      {:ok, fields} ->
        Enum.reduce(fields, s, fn {key, expected}, acc ->
          checked(acc, e, path ++ [key], Map.fetch!(claim, key), expected, {:claim_column, key})
        end)

      :error ->
        failure(s, e, :missing_claim_origin, claim.id, :wire_claim)
    end
  end

  defp typed_copies(%Postgrex.Result{columns: columns, rows: rows}, path, e, s)
       when is_list(columns) and is_list(rows) do
    if columns == s.statements.claim.columns do
      Enum.with_index(rows)
      |> Enum.reduce(s, fn {row, n}, acc ->
        id = row |> hd() |> uuid()
        status = Enum.at(row, 6)

        case Map.fetch(s.rows, {id, status}) do
          {:ok, source} ->
            Enum.with_index(columns)
            |> Enum.reduce(acc, fn {name, k}, acc ->
              if name in acc.statements.claim.clocks or name == "response_partition",
                do:
                  checked(
                    acc,
                    e,
                    path ++ [:rows, n, k],
                    Enum.at(row, k),
                    source[name],
                    {:result_column, name}
                  ),
                else: acc
            end)

          :error ->
            failure(acc, e, :result_before_wire, id, :wire_row)
        end
      end)
    else
      if "operation_key" in columns and "inserted_at" in columns do
        Enum.with_index(rows)
        |> Enum.reduce(s, fn {values, n}, acc ->
          row = Map.new(Enum.zip(columns, values))
          identity = row["event_id"] || uuid(row["operation_key"])
          table = s.peer_current[e.role]

          case Map.fetch(s.peer_rows, {table, identity}) do
            {:ok, source} ->
              k = Enum.find_index(columns, &(&1 == "inserted_at"))

              checked(
                acc,
                e,
                path ++ [:rows, n, k],
                row["inserted_at"],
                source["inserted_at"],
                {:peer_timestamp_copy, table}
              )

            _ ->
              failure(acc, e, :peer_before_returning, identity, :wire_row)
          end
        end)
      else
        if columns == s.statements.date.columns do
          case Map.fetch(s.dates, e.role) do
            {:ok, expected} ->
              checked(s, e, path ++ [:rows, 0, 0], hd(hd(rows)), expected, :database_date_copy)

            :error ->
              s
          end
        else
          s
        end
      end
    end
  end

  defp typed_copies(value, path, e, s) when is_function(value) do
    {:env, env} = Function.info(value, :env)
    typed_copies(env, path ++ [:function, :env], e, s)
  end

  defp typed_copies(value, path, e, s) when is_map(value),
    do:
      Enum.reduce(Map.to_list(value), s, fn {key, item}, acc ->
        typed_copies(item, path ++ [key], e, acc)
      end)

  defp typed_copies(value, path, e, s) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce(s, fn {item, n}, acc -> typed_copies(item, path ++ [n], e, acc) end)

  defp typed_copies(value, path, e, s) when is_list(value), do: typed_list(value, path, e, s, 0)
  defp typed_copies(_, _, _, s), do: s
  defp typed_list([], _, _, s, _), do: s

  defp typed_list([h | t], path, e, s, n),
    do: typed_list(t, path, e, typed_copies(h, path ++ [n], e, s), n + 1)

  defp typed_list(t, path, e, s, n), do: typed_copies(t, path ++ [n], e, s)

  defp checked(s, e, path, actual, expected, token) do
    if actual === expected,
      do: put_in(s.slots[{e.index, path}], {:database_expression, token}),
      else: failure(s, e, {token, path}, actual, expected)
  end

  defp failure(s, e, rule, actual, expected),
    do: %{
      s
      | errors: [
          %{
            at: Map.take(e, [:mfa, :role, :stack]),
            index: e.index,
            rule: rule,
            actual: actual,
            expected: expected
          }
          | s.errors
        ]
    }

  defp relation(columns, s) do
    tables =
      for {:data_column, _, _, _, _, {:table_oid, oid}, _, _, _, _} <- columns,
          do: Map.get(s.relations, oid, :undeclared_relation)

    case Enum.uniq(tables) do
      [table] -> table
      _ -> :mixed_relations
    end
  end

  # Only the protocol decoder's transport positions may create a wire origin.
  # A tuple with the same tag in a package argument remains an ordinary term.
  defp wire_event?({port, :receive, {_pid, {:command, {:pg_transport, _, _, _}}}}),
    do: is_port(port)

  defp wire_event?({port, :send, {:tcp, port, {:pg_transport, _, _, _}}, _pid}), do: is_port(port)

  defp wire_event?(
         {port, :send, {:inet_async, port, _ref, {:ok, {:pg_transport, _, _, _}}}, _pid}
       ),
       do: is_port(port)

  defp wire_event?({_pid, :receive, {:tcp, port, {:pg_transport, _, _, _}}}), do: is_port(port)

  defp wire_event?({_pid, :receive, {:inet_async, port, _ref, {:ok, {:pg_transport, _, _, _}}}}),
    do: is_port(port)

  defp wire_event?({_pid, :call, {module, function, [port, {:pg_transport, _, _, _} | _]}})
       when module in [:erlang, :erts_internal, :prim_inet, :gen_tcp] and
              function in [:port_command, :send],
       do: is_port(port)

  defp wire_event?({_pid, :return_from, {module, function, _}, {:ok, {:pg_transport, _, _, _}}})
       when module in [:prim_inet, :gen_tcp] and function in [:recv, :recv0], do: true

  defp wire_event?(_), do: false
  defp value({:timestamptz, micros}), do: DateTime.add(@epoch, micros, :microsecond)
  defp value({:date, days}), do: Date.add(~D[2000-01-01], days)
  defp value({:uuid, value}), do: value
  defp value(value), do: value
  defp uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp uuid(value), do: value

  defp walk_list([], _, _, _), do: []

  defp walk_list([h | t], path, fun, n),
    do: [walk(h, path ++ [n], fun) | walk_list(t, path, fun, n + 1)]

  defp walk_list(t, path, fun, n), do: walk(t, path ++ [n], fun)

  defp walk(value, path, fun) do
    case fun.(value, path) do
      {:replace, result} ->
        result

      {:descend, value} when is_map(value) ->
        Map.new(Map.to_list(value), fn {key, item} -> {key, walk(item, path ++ [key], fun)} end)

      {:descend, value} when is_tuple(value) ->
        value
        |> Tuple.to_list()
        |> Enum.with_index()
        |> Enum.map(fn {item, n} -> walk(item, path ++ [n], fun) end)
        |> List.to_tuple()

      {:descend, value} when is_list(value) ->
        walk_list(value, path, fun, 0)

      {:descend, value} ->
        value
    end
  end
end
