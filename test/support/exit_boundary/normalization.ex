defmodule AshOnetime.Test.ExitBoundary.Normalization do
  @moduledoc false

  # The differences declared by the paired fixtures, in one place. No binary or
  # numeric value is interchangeable merely because its type or width is the same.
  alias AshOnetime.{Fingerprint, Response, Store}
  alias AshOnetime.Resource.Info
  alias AshOnetime.Test.ExitBoundary.{External, Producer, Returned, ReturnedExternal, Withheld}
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @modules %{Withheld => Returned, External => ReturnedExternal}
  @postgresql_tags ~c"123ABCDEFGHIKNPQRSTVWXZbcdfnpsstv"
  @database_clock_tolerance 5_000_000

  # Align only clock tokens obtained from authoritative rows/returns, within the
  # measured observation interval. Semantic integers and opaque bytes never enter it.
  def align(%{normalization: run} = left, %{normalization: twin} = right) do
    offsets = for names <- [run, twin], {_, {:database_clock, at}} <- names, do: at

    # Statement clocks can span the real preparation/observation interval,
    # especially recovery's interrupted first call. Bound scheduling alignment by
    # that measured interval; no semantic number enters this clock-only set.
    tolerance = max(@database_clock_tolerance, run[:observed_elapsed] + twin[:observed_elapsed])

    {clocks, _} =
      offsets
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_reduce(nil, fn at, anchor ->
        anchor =
          if is_nil(anchor) or at - anchor > tolerance, do: at, else: anchor

        {{at, anchor}, anchor}
      end)

    clocks = Map.new(clocks)

    normalize = fn names ->
      Map.new(names, fn {from, to} -> {from, align_clock(to, clocks)} end)
    end

    {%{left | normalization: normalize.(run)}, %{right | normalization: normalize.(twin)}}
  end

  defp align_clock({:database_clock, at}, clocks), do: {:database_clock, Map.get(clocks, at, at)}

  defp align_clock(tuple, clocks) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> align_clock(clocks) |> List.to_tuple()

  defp align_clock(list, clocks) when is_list(list), do: Enum.map(list, &align_clock(&1, clocks))

  defp align_clock(%{} = map, clocks),
    do: Map.new(Map.to_list(map), fn {k, v} -> {k, align_clock(v, clocks)} end)

  defp align_clock(value, _clocks), do: value

  @uuid_generators [{Ecto.UUID, :generate, 0}, {Ash.UUID, :generate, 0}]
  @clock_generators for function <- [:monotonic_time, :system_time],
                        arity <- [0, 1],
                        do: {:erlang, function, arity}

  def frames,
    do:
      @uuid_generators ++
        @clock_generators ++
        [
          {DateTime, :utc_now, 0},
          {DateTime, :utc_now, 1},
          {:erlang, :unique_integer, 0},
          {:erlang, :unique_integer, 1},
          {Store, :claim, 2},
          {Store, :claim_committed, 2},
          {Store, :claim_committed, 3},
          {Splode, :filter_stacktrace, 2},
          {Kernel, :inspect, 2}
        ]

  # Establish every real pooled connection before observing an action. A checkout
  # barrier holds all ten connections at once, so authentication and initial type
  # loading cannot depend on which connection the paired call receives.
  def prepare(repo) do
    parent = self()
    tag = make_ref()

    tasks =
      for _ <- 1..10 do
        Task.async(fn -> prepare_connection(repo, parent, tag) end)
      end

    try do
      for _ <- tasks do
        receive do
          {^tag, _pid} -> :ok
        after
          30_000 -> raise "exit-boundary pool did not finish preparation"
        end
      end
    after
      for task <- tasks, do: send(task.pid, {tag, :release})
      for task <- tasks, do: Task.await(task, 30_000)
    end

    :ok
  end

  defp prepare_connection(repo, parent, tag) do
    Repo.put_dynamic_repo(repo)

    Repo.checkout(fn ->
      SQL.query!(Repo, "SELECT 1", [])
      send(parent, {tag, self()})
      receive do: ({^tag, :release} -> :ok)
    end)
  end

  # Only the entry path differs: deliver/2 adds package frames around the same
  # action, and Ash may tail-call its entry. Analysis retains every argument list,
  # in order and with multiplicity, independently of that path's frame identities.
  def path_frame?(module)
      when module in [
             Ash,
             AshOnetime,
             AshOnetime.Test.ExitBoundary.Pair,
             AshOnetime.Test.ExitBoundary.Root
           ],
      do: true

  def path_frame?(module) do
    name = Atom.to_string(module)

    String.starts_with?(name, "Elixir.AshOnetime.") and
      not String.starts_with?(name, "Elixir.AshOnetime.Test.")
  end

  def runtime(prefix) do
    %{rows: relations} =
      SQL.query!(
        Repo,
        "SELECT c.oid::bigint, c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1",
        [prefix]
      )

    tables = for table <- :ets.all(), do: {table, readable(table)}

    connections =
      for {table, rows} <- tables,
          row <- rows,
          {:conn, _owner, Postgrex.Protocol, %Postgrex.Protocol{} = state, _lock, clock,
           _deadline, _status} <- [row],
          do: {table, state.connection_id, state.connection_key, clock, state.scram}

    holders = MapSet.new(connections, &elem(&1, 0))

    # DBConnection.ConnectionPool's ready queue holds {{checkin_native, holder}}.
    # Only entries referring to an actual Postgrex holder in this pre-run snapshot
    # are trusted clock origins; a value placed in an observed exit cannot add one.
    pool_clocks =
      for {_table, rows} <- tables,
          {{at, holder}} <- rows,
          is_integer(at) and MapSet.member?(holders, holder),
          do: {:monotonic_time, :native, at}

    %{
      postgresql_relations: Map.new(relations, fn [oid, name] -> {oid, {:relation, name}} end),
      protocol_connections:
        Map.new(connections, fn {_, id, key, _, scram} -> {{id, key}, scram} end),
      backend_ids: MapSet.new(connections, &elem(&1, 1)),
      connection_clocks: MapSet.new(connections, &elem(&1, 3)),
      pool_clocks: pool_clocks
    }
  end

  defp readable(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end

  def new(prefix, resource, path, subject, before, events, runtime) do
    names =
      runtime
      |> Map.merge(@modules)
      |> Map.merge(%{prefix => "<prefix>", inspect(Withheld) => inspect(Returned)})
      |> Map.put(:clock_values, clock_values(events, runtime))
      |> Map.put(:cache_clock_reads, cache_clock_reads(events))
      |> Map.put(:tcp_receive_replies, tcp_receive_replies(events))
      |> Map.put(
        :query_ids,
        MapSet.new(
          for %{event: {_, :return_from, {:erlang, :unique_integer, _}, id}} <- events, do: id
        )
      )

    {:ok, operation} =
      Fingerprint.compute(%{domain: :operation, resource: inspect(resource), action: path.action})

    {:ok, canonical_operation} =
      Fingerprint.compute(%{domain: :operation, resource: inspect(Returned), action: path.action})

    names = Map.put(names, operation, canonical_operation)

    protection = Info.protection(resource, path.action)
    # Admission always stores the destroyed record, independently of Ash's caller option.
    trusted = if path.type == :destroy, do: %{return_destroyed?: true}, else: %{}
    {:ok, contract} = Response.contract(resource, path.action, protection.response, trusted)

    {:ok, canonical_contract} =
      Response.contract(
        Returned,
        path.action,
        Info.protection(Returned, path.action).response,
        trusted
      )

    names = Map.put(names, contract.digest, canonical_contract.digest)
    binding = fn digest -> "ao:boundary:" <> Base.url_encode64(digest, padding: false) end
    names = Map.put(names, binding.(contract.digest), binding.(canonical_contract.digest))
    names = fixture_metadata(names, protection, Info.protection(Returned, path.action))

    names =
      fixture_metadata(
        names,
        Ash.Resource.Info.action(resource, path.action),
        Ash.Resource.Info.action(Returned, path.action)
      )

    # Existing UUIDs come from the snapshot before the observed call; fresh claim
    # UUIDs come from the real generator's return trace, never from the compared exit.
    existing =
      before |> Map.get("ash_onetime_idempotency_claims", []) |> Enum.sort_by(& &1["key_hash"])

    names =
      Enum.with_index(existing)
      |> Enum.reduce(names, fn {row, n}, acc -> uuid(acc, row["id"], {:existing_claim, n}) end)

    id =
      case subject do
        %Ash.Changeset{} -> Ash.Changeset.get_attribute(subject, :id)
        _ -> nil
      end

    names =
      before
      |> Map.get("ash_onetime_boundary_records", [])
      |> Enum.sort_by(&Map.drop(&1, ["id"]))
      |> Enum.with_index()
      |> Enum.reduce(names, fn {row, n}, acc -> uuid(acc, row["id"], {:existing_record, n}) end)
      |> uuid(id, :fixture_record)

    reference =
      Enum.find_value(events, fn
        %{
          event:
            {_pid, :call,
             {AshOnetime.Delivery, :armed,
              [_subject, _protection, {_key, ref, _private, _public}, _opts]}}
        } ->
          ref

        _ ->
          nil
      end)

    cell = get_in(subject.context, [:private, :ash_onetime_delivery_cell])
    names = names |> Map.put(:delivery_reference, reference) |> Map.put(:delivery_cell, cell)

    generated =
      for %{event: {_pid, :return_from, mfa, id}} <- events, mfa in @uuid_generators, do: id

    names =
      generated
      |> Enum.uniq()
      |> Enum.with_index()
      |> Enum.reduce(names, fn {id, n}, acc -> uuid(acc, id, {:generated_uuid, n}) end)
      |> payloads(Map.new(before, fn {table, rows} -> {table, %{added: rows, removed: []}} end))
      |> claim_clocks(events)

    hashes(names, events)
  end

  defp claim_clocks(names, events) do
    rows =
      for %{
            event:
              {_, :return_from, {Store, function, _},
               %Store.Result{claim: %Store.Claim{} = claim}}
          } <- events,
          function in [:claim, :claim_committed],
          do: Map.new(Map.from_struct(claim), fn {key, value} -> {Atom.to_string(key), value} end)

    payloads(names, %{"claims" => %{added: rows, removed: []}})
  end

  defp hashes(names, events) do
    Enum.reduce(events, names, fn
      %{event: {_pid, :call, {:crypto, :hash, [algorithm, input]}}}, acc ->
        bytes = IO.iodata_to_binary(input)
        Map.put(acc, :crypto.hash(algorithm, bytes), {:derived_hash, algorithm, term(bytes, acc)})

      _, acc ->
        acc
    end)
  end

  # Clock normalization requires a real clock read (or an elapsed interval between
  # two such reads). Replacing a measurement with an unrelated number stays visible.
  defp clock_values(events, runtime) do
    {_, reads} =
      Enum.reduce(events, {%{}, runtime.pool_clocks}, fn
        %{event: {pid, :call, {:erlang, function, args}}}, {pending, reads}
        when function in [:monotonic_time, :system_time] and length(args) in [0, 1] ->
          {Map.put(pending, {pid, function, length(args)}, List.first(args) || :native), reads}

        %{event: {pid, :return_from, {:erlang, function, arity}, value}}, {pending, reads}
        when function in [:monotonic_time, :system_time] and arity in [0, 1] and is_integer(value) ->
          case Map.pop(pending, {pid, function, arity}) do
            {nil, pending} -> {pending, reads}
            {unit, pending} -> {pending, [{function, unit, value} | reads]}
          end

        _, acc ->
          acc
      end)

    elapsed =
      for {:monotonic_time, unit, a} <- reads,
          {:monotonic_time, ^unit, b} <- reads,
          b >= a,
          target <- [:native, :second, :millisecond, :microsecond, :nanosecond],
          do: System.convert_time_unit(b - a, unit, target)

    MapSet.new(Enum.map(reads, &elem(&1, 2)) ++ elapsed)
  end

  defp clock(value, names, token) do
    if MapSet.member?(Map.get(names, :clock_values, MapSet.new()), value), do: token, else: value
  end

  defp cache_clock_reads(events) do
    utc =
      for %{event: {_, :return_from, {DateTime, :utc_now, _}, %DateTime{} = at}} <- events, do: at

    seconds =
      for %{event: {pid, :call, {:erlang, :monotonic_time, [:second]}}} <- events,
          %{event: {^pid, :return_from, {:erlang, :monotonic_time, 1}, at}} <- events,
          is_integer(at),
          do: at

    {Enum.uniq(utc), Enum.uniq(seconds)}
  end

  defp uuid(names, nil, _token), do: names

  defp uuid(names, id, token) do
    {:ok, text} = Ecto.UUID.cast(id)
    names |> Map.put(text, token) |> Map.put(Ecto.UUID.dump!(text), token)
  end

  def term(%AshOnetime.Resource.Protection{} = protection, names) do
    # Only these two declared producer/executing-only differences are normalized.
    protection =
      case protection do
        %{executing_only: [:short, :long], produce: Producer} ->
          %{protection | executing_only: [], produce: nil}

        %{executing_only: [:short, :long], external_effect: External} ->
          %{protection | executing_only: []}

        _ ->
          protection
      end

    map(protection, names)
  end

  def term(%Spark.Dsl.Entity.Meta{} = value, names), do: Map.get(names, value, value)

  def term(%Postgrex.Protocol{} = state, names) do
    state =
      case Map.fetch(
             Map.get(names, :protocol_connections, %{}),
             {state.connection_id, state.connection_key}
           ) do
        {:ok, scram} ->
          state =
            if state.scram == scram, do: %{state | scram: :authenticated_connection}, else: state

          %{state | connection_id: :backend_identity, connection_key: :backend_key_identity}

        :error ->
          state
      end

    map(state, names)
  end

  def term(%Postgrex.Result{} = result, names) do
    result =
      if MapSet.member?(Map.get(names, :backend_ids, MapSet.new()), result.connection_id),
        do: %{result | connection_id: :backend_identity},
        else: result

    map(result, names)
  end

  def term(%Postgrex.Error{} = error, names) do
    error =
      if MapSet.member?(Map.get(names, :backend_ids, MapSet.new()), error.connection_id),
        do: %{error | connection_id: :backend_identity},
        else: error

    map(error, names)
  end

  def term(%DateTime{} = value, names), do: Map.get(names, value, value)
  def term(%NaiveDateTime{} = value, names), do: Map.get(names, value, value)
  def term(%{} = value, names), do: map(value, names)
  def term(list, names) when is_list(list), do: list(list, names)

  # DBConnection's named pool bookkeeping slots contain runtime clock readings.
  # The timeout, queue policy, connection state and every other argument remain.
  def term({:db_connection, from, {:checkout, callers, start, queue?}}, names)
      when is_integer(start),
      do:
        {:db_connection, term(from, names),
         {:checkout, term(callers, names), clock(start, names, :pool_clock), queue?}}

  def term({:"ETS-TRANSFER", holder, pool, {lock, reference, checkin}}, names)
      when is_integer(checkin),
      do:
        {:"ETS-TRANSFER", term(holder, names), term(pool, names),
         {term(lock, names), term(reference, names), clock(checkin, names, :pool_clock)}}

  def term({:checkin, reference, at}, names) when is_integer(at),
    do: {:checkin, term(reference, names), clock(at, names, :pool_clock)}

  def term({:conn, owner, Postgrex.Protocol, state, lock, connected_at, deadline, status}, names) do
    at =
      if MapSet.member?(Map.get(names, :connection_clocks, MapSet.new()), connected_at),
        do: :connection_clock,
        else: connected_at

    {:conn, term(owner, names), Postgrex.Protocol, term(state, names), term(lock, names), at,
     term(deadline, names), term(status, names)}
  end

  # Ecto.Adapters.SQL.prepare/2 gives a compiled SQL query a fresh unique integer.
  # Keep the entire SQL and normalize only an identity returned by that generator.
  def term({id, sql}, names) when is_integer(id) and is_binary(sql) do
    if MapSet.member?(Map.get(names, :query_ids, MapSet.new()), id),
      do: {:prepared_query_identity, binary(sql, names)},
      else: {id, binary(sql, names)}
  end

  def term({id, %Postgrex.Query{} = query}, names) when is_integer(id) do
    identity =
      if MapSet.member?(Map.get(names, :query_ids, MapSet.new()), id),
        do: :prepared_query_identity,
        else: id

    {identity, term(query, names)}
  end

  def term(tuple, names) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> term(names) |> List.to_tuple()

  def term(value, names) when is_binary(value), do: binary(value, names)
  def term(value, names), do: Map.get(names, value, value)

  # The package's two hook implementations capture the same context/protection;
  # delivery adds exactly its builder cell and the declared executing-only names.
  # Keep all other environment entries, including any substituted payload.
  def function(info, names) do
    if info.module in [AshOnetime.Change, AshOnetime.GenericAction] and
         String.starts_with?(Atom.to_string(info.name), "-install_delivery/4-fun-") do
      env = Enum.reject(info.env, &(&1 == names[:delivery_cell] or &1 == [:short, :long]))

      name =
        info.name
        |> Atom.to_string()
        |> String.replace("install_delivery/4", "install/3")
        |> String.to_existing_atom()

      %{info | name: name, env: env}
    else
      info
    end
  end

  defp map(value, names) do
    value
    |> drop_context(names)
    |> Map.to_list()
    |> Map.new(fn {key, value} -> {term(key, names), term(value, names)} end)
  end

  # The only subject-context additions: exactly the 16-byte delivery reference,
  # and the builder cell reference. Extra entries remain visible and comparable.
  defp drop_context(map, names) do
    map =
      case map do
        %{ash_onetime_delivery: %{ref: ref} = value}
        when is_binary(ref) and byte_size(ref) == 16 and map_size(value) == 1 ->
          if ref == names[:delivery_reference],
            do: Map.delete(map, :ash_onetime_delivery),
            else: map

        _ ->
          map
      end

    case map do
      %{ash_onetime_delivery_cell: cell} when is_reference(cell) ->
        if cell == names[:delivery_cell],
          do: Map.delete(map, :ash_onetime_delivery_cell),
          else: map

      _ ->
        map
    end
  end

  # Exact source annotations from the two trusted DSL declarations identify their
  # locations and the declared producer fields. An altered annotation is not erased.
  defp fixture_metadata(names, %Spark.Dsl.Entity.Meta{} = left, %Spark.Dsl.Entity.Meta{} = right),
    do: Map.put(names, left, right)

  defp fixture_metadata(names, left, right) when is_map(left) and is_map(right),
    do:
      left
      |> Map.to_list()
      |> Enum.reduce(names, fn {key, value}, acc ->
        fixture_metadata(acc, value, Map.get(right, key))
      end)

  defp fixture_metadata(names, left, right) when is_list(left) and is_list(right),
    do:
      Enum.zip(left, right)
      |> Enum.reduce(names, fn {l, r}, acc -> fixture_metadata(acc, l, r) end)

  defp fixture_metadata(names, left, right) when is_tuple(left) and is_tuple(right),
    do: fixture_metadata(names, Tuple.to_list(left), Tuple.to_list(right))

  defp fixture_metadata(names, _left, _right), do: names
  defp list([head | tail], names), do: [term(head, names) | list(tail, names)]
  defp list(other, names), do: term_tail(other, names)
  defp term_tail([], _names), do: []
  defp term_tail(other, names), do: term(other, names)

  def binary(value, names) do
    case Map.fetch(names, value) do
      {:ok, normalized} -> normalized
      :error -> encoded_or_text(value, names)
    end
  end

  defp encoded_or_text(<<131, _::binary>> = value, names) do
    {decoded, used} = :erlang.binary_to_term(value, [:safe, :used])

    encoding =
      cond do
        :erlang.term_to_binary(decoded) == value -> :default
        :erlang.term_to_binary(decoded, [:deterministic]) == value -> :deterministic
        true -> nil
      end

    if used == byte_size(value) and encoding,
      do: {:encoded_term, encoding, term(decoded, names)},
      else: value
  rescue
    ArgumentError -> value
  end

  defp encoded_or_text(<<17::32, "ash_onetime-cache", rest::binary>> = value, names) do
    case cache_components(rest, 4, []) do
      {:ok, components} -> {:cache_key_input, Enum.map(components, &binary(&1, names))}
      :error -> text(value, names)
    end
  end

  defp encoded_or_text(value, names), do: text(value, names)

  defp cache_components(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp cache_components(<<size::32, value::binary-size(size), rest::binary>>, count, acc)
       when count > 0,
       do: cache_components(rest, count - 1, [value | acc])

  defp cache_components(_, _, _), do: :error

  defp text(value, names) do
    Enum.reduce(names, value, fn
      {from, to}, text when is_binary(from) and is_binary(to) -> String.replace(text, from, to)
      _, text -> text
    end)
  end

  # Only named instrumentation clocks are nondeterministic. Counts, measurements
  # outside this allowlist, metadata and all callback arguments remain semantic.
  @measurement_clocks [
    :duration,
    :system_time,
    :monotonic_time,
    :query_time,
    :decode_time,
    :total_time,
    :queue_time,
    :idle_time
  ]
  def event(%{event: {pid, :call, {:telemetry, function, args}}} = event, names)
      when function in [:execute, :do_execute] do
    case args do
      [[namespace | _] = name, measurements, metadata | rest]
      when namespace in [:ash, :ash_onetime] and is_map(measurements) ->
        measurements = measurement_clocks(measurements, names)

        %{
          event
          | event: {pid, :call, {:telemetry, function, [name, measurements, metadata | rest]}}
        }

      [handlers, [namespace | _] = name, measurements, metadata]
      when function == :do_execute and namespace in [:ash, :ash_onetime] and is_map(measurements) ->
        measurements = measurement_clocks(measurements, names)

        %{
          event
          | event: {pid, :call, {:telemetry, function, [handlers, name, measurements, metadata]}}
        }

      _ ->
        event
    end
  end

  # Cache.Ets.put/3's sole deadline slot. Its expected value is the captured
  # monotonic-second read plus retain_until minus the captured UTC read. An
  # unrelated replacement value is not a clock, even in this slot.
  def event(
        %{
          event:
            {pid, :call,
             {:ets, :insert,
              [AshOnetime.Cache.Ets, {key, %AshOnetime.Cache.Entry{} = entry, expiry}]}}
        } = event,
        names
      ) do
    expiry = Map.get(Map.get(names, :cache_deadlines, %{}), {entry.digest, expiry}, expiry)
    %{event | event: {pid, :call, {:ets, :insert, [AshOnetime.Cache.Ets, {key, entry, expiry}]}}}
  end

  # PostgreSQL messages, never arbitrary binaries, are compared as protocol messages.
  # Iodata segmentation and TCP packet batching are transport framing, not exits.
  def event(
        %{
          event:
            {pid, :call,
             {:erlang, :start_timer,
              [absolute, pool, {reference, holder, caller, timeout}, [abs: true]]}}
        } = event,
        names
      )
      when is_integer(absolute) and is_integer(timeout) and is_pid(pool) and
             is_reference(reference) and is_reference(holder) and is_pid(caller) do
    deadline =
      if MapSet.member?(Map.get(names, :clock_values, MapSet.new()), absolute - timeout),
        do: :pool_deadline,
        else: absolute

    %{
      event
      | event:
          {pid, :call,
           {:erlang, :start_timer,
            [deadline, pool, {reference, holder, caller, timeout}, [abs: true]]}}
    }
  end

  def event(event, _names), do: event

  # OTP inet_drv TCP_REQ_RECV (42 + prim_inet's control magic) returns
  # INET_REP_OK followed by its two-byte asynchronous receive identity. Trust that
  # identity only when this trace contains both the precise driver request and a
  # matching successful inet_async receive. Status, other control replies, and the
  # number of replies remain compared; this never equates arbitrary short binaries.
  defp tcp_receive_replies(events) do
    requests =
      for %{event: {port, :receive, {pid, {:control, {0x03F1A32A, <<_::32, _::32>>}}}}} <-
            events,
          into: MapSet.new(),
          do: {port, pid}

    for %{event: {pid, :receive, {:inet_async, port, ref, {:ok, bytes}}}} <- events,
        is_binary(bytes) and MapSet.member?(requests, {port, pid}),
        into: MapSet.new(),
        do: {port, pid, ref}
  end

  defp measurement_clocks(measurements, names) do
    Map.new(measurements, fn {key, value} ->
      normalized =
        if key in @measurement_clocks and is_number(value),
          do: clock(value, names, :instrumentation_clock),
          else: value

      {key, normalized}
    end)
  end

  def events(events, names) do
    {output, pending} =
      Enum.map_reduce(events, %{}, fn observed, pending ->
        case incoming(observed) do
          nil -> {[event(observed, names) |> transport(names)], pending}
          {key, bytes, build} -> incoming_messages(key, bytes, build, observed, names, pending)
        end
      end)

    # An incomplete or non-PostgreSQL stream is never discarded.
    unfinished = for {_key, {_bytes, original}} <- pending, do: original
    List.flatten(output) ++ List.flatten(unfinished)
  end

  # Postgrex can switch from active TCP delivery to passive inet_async reads,
  # and either delivery can split a PostgreSQL message. These are two transports
  # of the same stream. Reassemble only these socket-data operations, preserving
  # every complete protocol message, its bytes and its multiplicity.
  defp incoming(%{event: {pid, :receive, {:tcp, port, bytes}}} = event)
       when is_pid(pid) and is_port(port) and is_binary(bytes),
       do:
         {{:receive, pid, port}, bytes,
          fn packet -> %{event | event: {pid, :receive, {:tcp, port, packet}}} end}

  defp incoming(%{event: {pid, :receive, {:inet_async, port, _ref, {:ok, bytes}}}} = event)
       when is_pid(pid) and is_port(port) and is_binary(bytes),
       do:
         {{:receive, pid, port}, bytes,
          fn packet -> %{event | event: {pid, :receive, {:tcp, port, packet}}} end}

  defp incoming(%{event: {port, :send, {:tcp, port, bytes}, pid}} = event)
       when is_pid(pid) and is_port(port) and is_binary(bytes),
       do:
         {{:send, pid, port}, bytes,
          fn packet -> %{event | event: {port, :send, {:tcp, port, packet}, pid}} end}

  defp incoming(%{event: {port, :send, {:inet_async, port, _ref, {:ok, bytes}}, pid}} = event)
       when is_pid(pid) and is_port(port) and is_binary(bytes),
       do:
         {{:send, pid, port}, bytes,
          fn packet -> %{event | event: {port, :send, {:tcp, port, packet}, pid}} end}

  defp incoming(_event), do: nil

  defp incoming_messages(key, bytes, build, observed, names, pending) do
    {{buffer, originals}, pending} = Map.pop(pending, key, {<<>>, []})
    bytes = buffer <> bytes
    originals = originals ++ [observed]

    case stream_messages(bytes, names, []) do
      {:ok, packets, <<>>} ->
        {Enum.map(packets, &build.({:postgresql_message, &1})), pending}

      {:ok, packets, rest} ->
        {Enum.map(packets, &build.({:postgresql_message, &1})),
         Map.put(pending, key, {rest, originals})}

      :not_postgresql ->
        {originals, pending}
    end
  end

  defp stream_messages(<<>>, _names, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp stream_messages(bytes, _names, acc) when byte_size(bytes) < 5,
    do: {:ok, Enum.reverse(acc), bytes}

  defp stream_messages(<<tag, size::32, rest::binary>> = bytes, names, acc)
       when tag in @postgresql_tags and size >= 4 do
    payload_size = size - 4

    if byte_size(rest) < payload_size do
      {:ok, Enum.reverse(acc), bytes}
    else
      <<payload::binary-size(^payload_size), tail::binary>> = rest
      stream_messages(tail, names, [{tag, message_payload(tag, payload, names)} | acc])
    end
  end

  defp stream_messages(_bytes, _names, _acc), do: :not_postgresql

  # Splode.filter_stacktrace/2 inspects each module for its configured prefix
  # filters (Splode.matches_filter?/2). Extra package entry frames therefore add
  # module-identity lookups. Compare each complete filter input, including every
  # frame argument. Only one exact Inspect.Opts read per identity-only inspect
  # call is excluded; altered arguments, extra reads, and other inspect calls stay.
  def formatting(events) do
    {events, _} = Enum.map_reduce(events, %{}, &formatting_event/2)
    events
  end

  defp formatting_event(
         %{event: {pid, :call, {Splode, :filter_stacktrace, _args}}} = event,
         active
       ) do
    state = Map.get(active, pid, %{depth: 0, lookup?: false})

    {%{event | kind: :event, class: :e15},
     Map.put(active, pid, %{state | depth: state.depth + 1})}
  end

  defp formatting_event(
         %{event: {pid, :return_from, {Splode, :filter_stacktrace, 2}, _}} = event,
         active
       ) do
    state = Map.fetch!(active, pid)
    {event, Map.put(active, pid, %{state | depth: state.depth - 1, lookup?: false})}
  end

  defp formatting_event(%{event: {pid, :call, {Kernel, :inspect, args}}} = event, active) do
    state = Map.get(active, pid, %{depth: 0, lookup?: false})

    identity? =
      case args do
        [module, []] when is_atom(module) -> state.depth > 0 and path_frame?(module)
        _ -> false
      end

    event = if identity?, do: event, else: %{event | kind: :event, class: :e15}
    {event, Map.put(active, pid, %{state | lookup?: identity?})}
  end

  defp formatting_event(
         %{event: {pid, tag, {Kernel, :inspect, 2}, _}} = event,
         active
       )
       when tag in [:return_from, :exception_from] do
    state = Map.get(active, pid, %{depth: 0, lookup?: false})
    {event, Map.put(active, pid, %{state | lookup?: false})}
  end

  defp formatting_event(
         %{event: {pid, :call, {:persistent_term, :get, [{Inspect.Opts, :inspect_fun}, default]}}} =
           event,
         active
       ) do
    state = Map.get(active, pid, %{depth: 0, lookup?: false})

    if state.lookup? and default == (&Inspect.inspect/2),
      do: {%{event | class: :pure}, Map.put(active, pid, %{state | lookup?: false})},
      else: {event, active}
  end

  defp formatting_event(event, active), do: {event, active}

  # OTP prim_inet:send/3 prefixes the driver's iodata with a length and an encoded
  # monitor reference (OTP-28.5/29.1.2 erts/preloaded/src/prim_inet.erl, send/3,4).
  # TCP batching and that exact reference header are transport identities. Each
  # PostgreSQL message remains a separate counted event with its semantic payload.
  defp transport(
         %{event: {port, :send, {port, {:control, <<1, ref::16>>}}, pid}} = event,
         names
       ) do
    if MapSet.member?(Map.get(names, :tcp_receive_replies, MapSet.new()), {port, pid, ref}) do
      [%{event | event: {port, :send, {port, {:control, {1, :tcp_receive_identity}}}, pid}}]
    else
      [event]
    end
  end

  defp transport(%{event: {pid, :call, {m, :port_command, [port, data, opts]}}} = event, names)
       when m in [:erlang, :erts_internal] and is_port(port),
       do:
         packets(data, names, fn packet ->
           %{event | event: {pid, :call, {m, :port_command, [port, packet, opts]}}}
         end)

  defp transport(
         %{event: {pid, :call, {:prim_inet, :send, [port, data, opts, ref]}}} = event,
         names
       )
       when is_port(port) and is_reference(ref),
       do:
         packets(data, names, fn packet ->
           %{event | event: {pid, :call, {:prim_inet, :send, [port, packet, opts, ref]}}}
         end)

  defp transport(%{event: {port, :receive, {pid, {:command, data}}}} = event, names)
       when is_port(port) and is_pid(pid),
       do:
         packets(data, names, fn packet ->
           %{event | event: {port, :receive, {pid, {:command, packet}}}}
         end)

  defp transport(%{event: {pid, :receive, {:tcp, port, data}}} = event, names)
       when is_pid(pid) and is_port(port),
       do:
         packets(data, names, fn packet ->
           %{event | event: {pid, :receive, {:tcp, port, packet}}}
         end)

  defp transport(%{event: {pid, :receive, {:inet_async, port, ref, {:ok, data}}}} = event, names)
       when is_pid(pid) and is_port(port),
       do:
         packets(data, names, fn packet ->
           %{event | event: {pid, :receive, {:inet_async, port, ref, {:ok, packet}}}}
         end)

  defp transport(%{event: {port, :send, {:tcp, port, data}, pid}} = event, names)
       when is_port(port) and is_pid(pid),
       do:
         packets(data, names, fn packet ->
           %{event | event: {port, :send, {:tcp, port, packet}, pid}}
         end)

  defp transport(
         %{event: {port, :send, {:inet_async, port, ref, {:ok, data}}, pid}} = event,
         names
       )
       when is_port(port) and is_pid(pid),
       do:
         packets(data, names, fn packet ->
           %{event | event: {port, :send, {:inet_async, port, ref, {:ok, packet}}, pid}}
         end)

  # A provisional busy-socket acknowledgement has no result; the subsequent
  # four-tuple contains the status and is retained, including repetitions.
  defp transport(%{event: {pid, :receive, {:inet_reply, port, ref}}}, _names)
       when is_pid(pid) and is_port(port) and is_reference(ref), do: []

  defp transport(%{event: {port, :send, {:inet_reply, port, ref}, pid}}, _names)
       when is_port(port) and is_pid(pid) and is_reference(ref), do: []

  defp transport(event, _names), do: [event]

  defp packets(data, names, build) do
    case wire(data, names) do
      {:postgresql_messages, messages} -> Enum.map(messages, &build.({:postgresql_message, &1}))
      other -> [build.(other)]
    end
  end

  defp wire(data, names) do
    bytes = data |> IO.iodata_to_binary() |> driver_payload()

    case messages(bytes, names, []) do
      {:ok, [_ | _] = messages} -> {:postgresql_messages, messages}
      _ -> data
    end
  rescue
    ArgumentError -> data
  end

  defp driver_payload(<<size::16, reference::binary-size(size), bytes::binary>> = original) do
    case :erlang.binary_to_term(reference, [:safe, :used]) do
      {ref, ^size} when is_reference(ref) -> bytes
      _ -> original
    end
  rescue
    ArgumentError -> original
  end

  defp driver_payload(other), do: other

  defp messages(<<>>, _names, acc), do: {:ok, Enum.reverse(acc)}

  defp messages(<<tag, size::32, rest::binary>>, names, acc)
       when tag in @postgresql_tags and size >= 4 and byte_size(rest) >= size - 4 do
    payload_size = size - 4
    <<payload::binary-size(^payload_size), tail::binary>> = rest
    messages(tail, names, [{tag, message_payload(tag, payload, names)} | acc])
  end

  defp messages(_bytes, _names, _acc), do: :not_postgresql

  # Only RowDescription's table OID is a per-installation catalog identity. Column
  # names, attribute numbers, data types, modifiers and formats remain exact.
  defp message_payload(?T, <<count::16, fields::binary>> = payload, names) do
    case row_fields(fields, count, names, []) do
      {:ok, fields} -> {:row_description, fields}
      :error -> wire_bytes(payload, names)
    end
  end

  defp message_payload(_tag, payload, names), do: wire_bytes(payload, names)
  defp row_fields(<<>>, 0, _names, acc), do: {:ok, Enum.reverse(acc)}

  defp row_fields(bytes, count, names, acc) when count > 0 do
    with {size, 1} <- :binary.match(bytes, <<0>>),
         <<name::binary-size(^size), 0, table::32, column::16, type::32, width::signed-16,
           modifier::signed-32, format::16, rest::binary>> <- bytes do
      relation = Map.get(Map.get(names, :postgresql_relations, %{}), table, table)

      row_fields(rest, count - 1, names, [
        {binary(name, names), relation, column, type, width, modifier, format} | acc
      ])
    else
      _ -> :error
    end
  end

  defp row_fields(_, _, _, _), do: :error

  defp wire_bytes(bytes, names) do
    substitutions =
      for {from, to} <- names,
          is_binary(from) and byte_size(from) >= 8,
          do: {from, to}

    case substitutions do
      [] ->
        bytes

      _ ->
        matches = :binary.matches(bytes, Enum.map(substitutions, &elem(&1, 0)))

        {parts, used} =
          Enum.reduce(matches, {[], 0}, &wire_part(&1, &2, bytes, names))

        Enum.reverse([binary_part(bytes, used, byte_size(bytes) - used) | parts])
    end
  end

  defp wire_part({offset, _size}, {parts, used}, _bytes, _names) when offset < used,
    do: {parts, used}

  defp wire_part({offset, size}, {parts, used}, bytes, names) do
    prefix = binary_part(bytes, used, offset - used)
    original = binary_part(bytes, offset, size)
    {[{:identity, Map.fetch!(names, original)}, prefix | parts], offset + size}
  end

  def payloads(names, delta) do
    {utc, seconds} = Map.get(names, :cache_clock_reads, {[], []})

    deadlines =
      for {_table, sides} <- delta,
          row <- sides.added ++ sides.removed,
          %DateTime{} = until <- [row["retain_until"]],
          is_binary(row["response_digest"]),
          now <- utc,
          mono <- seconds,
          into: %{},
          do: {{row["response_digest"], mono + DateTime.diff(until, now, :second)}, until}

    stamps =
      for {_table, sides} <- delta,
          row <- sides.added ++ sides.removed,
          column <- ["admitted_at", "retain_until", "inserted_at"],
          %DateTime{} = at <- [row[column]],
          do: at

    names =
      case stamps do
        [] ->
          names

        _ ->
          base = stamps |> Enum.map(&DateTime.to_unix(&1, :microsecond)) |> Enum.min()

          Enum.reduce(stamps, names, fn at, acc ->
            micros = DateTime.to_unix(at, :microsecond)
            token = {:database_clock, micros - base}
            pg = micros - 946_684_800_000_000
            acc |> Map.put(at, token) |> Map.put(<<pg::signed-64>>, token)
          end)
      end

    names =
      Map.put(
        names,
        :cache_deadlines,
        Map.new(deadlines, fn {key, until} -> {key, {:cache_deadline, term(until, names)}} end)
      )

    for {_table, sides} <- delta,
        row <- sides.added ++ sides.removed,
        payload = row["encoded_response"],
        is_binary(payload),
        reduce: names do
      acc ->
        canonical = binary(payload, names)

        acc
        |> Map.put(payload, canonical)
        |> Map.put(:crypto.hash(:sha256, payload), {:payload_digest, canonical})
    end
  end
end
