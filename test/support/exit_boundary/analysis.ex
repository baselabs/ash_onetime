defmodule AshOnetime.Test.ExitBoundary.Analysis do
  @moduledoc false

  # §2.7.8 rules 3 and 4 over a drained snapshot:
  #
  # - `annotate/2` classifies every event (a total function: an event no class claims is
  #   `:unclaimed`) and gives it its frame stack and its region of the caller's run.
  # - `unclaimed/1` lists the events no class claims.
  # - `emitted/3` is the X2 multiset: every claimed, non-pure event, with semantic
  #   values and multiplicities intact. Normalization names the fixture identities,
  #   instrumentation clocks and transport framing that differ between the twins;
  #   the declared events of the executing-only run are removed before comparison.
  # - `hits/3` is the search of every event for the canaries or the envelopes, outside the
  #   places each is allowed.
  #
  # Failures name event descriptors (class, module, function, arity or trace tag) and
  # counts only, never a term, so a value that leaked is never printed.

  alias AshOnetime.Test.ExitBoundary.{Classifier, Normalization, Root}

  @delivery AshOnetime.Delivery
  @envelope AshOnetime.Delivery.Envelope
  @store AshOnetime.Store

  @windows [
    {@delivery, :claim, 3},
    {@delivery, :produce, 4},
    {@delivery, :seal, 2},
    {@delivery, :complete, 2},
    {@delivery, :complete_current, 2},
    {@delivery, :key, 1},
    {@delivery, :open, 7},
    {@delivery, :protection, 1},
    {@delivery, :route, 2},
    {@delivery, :cell, 1}
  ]

  @deliver [{AshOnetime, :deliver, 1}, {AshOnetime, :deliver, 2}, {@delivery, :deliver, 2}]
  @readback {@store, :committed_completion, 2}
  @boundary {Root, :invoke, 2}

  # `deliver/2`'s entry owner and the call it runs: an event whose innermost frame is the
  # owner, not the call, happened after the call ended (the entry's erase and, when the
  # call raised, exited or threw, raising the same term again).
  @owner {@delivery, :armed_call, 4}
  @armed {@delivery, :armed, 4}
  # The frames whose return carries the delivery to the caller.
  @delivering [@owner, @armed | @deliver]

  @doc """
  The frame patterns the collector traces with `exception_trace`. `host` are the modules
  that produce values (the producer or the external effect); `callbacks` the package
  callback modules (codec, response classifier, hold), E24.
  """
  def frames(host, callbacks) do
    @windows ++
      [{@envelope, :_, :_}, @readback, @boundary, @owner, @armed | @deliver] ++
      Enum.map(host ++ callbacks, &{&1, :_, :_}) ++ Normalization.frames()
  end

  defmodule Event do
    @moduledoc false
    # `kind`: `:frame_call`, `:frame_return`, `:ledger_return` or `:event`.
    # `stack`: the open frames of this pid, innermost first, before this event.
    # `region`: the caller's place in the run (`:before`, `:pre_arm`, `:body`, `:after`);
    # every other process is `:body`. A port's event takes the stack and the region of
    # the process that drove it (the sender of a command, the recipient of the port's
    # message); one no recorded process drove, on a port the run did not open, is
    # `:outside` (another process's traffic: a pool's idle ping), searched but not
    # compared.
    defstruct [:pid, :event, :kind, :class, :mfa, :stack, :region]
  end

  @doc "Annotates every event of the snapshot. `spec` has `:host` and `:callbacks`."
  def annotate(snapshot, spec) do
    frames = frame_set(spec)
    callbacks = MapSet.new(spec.callbacks)
    replies = port_replies(snapshot.events)

    {events, _stacks} =
      Enum.map_reduce(snapshot.events, %{regions: %{snapshot.root => :before}}, fn event, acc ->
        annotate_event(event, acc, frames, callbacks, replies, snapshot)
      end)

    events
  end

  @port_operations [
    port_command: 3,
    port_control: 3,
    port_call: 3,
    port_connect: 2,
    port_close: 1,
    port_info: 1,
    port_info: 2
  ]

  # The references the port operations returned: an operation the port runs later
  # answers with `{reference, result}`, which belongs to the operation (whether the port
  # ran it at once or later depends on the schedulers, not on the run).
  defp port_replies(events) do
    for {_pid, :return_from, {:erts_internal, f, a}, ref} <- events,
        {f, a} in @port_operations and is_reference(ref),
        into: MapSet.new(),
        do: ref
  end

  defp port_reply?({pid, :receive, {ref, _result}}, replies) when is_pid(pid),
    do: MapSet.member?(replies, ref)

  defp port_reply?(_event, _replies), do: false

  defp frame_set(spec) do
    %{
      exact:
        MapSet.new(
          @windows ++ [@readback, @boundary, @owner, @armed | @deliver] ++ Normalization.frames()
        ),
      modules: MapSet.new([@envelope | spec.host ++ spec.callbacks])
    }
  end

  defp frame?(%{exact: exact, modules: modules}, {m, f, a}),
    do: MapSet.member?(exact, {m, f, a}) or MapSet.member?(modules, m)

  defp annotate_event(event, acc, frames, callbacks, replies, snapshot) do
    pid = owner(event)
    {stack, region} = attribution(event, pid, acc, snapshot)

    {kind, mfa, stack_after} = kind(event, pid, frames, stack)

    class =
      if port_reply?(event, replies),
        do: :marker,
        else: class(event, kind, mfa, callbacks, snapshot.loaded_before)

    annotated = %Event{
      pid: pid,
      event: event,
      kind: kind,
      class: class,
      mfa: mfa,
      stack: stack,
      region: region
    }

    acc =
      if is_pid(pid),
        do:
          acc |> Map.put(pid, stack_after) |> advance_region(pid, snapshot.root, kind, mfa, event),
        else: acc

    {annotated, acc}
  end

  # What the event is to the frame stack: a frame's call or return, which pushes or pops
  # it, or an event or a ledger return, which leaves it as it is.
  defp kind({pid, :call, {m, f, args}}, pid, frames, stack) do
    mfa = {m, f, length(args)}

    if frame?(frames, mfa),
      do: {:frame_call, mfa, [mfa | stack]},
      else: {:event, mfa, stack}
  end

  defp kind({pid, tag, mfa, _value}, pid, frames, stack)
       when tag in [:return_from, :exception_from] do
    if frame?(frames, mfa),
      do: {:frame_return, mfa, pop(stack, mfa)},
      else: {:ledger_return, mfa, stack}
  end

  defp kind(_event, _pid, _frames, stack), do: {:event, nil, stack}

  defp owner(event), do: elem(event, 0)

  defp attribution(_event, pid, acc, snapshot) when is_pid(pid),
    do: {Map.get(acc, pid, []), region(acc, pid, snapshot.root)}

  defp attribution(event, port, acc, snapshot) when is_port(port) do
    driver = driver(event)

    cond do
      MapSet.member?(snapshot.pids, driver) ->
        {Map.get(acc, driver, []), region(acc, driver, snapshot.root)}

      MapSet.member?(snapshot.opened, port) ->
        {[], :body}

      true ->
        {[], :outside}
    end
  end

  # The process a port's event names: the sender of what the port received, the
  # recipient of what it sent, its opener, the other end of a link.
  defp driver({_port, :receive, {pid, _message}}) when is_pid(pid), do: pid
  defp driver({_port, :open, pid, _driver}), do: pid

  defp driver({_port, tag, _message, pid}) when tag in [:send, :send_to_non_existing_process],
    do: pid

  defp driver({_port, tag, pid}) when tag in [:link, :unlink, :getting_linked, :getting_unlinked],
    do: pid

  defp driver(_event), do: nil

  defp pop(stack, mfa) do
    case Enum.split_while(stack, &(&1 != mfa)) do
      {_inner, [^mfa | outer]} -> outer
      {_inner, []} -> stack
    end
  end

  defp region(acc, root, root), do: Map.fetch!(acc.regions, root)
  defp region(_acc, _pid, _root), do: :body

  # The caller's regions: before the boundary call; the pre-arm region from the deliver
  # call through the armed put, or through deliver's return when it refuses before arming;
  # the body; after the boundary returned.
  defp advance_region(acc, root, root, kind, mfa, event) do
    next =
      case {acc.regions[root], kind, mfa, event} do
        {:before, :frame_call, @boundary, _} ->
          :body

        {:body, :frame_call, deliver, _} when deliver in @deliver ->
          :pre_arm

        {:pre_arm, :event, {:erlang, :put, 2}, {_, :call, {_, _, [_key, value]}}} ->
          if armed?(value), do: :body, else: :pre_arm

        {:pre_arm, :frame_return, deliver, _} when deliver in @deliver ->
          :body

        {_, :frame_return, @boundary, _} ->
          :after

        {region, _, _, _} ->
          region
      end

    put_in(acc.regions[root], next)
  end

  defp advance_region(acc, _pid, _root, _kind, _mfa, _event), do: acc

  defp armed?({:armed, pid, resource, action, cell, public})
       when is_pid(pid) and is_atom(resource) and is_atom(action) and is_reference(cell) and
              is_binary(public) and byte_size(public) == 32,
       do: true

  defp armed?(_value), do: false

  defp class(_event, :frame_call, {m, _f, _a}, callbacks, _loaded) do
    if MapSet.member?(callbacks, m), do: :e24, else: :marker
  end

  defp class(_event, kind, _mfa, _callbacks, _loaded)
       when kind in [:frame_return, :ledger_return],
       do: :marker

  defp class({_pid, :call, {m, f, args}}, :event, _mfa, _callbacks, loaded) do
    case Classifier.classify_mfa(m, f, length(args)) do
      :unclaimed -> if MapSet.member?(loaded, m), do: :unclaimed, else: :e18
      class -> class
    end
  end

  defp class(event, :event, _mfa, _callbacks, _loaded), do: Classifier.classify(event)

  @doc "The descriptors of the events no class claims."
  def unclaimed(events) do
    for %Event{class: :unclaimed} = e <- events, uniq: true, do: descriptor(e)
  end

  @doc "An event's printable descriptor: its class and its function or trace tag."
  def descriptor(%Event{class: class, mfa: {m, f, a}}), do: {class, m, f, a}
  def descriptor(%Event{class: class, event: event}), do: {class, elem(event, 1)}

  # ---------------------------------------------------------------------------------
  # X2, emitted.

  @doc """
  The X2 multiset of `events`. `side` is `%{host: modules, package?: boolean}`: the host
  modules whose frames are outside X2 on both sides, and whether the package's declared
  events are removed (the executing-only run) or kept (the twin). `rename` maps the run's
  resource atoms to the twin's. Returns `%{item => count}`.
  """
  def emitted(events, side, rename) do
    envelopes = envelopes(events)
    flushed = flushed_monitors(events)

    events
    |> Normalization.formatting()
    |> Enum.reject(&(excluded?(&1, side, envelopes) or flushed?(&1, flushed)))
    |> Normalization.events(rename)
    |> Enum.map(&item(&1, rename))
    |> Enum.frequencies()
  end

  @doc """
  The difference of two X2 multisets, as `{descriptor, run_count, twin_count}`. The
  descriptor is the class, the function or trace tag, and the item's skeleton: its
  structure with every atom that is neither a loaded module nor a protocol tag hidden, so
  an atom made from a value is never printed.
  """
  def emitted_difference(run, twin) do
    keys = MapSet.union(MapSet.new(Map.keys(run)), MapSet.new(Map.keys(twin)))

    for key <- keys, Map.get(run, key, 0) != Map.get(twin, key, 0) do
      {item_descriptor(key), Map.get(run, key, 0), Map.get(twin, key, 0)}
    end
    |> Enum.sort()
  end

  defp item_descriptor({class, descriptor, shape}), do: {class, descriptor, skeleton(shape)}

  @doc """
  For each event of one class and descriptor that the run emits with a shape the twin
  does not, where it parts from the nearest such event of the twin (`divergences/2`):
  the class, the descriptor and the divergences.
  """
  def emitted_divergences(run, twin) do
    run_only = for {item, count} <- run, Map.get(twin, item, 0) < count, do: item
    twin_only = for {item, count} <- twin, Map.get(run, item, 0) < count, do: item

    for {class, descriptor, run_shape} <- run_only,
        candidates =
          for(
            {^class, ^descriptor, twin_shape} <- twin_only,
            do: divergences(run_shape, twin_shape)
          ),
        candidates != [] do
      {class, descriptor, Enum.min_by(candidates, &length/1)}
    end
    |> Enum.group_by(fn {class, descriptor, _} -> {class, descriptor} end)
    |> Enum.map(fn {descriptor, rows} ->
      {descriptor, rows |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq() |> Enum.take(8)}
    end)
    |> Enum.sort()
  end

  @protocol_tags [
    :DOWN,
    :EXIT,
    :"$gen_call",
    :"$gen_cast",
    :io_request,
    :io_reply,
    :inet_reply,
    :inet_async,
    :tcp,
    :tcp_closed,
    :tcp_error,
    :udp,
    :timeout,
    :ok,
    :error,
    :normal,
    :process,
    :command,
    :data,
    :connect,
    :close,
    :closed,
    :bin,
    :num,
    :pid,
    :ref,
    :port,
    :fun,
    :bits,
    :identity,
    :database_clock,
    :postgresql_message,
    :cache_key_input,
    :derived_hash,
    :existing_claim,
    :existing_record,
    :generated_uuid,
    :fixture_record,
    :prepared_query_identity,
    :pool_clock,
    :map,
    nil,
    true,
    false
  ]
  @field_tags [
                Ash.Changeset,
                Ash.ActionInput,
                AshOnetime.Resource.Protection,
                AshOnetime.Response.Contract,
                AshOnetime.Store.Claim,
                AshOnetime.Store.Result,
                AshOnetime.Cache.Entry,
                Ecto.Schema.Metadata,
                Postgrex.Protocol,
                Postgrex.Query,
                Ash.Resource.Actions.Create,
                Ash.Resource.Actions.Update,
                Ash.Resource.Actions.Destroy,
                Ash.Resource.Actions.Action,
                Spark.Dsl.Entity.Meta
              ]
              |> Enum.flat_map(&Map.keys(struct(&1)))
              |> Kernel.++([
                :duration,
                :system_time,
                :monotonic_time,
                :query_time,
                :decode_time,
                :total_time,
                :queue_time,
                :idle_time
              ])
              |> Enum.uniq()

  defp skeleton(atom) when is_atom(atom) do
    if atom in @protocol_tags or atom in @field_tags or :code.is_loaded(atom) != false,
      do: atom,
      else: :atom
  end

  # A stacktrace frame, as its shape keeps it, by its function: the location is the
  # source's, never a value.
  defp skeleton({m, f, _arity, [{:file, _file} | _location]}) when is_atom(m) and is_atom(f),
    do: {skeleton(m), skeleton(f)}

  defp skeleton(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> skeleton() |> List.to_tuple()

  defp skeleton(list) when is_list(list),
    do: list |> proper() |> Enum.reverse() |> Enum.map(&skeleton/1)

  defp skeleton(binary) when is_binary(binary), do: {:bin, byte_size(binary)}
  defp skeleton(number) when is_number(number), do: :num
  defp skeleton(other), do: other

  # A monitor that `demonitor(ref, [:flush])` removes after its process ended: whether the
  # `:DOWN` reached the mailbox before the demonitor (and the flush ran) is the scheduler's
  # race, on either side, and the process's code never sees the message. The flush and the
  # `:DOWN` it removes are outside X2; the searches still cover both.
  defp flushed_monitors(events) do
    for %Event{event: {pid, :call, {:erts_internal, :flush_monitor_messages, [ref | _]}}} <-
          events,
        into: MapSet.new(),
        do: {pid, ref}
  end

  defp flushed?(
         %Event{event: {_pid, :call, {:erts_internal, :flush_monitor_messages, _args}}},
         _flushed
       ),
       do: true

  defp flushed?(%Event{event: {pid, :receive, {:DOWN, ref, _type, _object, _info}}}, flushed),
    do: MapSet.member?(flushed, {pid, ref})

  defp flushed?(_event, _flushed), do: false

  # The caller's own events after the boundary, the pure events, and the frame markers
  # are outside X2; host producer frames are outside it on both sides.
  defp excluded?(%Event{region: region}, _side, _envelopes)
       when region in [:before, :after, :outside],
       do: true

  defp excluded?(%Event{class: class}, _side, _envelopes) when class in [:pure, :marker],
    do: true

  defp excluded?(%Event{} = event, side, envelopes) do
    in_frame?(event, side.host) or (side.package? and declared?(event, envelopes))
  end

  defp in_frame?(%Event{stack: stack}, modules),
    do: Enum.any?(stack, fn {m, _f, _a} -> m in modules end)

  # The package's declared events (§2.7.8 rule 4): the pre-arm region of `deliver/2`
  # (the route checks, the key pair, the reference and its hash); the committed
  # read-back; the crypto calls whose innermost frame is a window (the invocation, the
  # entry key, the seal, the decryption), never one whose innermost frame is `deliver/2`
  # itself, which is the Ash call the twin makes too; the dictionary operations of the
  # state machine under `H(ref)`, in their exact shapes; and the entry owner raising again
  # what the call raised, exited or threw, after erasing the entry (rule 1), whose term is
  # the one the twin's caller receives from Ash.
  defp declared?(%Event{region: :pre_arm}, _envelopes), do: true

  defp declared?(%Event{stack: stack} = event, envelopes) do
    Enum.member?(stack, @readback) or crypto_in_window?(event) or
      state_operation?(event, envelopes) or reraise?(event)
  end

  defp reraise?(%Event{mfa: {:erlang, :raise, 3}, kind: :event, stack: [@owner | _]}),
    do: true

  defp reraise?(_event), do: false

  defp crypto_in_window?(%Event{class: :e9, mfa: {:crypto, _f, _a}, stack: [innermost | _]}),
    do: window?(innermost)

  defp crypto_in_window?(_event), do: false

  defp window?({@envelope, _f, _a}), do: true
  defp window?(mfa), do: mfa in @windows

  defp state_operation?(%Event{event: {_pid, :call, {:erlang, f, args}}}, envelopes) do
    case {f, args} do
      {:put, [key, value]} -> delivery_key?(key) and state?(value, envelopes)
      {:get, [key]} -> delivery_key?(key)
      {:erase, [key]} -> delivery_key?(key)
      _other -> false
    end
  end

  defp state_operation?(_event, _envelopes), do: false

  defp delivery_key?({@delivery, hash}) when is_binary(hash) and byte_size(hash) == 32,
    do: true

  defp delivery_key?(_key), do: false

  defp state?({:armed, _pid, _resource, _action, _cell, _public} = value, _envelopes),
    do: armed?(value)

  defp state?({:claimed, inv, public}, _envelopes), do: bytes?(inv, 16) and bytes?(public, 32)

  defp state?({:sealed, inv, envelope}, envelopes),
    do: bytes?(inv, 16) and envelope in envelopes

  defp state?({:done, inv, :executed, envelope, {_target, %{id: id}}}, envelopes),
    do: bytes?(inv, 16) and envelope in envelopes and is_binary(id)

  defp state?({:done, inv, outcome, nil, nil}, _envelopes),
    do: bytes?(inv, 16) and outcome in [:replayed, :recovered]

  defp state?(_value, _envelopes), do: false

  defp bytes?(value, size), do: is_binary(value) and byte_size(value) == size

  @doc "Every envelope the run produced, captured by the seal's return."
  def envelopes(events) do
    for %Event{event: {_pid, :return_from, {@envelope, :seal, 3}, {:ok, envelope}}} <- events,
        uniq: true,
        do: envelope
  end

  defp item(%Event{class: class, mfa: mfa, event: event}, rename) do
    case event do
      {_pid, :call, {_m, _f, args}} -> {class, rename(mfa, rename), shape(args, rename)}
      {_pid, tag, a} -> {class, tag, shape(a, rename)}
      {_pid, tag, a, b} -> {class, tag, shape({a, b}, rename)}
      {_pid, tag, a, b, c} -> {class, tag, shape({a, b, c}, rename)}
    end
  end

  defp rename({m, f, a}, rename), do: {Map.get(rename, m, m), f, a}

  @doc """
  A term's comparable representation: semantic binary and numeric values, map entries,
  closure environments and frame arguments are retained. Runtime process/reference/port
  identities become tags. Only the differences named in `Normalization` are normalized.
  A stacktrace compares action frames and all entry-path argument lists independently
  of the entry path's frame identities.
  """
  def shape(term, rename) when is_atom(term), do: Map.get(rename, term, term)
  def shape(term, _rename) when is_number(term), do: term
  def shape(term, rename) when is_binary(term), do: Normalization.binary(term, rename)
  def shape(term, _rename) when is_bitstring(term), do: term
  def shape(term, _rename) when is_pid(term), do: :pid
  def shape(term, _rename) when is_reference(term), do: :ref
  def shape(term, _rename) when is_port(term), do: :port

  def shape(term, rename) when is_function(term) do
    info = term |> :erlang.fun_info() |> Map.new() |> Normalization.function(rename)
    {:fun, shape(info.module, rename), info.name, info.arity, shape(info.env, rename)}
  end

  def shape(term, rename) when is_tuple(term),
    do: term |> Normalization.term(rename) |> Tuple.to_list() |> shape(rename) |> List.to_tuple()

  def shape([], _rename), do: []

  def shape([head | tail] = list, rename) do
    if stacktrace?(list) do
      {path, action} =
        Enum.split_with(list, fn {module, _, _, _} -> Normalization.path_frame?(module) end)

      arguments = for {_, _, args, _} <- path, is_list(args), do: shape(args, rename)

      frames =
        Enum.map(action, fn {module, function, args, location} ->
          {shape(module, rename), function, shape(args, rename), shape(location, rename)}
        end)

      {:stacktrace, frames, {:execution_path_arguments, arguments}}
    else
      [shape(head, rename) | elements(tail, rename)]
    end
  end

  def shape(%AshOnetime.Resource.Protection{} = protection, rename) do
    protection
    |> Normalization.term(rename)
    |> Map.delete(:__struct__)
    |> Map.put(:__struct__, AshOnetime.Resource.Protection)
    |> shape_map(rename)
  end

  def shape(%{} = map, rename), do: shape_map(Normalization.term(map, rename), rename)

  defp shape_map(map, rename) do
    map
    |> Map.to_list()
    |> Enum.map(fn {k, v} -> {shape(k, rename), shape(v, rename)} end)
    |> Enum.sort()
    |> then(&{:map, &1})
  end

  @doc """
  Where two shapes first differ, as `{path, run, twin}`: the path of map keys and
  positions, and an outline of each side there (atoms and tags, sizes of compounds), or
  `nil` when they are equal. Diagnostics redact semantic values from the shapes.
  """
  def divergence(run, twin), do: run |> divergences(twin) |> List.first()

  @doc """
  Every place two shapes differ, each as `divergence/2` gives the first. Where two lists
  differ in length, each side is the elements the other lacks, outlined (a stack frame as
  its module and function).
  """
  def divergences(run, twin), do: divergences(run, twin, [])

  defp divergences(same, same, _path), do: []

  defp divergences({:map, run}, {:map, twin}, path) do
    run_keys = Enum.map(run, &elem(&1, 0))
    twin_keys = Enum.map(twin, &elem(&1, 0))

    if run_keys == twin_keys do
      run
      |> Enum.zip(twin)
      |> Enum.flat_map(fn {{key, r}, {_key, t}} -> divergences(r, t, [skeleton(key) | path]) end)
    else
      [
        {Enum.reverse(path), {:keys, Enum.map(run_keys -- twin_keys, &skeleton/1)},
         {:keys, Enum.map(twin_keys -- run_keys, &skeleton/1)}}
      ]
    end
  end

  defp divergences(run, twin, path)
       when is_tuple(run) and is_tuple(twin) and tuple_size(run) == tuple_size(twin) do
    divergences(Tuple.to_list(run), Tuple.to_list(twin), path)
  end

  defp divergences([_ | _] = run, [_ | _] = twin, path) do
    run = proper(run)
    twin = proper(twin)

    if length(run) == length(twin) do
      run
      |> Enum.reverse()
      |> Enum.zip(Enum.reverse(twin))
      |> Enum.with_index()
      |> Enum.flat_map(fn {{r, t}, n} -> divergences(r, t, [n | path]) end)
    else
      [
        {Enum.reverse(path), {:only, Enum.map(run -- twin, &element/1)},
         {:only, Enum.map(twin -- run, &element/1)}}
      ]
    end
  end

  defp divergences(run, twin, path), do: [{Enum.reverse(path), outline(run), outline(twin)}]

  defp element({module, function, _arity, _location}) when is_atom(module) and is_atom(function),
    do: {module, function}

  defp element(other), do: outline(other)

  defp proper_length(list), do: list |> proper() |> length()

  defp outline({:map, entries}), do: {:map, length(entries)}
  defp outline(tuple) when is_tuple(tuple), do: {:tuple, tuple_size(tuple)}
  defp outline(list) when is_list(list), do: {:list, proper_length(list)}
  defp outline(atom) when is_atom(atom), do: skeleton(atom)
  defp outline(binary) when is_binary(binary), do: {:binary, byte_size(binary)}
  defp outline(_other), do: :term

  defp elements([head | tail], rename), do: [shape(head, rename) | elements(tail, rename)]
  defp elements(tail, rename), do: shape(tail, rename)

  @doc """
  The depth a stacktrace is captured to while a run is observed. ExUnit captures 20
  frames; the withheld run passes through more package frames than its twin, so at 20 a
  frame inside the action falls off the end of one side only. Captured to the most the
  runtime keeps, the trace reaches the entry frames on both sides. Their identities
  can differ, but every argument list is still compared.
  """
  def backtrace_depth, do: 64

  # Walked by hand: a list in a term can be improper.
  defp stacktrace?([]), do: true

  defp stacktrace?([{module, function, arity, location} | tail])
       when is_atom(module) and is_atom(function) and (is_integer(arity) or is_list(arity)) and
              is_list(location),
       do: stacktrace?(tail)

  defp stacktrace?(_other), do: false

  # ---------------------------------------------------------------------------------
  # The searches.

  @doc """
  The needles of each secret: raw, Base64 (standard and URL, padded or not), Base16, and
  the secret as an unsigned integer in both byte orders where it fits a 64-bit word (an
  atomic or a counter carries integers only).
  """
  def needles(secrets) do
    Enum.flat_map(secrets, fn secret ->
      [
        secret,
        Base.encode64(secret),
        Base.encode64(secret, padding: false),
        Base.url_encode64(secret),
        Base.url_encode64(secret, padding: false),
        Base.encode16(secret),
        Base.encode16(secret, case: :lower)
      ] ++ integers(secret)
    end)
    |> Enum.uniq()
  end

  defp integers(secret) when byte_size(secret) <= 8,
    do: [:binary.decode_unsigned(secret, :big), :binary.decode_unsigned(secret, :little)]

  defp integers(_secret), do: []

  @doc """
  The descriptors of the events that carry a needle outside the places `allowed?/1`
  accepts.
  """
  def hits(events, needles, allowed?) do
    for event <- events, not allowed?.(event), contains?(searched(event), needles), uniq: true do
      descriptor(event)
    end
  end

  # The return of `deliver/2` to its caller, and of the frames inside it that hand the
  # delivery up, is searched without the delivery's own values: they are the delivery, and
  # a canary anywhere else in the returned term (an error, the record, a notification) is
  # a hit.
  defp searched(%Event{kind: :frame_return, mfa: mfa, event: {pid, :return_from, mfa, value}})
       when mfa in @delivering,
       do: {pid, :return_from, mfa, without_values(value)}

  defp searched(%Event{event: event}), do: event

  defp without_values(%AshOnetime.Delivery{} = delivery), do: %{delivery | values: %{}}

  defp without_values(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&without_values/1) |> List.to_tuple()

  defp without_values(other), do: other

  @doc """
  Where a canary may appear: the windows' and the host producer's own calls and returns
  (never a package callback's: handing a value to a callback is an exit, E24), the pure
  events, the crypto inside the envelope, the host producer's frames, and the caller after
  the boundary returned. The return of `deliver/2` is searched without its delivery's
  values (`hits/3`).
  """
  def canary_allowed?(%Event{} = event, host) do
    (event.kind in [:frame_call, :frame_return] and
       (window_frame?(event) or host_frame?(event.mfa, host))) or
      event.class == :pure or event.region == :after or in_frame?(event, host) or
      (event.class == :e9 and match?([{@envelope, _, _} | _], event.stack))
  end

  @doc """
  Where an envelope may appear: the seal's return (the capture), the windows' own calls
  and returns, and the `{:sealed, …}` and `{:done, …}` puts under `H(ref)`.
  """
  def envelope_allowed?(%Event{} = event, envelopes) do
    (event.kind in [:frame_call, :frame_return] and window_frame?(event)) or
      (envelope_put?(event) and state_operation?(event, envelopes))
  end

  defp envelope_put?(%Event{event: {_pid, :call, {:erlang, :put, [_key, value]}}}),
    do: match?({:sealed, _, _}, value) or match?({:done, _, _, _, _}, value)

  defp envelope_put?(_event), do: false

  defp window_frame?(%Event{mfa: mfa}), do: window?(mfa) or mfa == @boundary

  defp host_frame?({m, _f, _a}, host), do: m in host
  defp host_frame?(_mfa, _host), do: false

  @doc "Whether `term` carries any of `needles`, through binaries, iodata, atoms and closures."
  def contains?(term, needles) when is_binary(term),
    do: Enum.any?(needles, &(is_binary(&1) and :binary.match(term, &1) != :nomatch))

  def contains?(term, needles) when is_integer(term), do: term in needles

  def contains?(term, needles) when is_atom(term),
    do: contains?(Atom.to_string(term), needles)

  def contains?(term, needles) when is_list(term) do
    iodata_contains?(term, needles) or Enum.any?(proper(term), &contains?(&1, needles))
  end

  def contains?(term, needles) when is_tuple(term),
    do: term |> Tuple.to_list() |> contains?(needles)

  def contains?(%{} = term, needles),
    do:
      term
      |> Map.to_list()
      |> Enum.any?(fn {k, v} -> contains?(k, needles) or contains?(v, needles) end)

  def contains?(term, needles) when is_function(term) do
    {:env, env} = :erlang.fun_info(term, :env)
    contains?(env, needles)
  end

  def contains?(term, needles) when is_bitstring(term) do
    size = bit_size(term) - rem(bit_size(term), 8)
    <<bytes::bitstring-size(^size), _::bitstring>> = term
    contains?(bytes, needles)
  end

  def contains?(_term, _needles), do: false

  defp iodata_contains?(list, needles) do
    contains?(IO.iodata_to_binary(list), needles)
  rescue
    ArgumentError -> false
  end

  defp proper(list) do
    case improper_split(list, []) do
      {items, []} -> items
      {items, tail} -> [tail | items]
    end
  end

  defp improper_split([head | tail], acc), do: improper_split(tail, [head | acc])
  defp improper_split(tail, acc), do: {acc, tail}
end
