defmodule AshOnetime.Test.ExitBoundary.PermittedTrace do
  @moduledoc false
  alias AshOnetime.Delivery
  alias AshOnetime.Delivery.Envelope
  alias AshOnetime.Test.ExitBoundary.{HostCall, Producer, Registry, Returns}

  @delivery_functions [deliver: 2, armed_call: 4, armed: 4, dispatch: 2,
    normalize: 3, finish: 2, open: 7, protection: 1, subject_type?: 2,
    route: 2, bulk?: 1, built_for_action?: 1, task_route?: 2, cell: 1,
    put_reference: 2, put_cell: 1, put_private: 3, key: 1, reference: 1,
    claim: 3, claim_entry: 6, produce: 4, seal: 2, seal_to_entry: 2,
    ordered_values: 2, deliverable: 1, complete: 2, complete_current: 2,
    complete_entry: 3, lost: 0, invalid: 0, refused: 0, in_transaction: 0,
    requires_call: 0, lost_class: 0]
  @envelope_functions [max_value_bytes: 0, bound: 1, context: 4, seal: 3,
    encrypt: 3, open: 5, split: 2, public_key: 1, agree: 2, derive: 4,
    hmac: 2, decrypt: 5, additional_data: 1, decode: 3]
  @frames (Enum.map(@delivery_functions, fn {f, a} -> {Delivery, f, a} end) ++
    Enum.map(@envelope_functions, fn {f, a} -> {Envelope, f, a} end) ++
    [{AshOnetime, :deliver, 1}, {AshOnetime, :deliver, 2},
     {Delivery, :"-bulk?/1-fun-0-", 2}, {Delivery, :"-armed/4-fun-0-", 7},
     {Delivery, :"-ordered_values/2-fun-0-", 3}, {Delivery, :"-produce/4-fun-0-", 1}, {Delivery, :"-claim/3-fun-0-", 1}, {Delivery, :"-seal/2-fun-0-", 1},
     {Envelope, :"-context/4-fun-0-", 1}, {Envelope, :"-seal/3-fun-0-", 1},
     {Envelope, :"-seal/3-fun-1-", 1}])

  def frame?({m, f, a}), do: {m, f, a} in @frames
  def frames, do: @frames

  # This matcher binds only returns. Calls are checked against values already bound
  # by their source, and all nonmatching events remain in the compared observation.
  def match(side, indexed) do
    state = %{host_owned: HostCall.indexes(indexed.events), bound: Map.get(side, :fixture_bindings, %{}), claimed: MapSet.new(), errors: [], pending: %{},
      source_returns: %{}, dictionary_sources: %{}, route_pending: %{}, path_references: %{}, path_subject: nil, crypto: [], host_calls: 0, references: %{}, last_state: :undefined, returned?: false,
      allowed: Registry.trace(side.row), segments: []}
    state = Enum.reduce(indexed.events, state, fn e, s ->
      s = segment(e, s, side.row)
      step(e, s, side)
    end)
    state = finish(state, side)
    program_errors = AshOnetime.Test.ExitBoundary.TraceProgram.check(side, indexed.events, state.bound) ++
      AshOnetime.Test.ExitBoundary.FrameBindings.check(side, indexed.events, state.bound)
    state = %{state | errors: Enum.reverse(program_errors) ++ state.errors}
    %{state | errors: Enum.reverse(state.errors)}
  end

  defp step(%{event: {pid, :call, {m, f, args}}} = e, state, side) do
    mfa = {m, f, length(args)}
    state = if m == :erlang and f == :put and length(args) == 2,
      do: put_in(state.dictionary_sources[{pid, hd(args)}], Enum.at(args, 1)), else: state
    cond do
      path_reference?(e, state) -> path_reference(e, state, side)
      MapSet.member?(state.host_owned, e.index) -> claim(state, e)
      m in [AshOnetime.Change, AshOnetime.GenericAction] and f in [:produce, :complete_delivery] ->
        path_frame(state, e, mfa, args, side) |> claim(e) |> pending(pid, mfa, args)
      m == AshOnetime.Store and f in [:claim, :claim_committed, :complete, :complete_external] -> pending(state, pid, mfa, args)
      m == AshOnetime.Store and f == :committed_completion ->
        state |> check_frame(e, mfa, args, side) |> pending(pid, mfa, args)
      entry_protection?(e) -> reference(state, e, side.protection_reference, :entry_protection)
      entry_route_read?(e) -> entry_route(state, e, side)
      m == Producer and f == :produce ->
        state |> valid(e, :host_multiplicity, state.host_calls == 0) |> Map.update!(:host_calls, &(&1 + 1)) |> claim(e)
        |> pending(pid, mfa, args)
      frame?(mfa) ->
        state |> check_frame(e, mfa, args, side) |> claim(e) |> pending(pid, mfa, args)
      m == :erlang and f in [:put, :get, :erase] -> dictionary(e, state, f, args, side)
      m == Process and f == :get -> dictionary_get(e, state, args)
      m == :crypto and delivery_crypto?(e) -> crypto(e, state, mfa, args, side)
      delivery_origin?(e, mfa, args) ->
        state |> claim(e) |> pending(pid, mfa, args)
      true -> state
    end
  end

  defp step(%{event: {pid, tag, mfa, value}} = e, state, side)
       when tag in [:return_from, :exception_from] do
    {args, pending} = case Map.get(state.pending, {pid, mfa}, []) do
      [args | rest] -> {args, Map.put(state.pending, {pid, mfa}, rest)}
      [] -> {nil, state.pending}
    end
    state = %{state | pending: pending, source_returns: Map.put(state.source_returns, mfa, value)}
    cond do
      path_reference?(e, state) -> path_reference(e, state, side)
      MapSet.member?(state.host_owned, e.index) -> claim(state, e)
      elem(mfa, 0) in [AshOnetime.Change, AshOnetime.GenericAction] and elem(mfa, 1) in [:produce, :complete_delivery] ->
        path_return(state, e, mfa, value) |> claim(e)
      entry_protection?(e) -> reference(state, e, side.protection_reference, :entry_protection)
      entry_route_read?(e) -> entry_route(state, e, side)
      mfa == {AshOnetime.Test.ExitBoundary.External, :execute, 3} and tag == :return_from ->
        case value do
          {:ok, _result, values} -> bind(state, :values, values)
          _ -> state
        end
      not is_nil(args) ->
        state = returned(state, e, mfa, args, value, side)
        if elem(mfa, 0) == AshOnetime.Store, do: state, else: claim(state, e)
      true -> state
    end
  end
  defp step(e, state, _side), do: if(MapSet.member?(state.host_owned, e.index), do: claim(state, e), else: state)

  defp path_reference?(e, state) do
    Map.has_key?(state.path_references, e.pid) or
      (e.mfa in [{AshOnetime.Admission, :state, 1}, {AshOnetime.Admission, :trusted_context, 1}] and
       Enum.any?(e.stack, fn {module, function, _} ->
         module in [AshOnetime.Change, AshOnetime.GenericAction] and function in [:produce, :complete_delivery]
       end))
  end
  defp path_reference(%{event: {pid, :call, {m, f, args}}} = e, state, side) do
    if Map.has_key?(state.path_references, pid) do
      advance_path_reference(state, e)
    else
      expected_args = if f == :state, do: [state.path_subject],
        else: [AshOnetime.Test.ExitBoundary.Hooks.environment(if(side.row.type == :action, do: {:before_action, 0}, else: {:around_action, 0}), Map.put(side, :bound, state.bound))
          |> Enum.zip(side.hooks[if(side.row.type == :action, do: {:before_action, 0}, else: {:around_action, 0})].sources)
          |> Enum.find_value(fn {value, source} -> if source == :context, do: {:found, value} end) |> elem(1)]
      state = exact(state, e, :path_source_arguments, args, expected_args)
      events = AshOnetime.Test.ExitBoundary.References.capture(fn -> apply(m, f, expected_args) end, e.mfa)
      state = put_in(state.path_references[pid], %{root: e.mfa, events: events, position: 0})
      advance_path_reference(state, e)
    end
  end
  defp path_reference(e, state, _side), do: advance_path_reference(state, e)
  defp advance_path_reference(state, e) do
    frame = state.path_references[e.pid]
    expected = case Enum.at(frame.events, frame.position) do nil -> :undeclared_path_event; reference -> Tuple.delete_at(reference.event, 0) end
    state = exact(state, e, :path_reference, Tuple.delete_at(e.event, 0), expected) |> claim(e)
    if elem(e.event, 1) in [:return_from, :exception_from] and e.mfa == frame.root do
      state = exact(state, e, :path_reference_length, frame.position + 1, length(frame.events))
      %{state | path_references: Map.delete(state.path_references, e.pid)}
    else
      put_in(state.path_references[e.pid], %{frame | position: frame.position + 1})
    end
  end
  defp path_frame(state, e, {module, :produce, 4}, [subject, delivery, protection, context], side) do
    expected_subject = Map.get(state.source_returns, {module, :reserve, 4}, :missing_reservation_return)
    state = exact(state, e, :produce_source_subject, subject, expected_subject)
      |> exact(e, :produce_handle, delivery, handle(state.bound, side))
      |> exact(e, :produce_protection, protection, side.protection)
    slot = if side.row.type == :action, do: {:before_action, 0}, else: {:around_action, 0}
    expected_context = Enum.zip(side.hooks[slot].sources,
      AshOnetime.Test.ExitBoundary.Hooks.environment(slot, Map.put(side, :bound, state.bound)))
      |> Enum.find_value(fn {source, value} -> if source == :context, do: {:found, value} end) |> elem(1)
    state |> exact(e, :produce_context, context, expected_context) |> Map.put(:path_subject, expected_subject)
  end
  defp path_frame(state, e, {AshOnetime.Change, :complete_delivery, 2}, [completed, delivery], side) do
    expected = Map.get(state.source_returns, {AshOnetime.Change, :complete, 2}, :missing_completion_return)
    source = case expected do {:ok, _, subject, _} -> subject; _ -> nil end
    state |> exact(e, :completion_source, completed, expected)
      |> exact(e, :completion_handle, delivery, handle(state.bound, side)) |> Map.put(:path_subject, source)
  end
  defp path_frame(state, e, {AshOnetime.GenericAction, :complete_delivery, 2}, [completed, subject], _side) do
    expected = Map.get(state.source_returns, {AshOnetime.GenericAction, :complete, 2}, :missing_completion_return)
    state |> exact(e, :completion_source, completed, expected) |> Map.put(:path_subject, subject)
  end
  defp path_return(state, e, {_, :produce, 4}, value),
    do: exact(state, e, :produce_return, value, Map.get(state.source_returns, {Delivery, :produce, 4}, :ok))
  defp path_return(state, e, {module, :complete_delivery, 2}, value),
    do: exact(state, e, :complete_delivery_return, value, Map.get(state.source_returns, {module, :complete, 2}))

  defp entry_protection?(e), do: e.mfa == {AshOnetime.Resource.Info, :protection, 2} and
    {Delivery, :protection, 1} in e.stack or
    ({AshOnetime.Resource.Info, :protection, 2} in e.stack and {Delivery, :protection, 1} in e.stack)
  defp entry_route_read?(e), do: {Delivery, :route, 2} in e.stack and
    e.mfa in [{:ets, :lookup_element, 3}, {:erlang, :get, 1}, {Process, :get, 1}, {Process, :get, 2}]
  defp reference(state, e, events, label) do
    payload = Tuple.delete_at(e.event, 0)
    key = {elem(payload, 0), e.mfa}
    count = Map.get(state.references, {label, key}, 0)
    expected = Enum.find_value(events, :undeclared_reference_event, fn
      {^key, ^count, value} -> value
      _ -> nil
    end)
    state |> exact(e, label, payload, expected) |> claim(e)
      |> put_in([:references, {label, key}], count + 1)
  end
  defp entry_route(state, %{event: {_, :call, {:ets, :lookup_element, [Ecto.Repo.Registry, repo, 4]}}} = e, side) do
    exact(state, e, :entry_repo, repo, side.historical.repo) |> claim(e)
  end
  defp entry_route(state, %{event: {_, :return_from, {:ets, :lookup_element, 3}, value}} = e, side),
    do: exact(state, e, :entry_repo_metadata, value, side.historical.repo_metadata) |> claim(e)
  defp entry_route(state, %{event: {pid, :call, {module, :get, [key | defaults]}}} = e, side)
       when module in [:erlang, Process] do
    repo_key = {AshOnetime.Test.Repo, :dynamic_repo}
    sql_key = {Ecto.Adapters.SQL, side.historical.repo_metadata.pid}
    expected_defaults = case {module, length(defaults), key} do
      {Process, 1, ^repo_key} -> [AshOnetime.Test.Repo]
      {Process, 1, ^sql_key} -> [nil]
      {_, 0, _} -> []
      _ -> :undeclared_get
    end
    expected = cond do
      key == repo_key -> side.historical.repo
      key == sql_key -> Map.get(state.dictionary_sources, {pid, key}, if(module == Process, do: nil, else: :undefined))
      true -> :undeclared_route_key
    end
    state |> exact(e, :entry_dictionary_key, key in [repo_key, sql_key], true)
      |> exact(e, :entry_dictionary_default, defaults, expected_defaults)
      |> put_in([:route_pending, {pid, e.mfa}], expected) |> claim(e)
  end
  defp entry_route(state, %{event: {pid, :return_from, mfa, value}} = e, _side) do
    exact(state, e, :entry_dictionary_read, value, Map.fetch!(state.route_pending, {pid, mfa})) |> claim(e)
  end

  defp pending(state, pid, mfa, args), do: Map.update!(state, :pending, &Map.update(&1, {pid, mfa}, [args], fn stack -> [args | stack] end))
  defp claim(state, e), do: %{state | claimed: MapSet.put(state.claimed, e.index)}
  defp bind(state, name, value), do: put_in(state.bound[name], value)

  defp returned(state, _e, {AshOnetime.Store, function, _}, [_target | _], %AshOnetime.Store.Result{claim: %AshOnetime.Store.Claim{} = claim}, _side)
       when function in [:claim, :claim_committed], do: bind(state, :c_admit, claim)
  defp returned(state, e, {AshOnetime.Store, function, _}, [target | _], %AshOnetime.Store.Result{status: :complete, claim: claim}, _side)
       when function in [:complete, :complete_external] do
    state = state |> bind(:target, target) |> bind(:c_complete, claim)
      |> bind(:completion, {target, state.bound[:c_admit]})
    fields = [:id, :strategy, :logical_partition, :operation_hash, :scope_hash, :key_hash]
    exact(state, e, :completion_locator, Map.take(claim, fields), Map.take(Map.get(state.bound, :c_admit, %{}), fields))
  end
  defp returned(state, e, {Delivery, :put_cell, 1}, [_], {subject, cell}, _side) do
    state |> bind(:cell, cell) |> bind(:built_subject, subject) |> exact(e, :cell_copy,
      get_in(subject.context, [:private, :ash_onetime_delivery_cell]), cell)
  end
  defp returned(state, e, {:crypto, :generate_key, 2}, [:ecdh, :x25519], {pk, sk} = pair, _side) do
    state = exact(state, e, :keypair_copy, pair, state.bound[:nif_keypair])
    if Map.has_key?(state.bound, :pk),
      do: state |> bind(:epk, pk) |> bind(:esk, sk),
      else: state |> bind(:pk, pk) |> bind(:sk, sk)
  end
  defp returned(state, e, {:crypto, :strong_rand_bytes, 1}, [16], value, _side) do
    state = exact(state, e, :entropy_copy, value, state.bound[:nif_entropy])
    key = if Map.has_key?(state.bound, :ref), do: :inv, else: :ref
    state = bind(state, key, value)
    state = if key == :ref, do: bind(state, :key, {Delivery, :crypto.hash(:sha256, value)}), else: state
    state |> valid(e, :origin_width, is_binary(value) and byte_size(value) == 16)
  end
  defp returned(state, _e, {:erlang, :make_ref, 0}, [], value, _side), do: bind(state, :cell, value)
  defp returned(state, e, {Envelope, :context, 4}, args, value, _side) do
    state |> exact(e, :o2a_context, value, Registry.compute(:o2a_context, args)) |> bind(:context, value)
  end
  defp returned(state, e, {Envelope, :seal, 3}, _, {:ok, envelope}, _side) do
    b = state.bound
    expected = if b[:epk] && b[:ct] && b[:tag], do: <<1, b.epk::binary, b.tag::binary, b.ct::binary>>
    state |> exact(e, :crypto_envelope, envelope, expected) |> bind(:envelope, envelope)
  end
  defp returned(state, e, {:crypto, :compute_key, 4}, args, value, _side) do
    state |> exact(e, :crypto_shared, value, apply(:crypto, :compute_key, args)) |> bind(:shared, value)
  end
  defp returned(state, e, {:crypto, :mac, 4}, args, value, _side),
    do: exact(state, e, :crypto_hmac, value, apply(:crypto, :mac, args))
  defp returned(state, _e, {:crypto, :crypto_one_time_aead, 7}, [_, _, _, _, _, _, true], {ct, tag}, _side),
    do: state |> bind(:ct, ct) |> bind(:tag, tag)
  defp returned(state, e, {:crypto, :crypto_one_time_aead, 7}, [_, _, _, _, _, _, false], value, _side),
    do: exact(state, e, :crypto_plaintext, value, plaintext(state.bound[:values]))
  defp returned(state, _e, {:crypto, :evp_generate_key_nif, 2}, [:x25519, :undefined], pair, _side),
    do: bind(state, :nif_keypair, pair)
  defp returned(state, _e, {:crypto, :strong_rand_bytes_nif, 1}, [16], bytes, _side),
    do: bind(state, :nif_entropy, bytes)
  defp returned(state, e, {:crypto, :generate_key, 3}, _, pair, _side),
    do: exact(state, e, :keypair_copy, pair, state.bound[:nif_keypair])
  defp returned(state, e, {Process, :get, _}, [_key | _], value, _side),
    do: exact(state, e, :dictionary_read, value, state.last_state)
  defp returned(state, e, {:erlang, :get, 1}, [_key], value, _side),
    do: exact(state, e, :dictionary_read, value, state.last_state)
  defp returned(state, e, {:erlang, :put, 2}, [_key, _value], value, _side),
    do: exact(state, e, :dictionary_previous, value, state.bound[:previous_state])
  defp returned(state, e, {:erlang, :erase, 1}, [_key], value, _side),
    do: exact(state, e, :dictionary_erased, value, state.last_state)
  defp returned(state, _e, {Producer, :produce, 2}, _, {:ok, values}, _side),
    do: bind(state, :values, values)
  defp returned(state, e, {AshOnetime, :deliver, 2}, _, result, side) do
    state = %{state | returned?: true}
    validate_delivery(state, e, result, side)
  end
  defp returned(state, _e, _, _, _, _side), do: state

  defp check_frame(state, e, {Delivery, :key, 1}, [ref], _side),
    do: exact(state, e, :key_reference, ref, state.bound[:ref])
  defp check_frame(state, e, {Envelope, :context, 4}, args, side),
    do: exact(state, e, :envelope_binding, args,
      [state.bound[:ref], state.bound[:inv], side.resource, side.row.action])
  defp check_frame(state, e, {Envelope, :seal, 3}, [pk, values, context], _side) do
    state |> exact(e, :recipient, pk, state.bound[:pk])
      |> exact(e, :ordered_values, values, ordered(state.bound[:values]))
      |> exact(e, :context, context, state.bound[:context])
  end
  defp check_frame(state, e, {Envelope, :open, 5}, args, _side),
    do: exact(state, e, :open_arguments, args,
      [state.bound[:envelope], state.bound[:sk], state.bound[:pk], 2, state.bound[:context]])
  defp check_frame(state, e, {Delivery, :claim, 3}, [_subject, cell, names], side),
    do: state |> exact(e, :claim_cell, cell, state.bound[:cell])
      |> exact(e, :claim_names, names, side.protection.executing_only)
  defp check_frame(state, e, {Delivery, :normalize, 3}, [raw, type, opts], side) do
    state |> exact(e, :return_type, type, side.row.type)
      |> exact(e, :return_options, opts, Map.get(side.row, :opts, []))
      |> bind(:raw_return, raw)
      |> bind(:delivered_return, Registry.compute(:return, [raw, type, opts, Returns.delivery(side.row, side.values)]))
  end
  defp check_frame(state, e, {AshOnetime.Store, :committed_completion, 2}, args, _side),
    do: exact(state, e, :committed_readback_binding, args, [state.bound[:target], state.bound[:c_admit]])
  defp check_frame(state, e, {Delivery, :seal, 2}, [handle, values], side) do
    state |> exact(e, :host_values_copy, values, state.bound[:values])
      |> exact(e, :claim_handle, handle, handle(state.bound, side))
  end
  defp check_frame(state, _e, _mfa, _args, _side), do: state

  defp dictionary_get(e, state, [key | _] = args) do
    if key === state.bound[:key] and key != nil and dictionary_site?(e, :get),
      do: state |> claim(e) |> pending(e.pid, {Process, :get, length(args)}, args), else: state
  end

  defp dictionary_site?(e, function) do
    frame = Enum.find(e.stack, fn {module, _, _} -> module == Delivery end)
    case function do
      :get -> frame in [{Delivery, :claim, 3}, {Delivery, :seal_to_entry, 2},
        {Delivery, :complete_entry, 3}, {Delivery, :complete_current, 2}, {Delivery, :open, 7}]
      :put -> frame in [{Delivery, :armed_call, 4}, {Delivery, :claim_entry, 6},
        {Delivery, :seal_to_entry, 2}, {Delivery, :complete_entry, 3}]
      :erase -> frame == {Delivery, :armed_call, 4}
    end
  end

  defp dictionary(e, state, function, [key | rest], side) do
    if key == state.bound[:key] and not is_nil(key) and dictionary_site?(e, function) do
      state = claim(state, e) |> pending(e.pid, {:erlang, function, length(rest) + 1}, [key | rest])
      case {function, rest} do
        {:put, [value]} ->
          b = state.bound
          expected = case Enum.find(e.stack, fn {m, _, _} -> m == Delivery end) do
            {Delivery, :armed_call, 4} -> {:armed, e.pid, side.resource, side.row.action, b[:cell], b[:pk]}
            {Delivery, :claim_entry, 6} -> {:claimed, b[:inv], b[:pk]}
            {Delivery, :seal_to_entry, 2} -> {:sealed, b[:inv], b[:envelope]}
            {Delivery, :complete_entry, 3} ->
              outcome = case side.row.branch do
                branch when branch in [:replay, :finalize_replay] -> :replayed
                branch when branch in [:recovered, :unknown] -> :recovered
                _ -> :executed
              end
              if outcome == :executed, do: {:done, b[:inv], outcome, b[:envelope], b[:completion]},
                else: {:done, b[:inv], outcome, nil, nil}
          end
          state = exact(state, e, :dictionary_binding, value, expected)
          state = bind(state, :previous_state, state.last_state || :undefined)
          %{state | last_state: value}
        {:erase, []} -> bind(state, :erased, true)
        {:get, []} -> state
        _ -> state
      end
    else
      state
    end
  end
  defp dictionary(_e, state, _, _, _), do: state

  defp crypto(e, state, mfa, args, _side) do
    b = state.bound
    state = claim(state, e) |> pending(e.pid, mfa, args)
    state = case {mfa, args} do
      {{:crypto, :generate_key, 2}, [:ecdh, :x25519]} -> state
      {{:crypto, function, 1}, [16]} when function in [:strong_rand_bytes, :strong_rand_bytes_nif] -> state
      {{:crypto, :ensure_int_as_bin, 1}, [value]} ->
        valid(state, e, :crypto_integer_input, value in [:undefined, b[:pk], b[:sk], b[:epk], b[:esk]])
      {{:crypto, :evp_generate_key_nif, 2}, [:x25519, :undefined]} -> state
      {{:crypto, :max_bytes, 0}, []} -> state
      {{:crypto, :hash, 2}, [:sha256, ref]} -> exact(state, e, :key_hash_input, ref, b[:ref])
      {{:crypto, :hash, 4}, [:sha256, ref, size, 20_000]} ->
        state |> exact(e, :key_hash_input, ref, b[:ref]) |> exact(e, :key_hash_size, size, 16)
      {{:crypto, :hash_nif, 2}, [:sha256, ref]} -> exact(state, e, :key_hash_input, ref, b[:ref])
      {{:crypto, :generate_key, 3}, [kind, :x25519, :undefined]} when kind in [:ecdh, :eddh] ->
        valid(state, e, :ephemeral_generation,
          {:crypto, :generate_key, 2} in e.stack)
      {{:crypto, :generate_key, _}, _} -> valid(state, e, :ephemeral_generation, false)
      {{:crypto, :compute_key, 4}, [kind, pk, sk, :x25519]} when kind in [:ecdh, :eddh] ->
        valid(state, e, :key_agreement,
          {pk, sk} in [{b[:pk], b[:esk]}, {b[:epk], b[:sk]}])
      {{:crypto, :evp_compute_key_nif, 3}, [:x25519, pk, sk]} ->
        valid(state, e, :key_agreement, {pk, sk} in [{b[:pk], b[:esk]}, {b[:epk], b[:sk]}])
      {{:crypto, function, 4}, [:hmac, :sha256, key, data]} when function in [:mac, :mac_nif] ->
        expected = hmac_inputs(b)
        valid(state, e, :hmac_transfer, {key, data} in expected)
      {{:crypto, :alias, 2}, [:sha256, key]} ->
        valid(state, e, :hmac_alias, Enum.any?(hmac_inputs(b), fn {expected, _} -> expected == key end))
      {{:crypto, :alias, 2}, [:aes_256_gcm, key]} -> exact(state, e, :aead_alias, key, elem(derived_key(b), 0))
      {{:crypto, function, 7}, [:aes_256_gcm, key, nonce, input, aad, tag, encrypt?]}
          when function in [:crypto_one_time_aead, :aead_cipher_nif] ->
        {expected_key, expected_nonce} = derived_key(b)
        state |> exact(e, :aead_key, key, expected_key)
          |> exact(e, :aead_nonce, nonce, expected_nonce)
          |> exact(e, :aead_aad, aad, <<1, b.context::binary>>)
          |> exact(e, :aead_input, input, if(encrypt?, do: plaintext(b[:values]), else: b[:ct]))
          |> exact(e, :aead_tag, tag, if(encrypt?, do: 16, else: b[:tag]))
      _ -> valid(state, e, :undeclared_crypto_call, false)
    end
    %{state | crypto: [mfa | state.crypto]}
  end

  defp hmac_inputs(%{epk: epk, pk: pk, shared: shared, context: context}) do
    salt = epk <> pk
    prk = :crypto.mac(:hmac, :sha256, salt, shared)
    info = "ash_onetime delivery v1" <> context
    first = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    [{salt, shared}, {prk, info <> <<1>>}, {prk, first <> info <> <<2>>}]
  end
  defp hmac_inputs(_), do: []
  defp derived_key(b) do
    case hmac_inputs(b) do
      [_, {prk, first_input}, {prk, second_input}] ->
        first = :crypto.mac(:hmac, :sha256, prk, first_input)
        second = :crypto.mac(:hmac, :sha256, prk, second_input)
        <<key::binary-size(32), nonce::binary-size(12), _::binary>> = first <> second
        {key, nonce}
      _ -> {nil, nil}
    end
  end
  defp ordered(%{short: short, long: long}), do: [short, long]
  defp ordered(_), do: []
  defp plaintext(values), do: for(value <- ordered(values), into: <<>>, do: <<byte_size(value)::32, value::binary>>)

  def handle(b, side), do: %{key: b[:key], ref: b[:ref], inv: b[:inv],
    resource: side.resource, action: side.row.action, names: side.protection.executing_only}

  defp validate_delivery(state, e, result, side) do
    state = if Map.has_key?(state.bound, :delivered_return),
      do: exact(state, e, :return, result, state.bound.delivered_return), else: state
    case result do
      {:ok, _, %Delivery{outcome: :executed, values: values}} -> exact(state, e, :delivery_values, values, side.values)
      {:ok, _, %Delivery{outcome: outcome, values: values}} when outcome in [:replayed, :recovered] -> exact(state, e, :delivery_values, values, %{})
      {:error, _} -> state
      _ -> state
    end
  end
  defp segment(e, state, row) do
    marker = case e.event do
      {_, :call, {AshOnetime, :deliver, [_subject, _opts]}} -> :entry
      {_, :call, {Delivery, :put_cell, [_]}} -> :cell
      {_, :call, {Delivery, :armed_call, _}} -> :arm
      {_, :call, {Delivery, :put_reference, _}} -> :context
      {_, :call, {Delivery, :claim, _}} -> if row.branch == :direct, do: :claim_refusal, else: :claim
      {_, :call, {Producer, :produce, _}} -> if row.branch == :producer_failure, do: :produce_failure, else: :local
      {_, :call, {module, :execute, _}} when module == AshOnetime.Test.ExitBoundary.External -> :external
      {_, :call, {Delivery, :seal, _}} -> if row.branch == :producer_failure, do: nil, else: :seal
      {_, :call, {Delivery, :complete_entry, _}} -> case row.branch do
        :replay -> :replay
        branch when branch in [:recovered, :unknown] -> :recovered
        :finalize_replay -> :finalize_replay
        _ -> :complete
      end
      {_, :call, {Delivery, :open, _}} -> if row.branch in [:replay, :recovered, :unknown, :finalize_replay], do: :open_empty, else: :open
      {_, :call, {:erlang, :erase, [key]}} -> if key == state.bound[:key] and key != nil, do: :erase
      {_, :exception_from, {Delivery, :armed, 4}, _} -> :reraise
      {_, :return_from, {AshOnetime, :deliver, 2}, _} -> cond do
        row.branch == :transaction -> :refusal_return
        row.branch in [:failure, :producer_failure, :consumer_failure, :interrupted] -> :error_return
        true -> :return
      end
      {_, :return_from, {AshOnetime.Test.ExitBoundary.Root, :invoke, 2}, _} -> if row.branch == :direct, do: :error_return
      {_, :exception_from, {AshOnetime.Test.ExitBoundary.Root, :invoke, 2}, _} -> :error_return
      {_, :return_from, {AshOnetime.Test.ExitBoundary.ResponseClassifier, :classify, 2}, _} -> if row.fault in [:classify_reject, :classify_rollback], do: :failure
      {_, :return_from, {AshOnetime.Test.ExitBoundary.Codec, :encode, 3}, _} -> if row.fault == :codec_encode, do: :failure
      {_, :return_from, {AshOnetime.Test.ExitBoundary.Codec, :decode, 4}, _} -> if row.fault == :codec_decode, do: :failure
      {_, :return_from, {AshOnetime.Test.ExitBoundary.Hold, :reference, 2}, _} -> if row.fault == :hold_invalid, do: :failure
      {_, tag, {AshOnetime.Store, function, _}, _} when tag in [:return_from, :exception_from] and function in [:complete, :complete_external] -> if row.fault == :store_completion, do: :failure
      _ -> nil
    end
    if marker, do: %{state | segments: state.segments ++ [{marker, e.index}]}, else: state
  end

  defp finish(state, side) do
    state = exact(state, %{index: :terminal, role: :caller}, :permitted_segment_order,
      Enum.map(state.segments, &elem(&1, 0)), state.allowed)
    expected = if not side.row.external? and side.row.branch not in [:transaction, :direct, :replay, :recovered] and side.row.fault != :codec_decode, do: 1, else: 0
    exact(state, %{index: :terminal, role: :caller}, :host_multiplicity, state.host_calls, expected)
  end
  defp delivery_crypto?(e) do
    Enum.any?(e.stack, fn
      {Envelope, _, _} -> true
      {Delivery, :key, 1} -> true
      {Delivery, function, _} when function in [:armed_call, :claim_entry] ->
        Enum.all?(Enum.take_while(e.stack, fn {module, _, _} -> module != Delivery end),
          fn {module, _, _} -> module == :crypto end)
      _ -> false
    end)
  end
  # A nested UUID generator is a common origin, even when Ash runs beneath
  # deliver/2. Only the immediate constructor can bind these delivery origins.
  defp delivery_origin?(%{stack: [{Delivery, :put_cell, 1} | _]}, {:erlang, :make_ref, 0}, []), do: true
  defp delivery_origin?(%{stack: [{Delivery, :armed_call, 4} | _]}, {:crypto, :generate_key, 2}, [:ecdh, :x25519]), do: true
  defp delivery_origin?(%{stack: [{Delivery, function, _} | _]}, {:crypto, :strong_rand_bytes, 1}, [16])
       when function in [:armed_call, :claim_entry], do: true
  defp delivery_origin?(_, _, _), do: false
  defp exact(state, e, rule, actual, expected), do: valid(state, e, rule, actual === expected, expected, actual)
  defp valid(state, e, rule, ok?, expected \\ true, actual \\ false)
  defp valid(state, _e, _rule, true, _expected, _actual), do: state
  defp valid(state, e, rule, false, expected, actual),
    do: %{state | errors: [%{rule: rule, role: e.role, index: e.index,
      at: Map.take(e, [:mfa, :role, :index, :phase, :stack]),
      expected: expected, actual: actual} | state.errors]}
end
