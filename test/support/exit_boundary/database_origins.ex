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
      date_origins: %{},
      wire_ports: %{},
      last_rows: %{},
      source_rows: %{},
      releases: %{},
      wire_sql: %{},
      claim_binds: %{},
      payload_dates: if(history, do: history.payload_dates, else: %{}),
      date_checkpoints: %{},
      date_binds: %{},
      payload_results: %{},
      payload_children: side.historical.payload_children
    }

    state = Enum.reduce(events, initial, &event/2)
    parameter_copies(events, state)
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
    s =
      case wire_port(e.event) do
        port when is_port(port) -> put_in(s.wire_ports[e.role], port)
        _ -> s
      end

    s = release(e, s)
    s = date_flow(e, s)
    s = put_in(s.date_checkpoints[e.index], Map.get(s.dates, e.role))
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

  # First bind the date flowing through the completion to its native SELECT.
  # Every downstream SQL copy is then keyed by that statement and claim id.
  defp date_flow(
         %{event: {_, :call, {AshOnetime.Store.Postgres, :insert_payload, [_, date, id, _]}}} = e,
         s
       ) do
    expected = Map.get(s.dates, e.role)
    s = checked(s, e, [2, 2, 1], date, expected, :payload_date_argument)
    %{s | payload_dates: Map.put_new(s.payload_dates, uuid(id), expected)}
  end

  defp date_flow(
         %{event: {_, :call, {AshOnetime.Store.Postgres, :update_complete, [_, claim, date | _]}}} =
           e,
         s
       ),
       do: checked(s, e, [2, 2, 2], date, payload_date(s, claim.id), :completion_date_argument)

  defp date_flow(
         %{event: {_, :return_from, {AshOnetime.Store.Postgres, :database_date, 2}, {:ok, date}}} =
           e,
         s
       ),
       do: checked(s, e, [3, 1], date, Map.get(s.dates, e.role), :database_date_return)

  defp date_flow(%{event: {_, :call, {module, function, args}}} = e, s) do
    case completion_date_slot(module, function) do
      {:ok, index} ->
        checked(
          s,
          e,
          [2, 2, index],
          Enum.fetch!(args, index),
          s.dates[e.role],
          :completion_date_frame
        )

      :not_called ->
        s
    end
  end

  defp date_flow(_, s), do: s

  defp completion_date_slot(AshOnetime.Store.Postgres = module, function) do
    if String.starts_with?(Atom.to_string(function), "-complete_transaction/7-fun-") do
      slots =
        for {callee, arity, argument} <- [{:insert_payload, 4, 1}, {:update_complete, 7, 2}],
            {:ok, index} <- [
              AshOnetime.Test.ExitBoundary.Compiled.captured_argument(
                module,
                function,
                callee,
                arity,
                argument
              )
            ],
            do: index

      case slots do
        [index] -> {:ok, index}
        [] -> :not_called
        _ -> raise "ambiguous completion clock capture"
      end
    else
      :not_called
    end
  end

  defp completion_date_slot(_, _), do: :not_called

  def payload_date(s, id) do
    case Map.fetch(s.payload_dates, uuid(id)) do
      {:ok, date} ->
        date

      :error ->
        case Map.fetch(s.rows, {uuid(id), "complete"}) do
          {:ok, row} -> row["response_partition"]
          :error -> :missing_payload_date_origin
        end
    end
  end

  def payload_snapshot(table, row, s) do
    parent = s.statements.payload.table

    if table == parent or table in s.payload_children do
      expected = payload_date(s, row["claim_id"])

      if is_struct(expected, Date) do
        monthly = Registry.payload_partition(expected)
        child = if monthly in s.payload_children, do: monthly, else: parent <> "_default"
        expected_table = if table == parent, do: parent, else: child

        if table == expected_table and row["partition_date"] === expected do
          relation = if table == parent, do: parent, else: {:database_relation, :payload_child}

          {:ok, relation,
           Map.put(row, "partition_date", {:database_expression, :payload_date_snapshot})}
        else
          {:error, {table, row["partition_date"]}, {expected_table, expected}}
        end
      else
        {:error, row["partition_date"], expected}
      end
    else
      {:ok, table, row}
    end
  end

  defp date_statement(sql) when is_binary(sql) do
    cond do
      String.starts_with?(sql, "INSERT INTO ") and
          String.contains?(sql, "ash_onetime_response_payloads") ->
        {1, 2}

      String.starts_with?(sql, "UPDATE ") and String.contains?(sql, "SET state = 'complete'") ->
        {0, 7}

      String.starts_with?(sql, "SELECT partition_date, encoded_response") ->
        {2, 1}

      true ->
        nil
    end
  end

  defp date_statement(_), do: nil

  defp wire_date_bind(sql, binds, e, s) do
    case date_statement(sql) do
      {position, identity} ->
        id = binds |> Enum.at(identity) |> parameter_uuid()
        expected = payload_date(s, id)
        actual = binds |> Enum.at(position) |> elem(4) |> value()

        s =
          if actual === expected,
            do: s,
            else: failure(s, e, :database_date_bind, actual, expected)

        put_in(s.date_binds[{sql, id}], expected)

      nil ->
        s
    end
  end

  defp parameter_uuid({:bind_column, _, _, _, raw}), do: raw |> value() |> uuid()

  defp parameter_uuid(value) do
    case encoded_bytes(value) do
      <<_::128>> = binary -> uuid(binary)
      other -> uuid(other)
    end
  end

  defp encoded_bytes(%Date{} = date), do: date
  defp encoded_bytes(value) when is_binary(value) and byte_size(value) in [16, 36], do: value

  defp encoded_bytes(value) do
    case IO.iodata_to_binary(value) do
      <<n::signed-32, bytes::binary-size(n)>> -> bytes
      bytes -> bytes
    end
  rescue
    ArgumentError -> value
  end

  defp parameter_date({:bind_column, _, _, _, raw}), do: value(raw)
  defp parameter_date(%Date{} = date), do: date

  defp parameter_date(raw) do
    case encoded_bytes(raw) do
      <<days::signed-32>> -> Date.add(~D[2000-01-01], days)
      other -> other
    end
  end

  def sql({_, :call, {AshOnetime.Store.Postgres, f, [_target, sql | _]}})
      when f in [:query_claim, :dispatched_query] and is_binary(sql), do: sql

  def sql({_, :call, {m, f, [_repo, sql, _params, _opts]}})
      when m in [Ecto.Adapters.SQL, Postgrex] and f in [:query, :query!],
      do: IO.iodata_to_binary(sql)

  def sql({_, :call, {Postgrex, :prepare_execute, [_conn, _name, statement, _params, _opts]}}),
    do: IO.iodata_to_binary(statement)

  def sql(value), do: find_query(value)
  defp find_query(%Postgrex.Query{statement: sql}), do: IO.iodata_to_binary(sql)
  defp find_query(%DBConnection.LogEntry{query: query}), do: find_query(query)
  defp find_query(%{type: :ecto_sql_query, query: sql}), do: sql
  defp find_query({:parse, _name, sql, _count, _types}), do: sql
  defp find_query(value) when is_tuple(value), do: value |> Tuple.to_list() |> find_query()
  defp find_query([h | t]), do: find_query(h) || find_query(t)
  defp find_query(_), do: nil

  # SQL qualification has call lifetime. A logging closure has parameters but
  # no statement, so it belongs to its enclosing actual driver query instance.
  # Never carry the last statement into the next call on a reused connection.
  def sql_contexts(events) do
    {contexts, _open} =
      Enum.reduce(events, {%{}, %{}}, fn e, {contexts, open} ->
        scope = Map.get(open, e.pid, [])

        scope =
          case e.event do
            {_, :call, _} ->
              if query_frame?(e.mfa), do: [{e.mfa, sql(e.event)} | scope], else: scope

            _ ->
              scope
          end

        statement = sql(e.event) || case scope do
          [{_, statement} | _] -> statement
          [] -> nil
        end

        scope =
          case {e.event, scope} do
            {{_, tag, mfa, _}, [{mfa, _} | rest]}
            when tag in [:return_from, :exception_from] -> rest
            _ -> scope
          end

        {Map.put(contexts, e.index, statement), Map.put(open, e.pid, scope)}
      end)

    contexts
  end

  defp query_frame?({m, f, 4})
       when m in [Ecto.Adapters.SQL, Postgrex] and f in [:query, :query!], do: true

  defp query_frame?({Postgrex, :prepare_execute, 5}), do: true
  defp query_frame?({Postgrex, :execute, 4}), do: true
  defp query_frame?({DBConnection, f, 4}) when f in [:prepare_execute, :execute], do: true

  defp query_frame?({AshOnetime.Store.Postgres, f, _})
       when f in [:query_claim, :dispatched_query], do: true

  defp query_frame?(_), do: false

  defp parameter_copies(events, s) do
    contexts = sql_contexts(events)

    Enum.reduce(events, s, fn e, s ->
      statement = Map.fetch!(contexts, e.index)

      s =
        Enum.reduce(parameter_paths(e.mfa), s, fn path, acc ->
          copied_parameters(at(e.event, path), path, statement, e, acc)
        end)

      nested_copies(e.event, [], statement, e, s)
    end)
  end

  def parameter_paths(mfa) do
    case mfa do
      {AshOnetime.Store.Postgres, f, _} when f in [:query_claim, :dispatched_query] -> [[2, 2, 2]]
      {m, f, 4} when m in [Ecto.Adapters.SQL, Postgrex] and f in [:query, :query!] -> [[2, 2, 2]]
      {Postgrex, :prepare_execute, 5} -> [[2, 2, 3]]
      {Postgrex, :execute, 4} -> [[2, 2, 2]]
      {DBConnection, f, 4} when f in [:prepare_execute, :execute] -> [[2, 2, 2]]
      {DBConnection, :log, a} when a in [4, 5] -> [[2, 2, 3]]
      {DBConnection.LogEntry, :new, 5} -> [[2, 2, 2]]
      {Ecto.Adapters.SQL, :log, 5} -> [[2, 2, 2]]
      {:telemetry, :execute, 3} -> [[2, 2, 2, :params]]
      {:telemetry, :do_execute, 4} -> [[2, 2, 3, :params]]
      {Postgrex.Protocol, :handle_execute, 4} -> [[2, 2, 1]]
      _ -> []
    end
  end

  defp copied_parameters(parameters, path, sql, e, s) when is_list(parameters) do
    case date_statement(sql) do
      {position, identity} when length(parameters) > position and length(parameters) > identity ->
        id = parameters |> Enum.at(identity) |> parameter_uuid()
        expected = payload_date(s, id)
        raw = Enum.at(parameters, position)

        at =
          if match?({:bind_column, _, _, _, _}, raw),
            do: path ++ [position, 4],
            else: path ++ [position]

        encoded? = e.mfa == {Postgrex.Protocol, :handle_execute, 4} and path == [2, 2, 1]
        actual =
          if encoded? or match?({:bind_column, _, _, _, _}, raw),
            do: parameter_date(raw),
            else: raw

        if encoded? do
          if actual === expected,
            do: s,
            else: failure(s, e, :encoded_database_date_copy, actual, expected)
        else
          checked(s, e, at, actual, expected, :database_date_bind_copy)
        end

      _ ->
        s
    end
  end

  defp copied_parameters(_, _, _, _, s), do: s

  defp nested_copies(%DBConnection.LogEntry{params: params} = value, path, sql, e, s) do
    s = copied_parameters(params, path ++ [:params], sql, e, s)
    nested_copies(Map.delete(Map.from_struct(value), :params), path, sql, e, s)
  end

  defp nested_copies({:cast_params, params}, path, sql, e, s),
    do: copied_parameters(params, path ++ [1], sql, e, s)

  defp nested_copies(
         {:data_column, statement, {_, binds}, _, _, _, _, _, _, _},
         path,
         _sql,
         e,
         s
       ),
       do:
         if(wire_event?(e.event),
           do: copied_parameters(binds, path ++ [2, 1], statement, e, s),
           else: s
         )

  defp nested_copies({:bind, _, _, _, binds, _}, path, sql, e, s),
    do: if(wire_event?(e.event), do: copied_parameters(binds, path ++ [4], sql, e, s), else: s)

  defp nested_copies(fun, path, sql, e, s) when is_function(fun) do
    info = Map.new(Function.info(fun))
    base = path ++ [:function, :env]

    s =
      Enum.reduce(Registry.function_slots(info.module, info.name), s, fn
        {index, :parameters}, acc ->
          copied_parameters(Enum.fetch!(info.env, index), base ++ [index], sql, e, acc)

        _, acc ->
          acc
      end)

    s =
      case completion_date_slot(info.module, info.name) do
        {:ok, index} ->
          checked(
            s,
            e,
            base ++ [index],
            Enum.fetch!(info.env, index),
            s.date_checkpoints[e.index],
            :completion_date_environment
          )

        :not_called ->
          s
      end

    nested_copies(info.env, base, sql, e, s)
  end

  defp nested_copies(value, path, sql, e, s) when is_map(value),
    do:
      Enum.reduce(Map.to_list(value), s, fn {key, item}, acc ->
        nested_copies(item, path ++ [key], sql, e, acc)
      end)

  defp nested_copies(value, path, sql, e, s) when is_tuple(value),
    do: value |> Tuple.to_list() |> nested_copies(path, sql, e, s)

  defp nested_copies(value, path, sql, e, s) when is_list(value) do
    nested_list(value, path, sql, e, s, 0)
  end

  defp nested_copies(_, _, _, _, s), do: s
  defp nested_list([], _, _, _, s, _), do: s

  defp nested_list([h | t], path, sql, e, s, n),
    do: nested_list(t, path, sql, e, nested_copies(h, path ++ [n], sql, e, s), n + 1)

  defp nested_list(tail, path, sql, e, s, n), do: nested_copies(tail, path ++ [n], sql, e, s)

  def date_copy(value, parameters, sql, s) do
    case date_statement(sql) do
      {_position, identity} ->
        id = parameters |> Enum.at(identity) |> parameter_uuid()
        expected = payload_date(s, id)
        {parameter_date(value), expected}

      nil ->
        {value, :not_a_database_date_copy}
    end
  end

  defp at(value, []), do: value
  defp at(value, [key | path]) when is_tuple(value), do: at(elem(value, key), path)
  defp at(value, [key | path]) when is_list(value), do: at(Enum.at(value, key), path)
  defp at(value, [key | path]) when is_map(value), do: at(Map.get(value, key), path)
  defp at(_, _), do: nil

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
    s = wire_date_bind(sql, binds, e, s)

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

      String.starts_with?(sql, "SELECT partition_date, encoded_response") ->
        id = binds |> Enum.at(1) |> parameter_uuid()
        expected = payload_date(s, id)
        s = put_in(s.payload_results[e.role], expected)
        n = Enum.find_index(columns, &(elem(&1, 4) == "partition_date"))
        checked(s, e, path ++ [1, n, 9], row["partition_date"], expected, :payload_date_column)

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
        # The first DataRow of this exact native statement is the origin;
        # mirrored transport and caller returns are later copies of it.
        {:data_column, _, {ordinal, _}, _, _, _, _, _, _, _} = hd(columns)
        key = {Map.get(s.wire_ports, e.role), sql, ordinal}
        source = Map.get(s.date_origins, key, date)
        s = put_in(s.date_origins[key], source)
        s = put_in(s.dates[e.role], source)
        checked(s, e, path ++ [1, 0, 9], date, source, {:database_date, name})

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

  defp typed_copies(
         %Postgrex.Result{columns: ["partition_date", "encoded_response"], rows: [[date, _]]},
         path,
         e,
         s
       ) do
    checked(
      s,
      e,
      path ++ [:rows, 0, 0],
      date,
      Map.get(s.payload_results, e.role),
      :payload_date_result
    )
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
  defp wire_port({port, :receive, _}) when is_port(port), do: port
  defp wire_port({port, :send, _, _}) when is_port(port), do: port
  defp wire_port({_, :receive, {:tcp, port, _}}), do: port
  defp wire_port({_, :receive, {:inet_async, port, _, _}}), do: port

  defp wire_port({_, :call, {module, function, [port | _]}})
       when module in [:erlang, :erts_internal, :prim_inet, :gen_tcp] and
              function in [:port_command, :send, :recv, :recv0] and is_port(port),
       do: port

  defp wire_port(_), do: :caller_receive
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
