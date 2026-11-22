defmodule AshOnetime.Test.ExitBoundary.ComparatorMutants do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Comparator
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.Diagnostics
  alias AshOnetime.Test.ExitBoundary.ConnectionNative
  alias AshOnetime.Test.ExitBoundary.ConnectionTls
  import ExUnit.Assertions

  def rules,
    do: [
      :k,
      :inv,
      :completion,
      :crypto,
      :context,
      :o2,
      :backend_copy,
      :o3,
      :o4,
      :order,
      :return,
      :host_multiplicity
    ]

  # Disable K's expression at its source, while still binding that return and
  # checking every later copy. The captured events are passed through unchanged.
  def edits(:k) do
    [
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "    state =\n      if key == :ref, do: bind(state, :key, {Delivery, :crypto.hash(:sha256, value)}), else: state\n\n",
        mutated: ""
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original: "  defp returned(state, _e, {:erlang, :make_ref, 0}, [], value, _side),",
        mutated:
          "  defp returned(state, e, {Delivery, :key, 1}, _, value, _side) do\n    if Map.has_key?(state.bound, :key),\n      do: exact(state, e, :key_copy, value, state.bound.key),\n      else: bind(state, :key, value)\n  end\n\n  defp returned(state, _e, {:erlang, :make_ref, 0}, [], value, _side),"
      },
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original:
          "  defp expected_return({Delivery, :key, 1}, [ref], _, _),\n    do: {:value, {Delivery, :crypto.hash(:sha256, ref)}}\n",
        mutated:
          "  defp expected_return({Delivery, :key, 1}, [_ref], _, b),\n    do: {:value, b.key}\n"
      }
    ]
  end

  # Bind inv at its first claimed put instead of its entropy return. Every
  # later inv copy is still checked against that one captured value.
  def edits(:inv) do
    [
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original: "    state = bind(state, key, value)\n",
        mutated: "    state = if key == :ref, do: bind(state, key, value), else: state\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original: "      case {function, rest} do\n",
        mutated:
          "      state = case {function, rest, Enum.find(e.stack, fn {m, _, _} -> m == Delivery end)} do\n        {:put, [{:claimed, inv, _}], {Delivery, :claim_entry, 6}} -> bind(state, :inv, inv)\n        _ -> state\n      end\n\n      case {function, rest} do\n"
      }
    ]
  end

  # Disable the store-to-completion grounding, bind the first done tuple,
  # and retain every later readback copy and its real reference computation.
  def edits(:completion) do
    [
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original: "          state = exact(state, e, :dictionary_binding, value, expected)\n",
        mutated:
          "          {state, expected} =\n            case {value, expected} do\n              {{:done, inv, :executed, envelope, {target, claim}},\n               {:done, expected_inv, :executed, expected_envelope, _}}\n              when inv === expected_inv and envelope === expected_envelope ->\n                state =\n                  state\n                  |> bind(:target, target)\n                  |> bind(:c_admit, claim)\n                  |> bind(:completion, {target, claim})\n\n                {state, value}\n\n              _ ->\n                {state, expected}\n            end\n\n          state = exact(state, e, :dictionary_binding, value, expected)\n"
      },
      %{
        path: "test/support/exit_boundary/readback.ex",
        original:
          "        prepared = Map.get_lazy(side, :readback_reference, fn -> capture(side, bound) end)\n",
        mutated: "        prepared = capture(side, bound)\n"
      }
    ]
  end

  # Remove the envelope's crypto transfer graph. Keep K, inv, qualified
  # context, later envelope copies and the caller-visible result grounded.
  def edits(:crypto) do
    [
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "  defp crypto(e, state, mfa, args, _side) do\n    state = claim(state, e) |> pending(e.pid, mfa, args)\n    state = crypto_call({mfa, args}, e, state, state.bound)\n    %{state | crypto: [mfa | state.crypto]}\n  end\n\n  defp crypto_call({{:crypto, :generate_key, 2}, [:ecdh, :x25519]}, _e, state, _b) do\n    state\n  end\n\n  defp crypto_call({{:crypto, function, 1}, [16]}, _e, state, _b)\n       when function in [:strong_rand_bytes, :strong_rand_bytes_nif] do\n    state\n  end\n\n  defp crypto_call({{:crypto, :ensure_int_as_bin, 1}, [value]}, e, state, b) do\n    valid(\n      state,\n      e,\n      :crypto_integer_input,\n      value in [:undefined, b[:pk], b[:sk], b[:epk], b[:esk]]\n    )\n  end\n\n  defp crypto_call({{:crypto, :evp_generate_key_nif, 2}, [:x25519, :undefined]}, _e, state, _b) do\n    state\n  end\n\n  defp crypto_call({{:crypto, :max_bytes, 0}, []}, _e, state, _b) do\n    state\n  end\n\n  defp crypto_call({{:crypto, :hash, 2}, [:sha256, ref]}, e, state, b) do\n    exact(state, e, :key_hash_input, ref, b[:ref])\n  end\n\n  defp crypto_call({{:crypto, :hash, 4}, [:sha256, ref, size, 20_000]}, e, state, b) do\n    state |> exact(e, :key_hash_input, ref, b[:ref]) |> exact(e, :key_hash_size, size, 16)\n  end\n\n  defp crypto_call({{:crypto, :hash_nif, 2}, [:sha256, ref]}, e, state, b) do\n    exact(state, e, :key_hash_input, ref, b[:ref])\n  end\n\n  defp crypto_call({{:crypto, :generate_key, 3}, [kind, :x25519, :undefined]}, e, state, _b)\n       when kind in [:ecdh, :eddh] do\n    valid(state, e, :ephemeral_generation, {:crypto, :generate_key, 2} in e.stack)\n  end\n\n  defp crypto_call({{:crypto, :generate_key, _}, _}, e, state, _b) do\n    valid(state, e, :ephemeral_generation, false)\n  end\n\n  defp crypto_call({{:crypto, :compute_key, 4}, [kind, pk, sk, :x25519]}, e, state, b)\n       when kind in [:ecdh, :eddh] do\n    valid(state, e, :key_agreement, {pk, sk} in [{b[:pk], b[:esk]}, {b[:epk], b[:sk]}])\n  end\n\n  defp crypto_call({{:crypto, :evp_compute_key_nif, 3}, [:x25519, pk, sk]}, e, state, b) do\n    valid(state, e, :key_agreement, {pk, sk} in [{b[:pk], b[:esk]}, {b[:epk], b[:sk]}])\n  end\n\n  defp crypto_call({{:crypto, function, 4}, [:hmac, :sha256, key, data]}, e, state, b)\n       when function in [:mac, :mac_nif] do\n    expected = hmac_inputs(b)\n    valid(state, e, :hmac_transfer, {key, data} in expected)\n  end\n\n  defp crypto_call({{:crypto, :alias, 2}, [:sha256, key]}, e, state, b) do\n    valid(\n      state,\n      e,\n      :hmac_alias,\n      Enum.any?(hmac_inputs(b), fn {expected, _} -> expected == key end)\n    )\n  end\n\n  defp crypto_call({{:crypto, :alias, 2}, [:aes_256_gcm, key]}, e, state, b) do\n    exact(state, e, :aead_alias, key, elem(derived_key(b), 0))\n  end\n\n  defp crypto_call(\n         {{:crypto, function, 7}, [:aes_256_gcm, key, nonce, input, aad, tag, encrypt?]},\n         e,\n         state,\n         b\n       )\n       when function in [:crypto_one_time_aead, :aead_cipher_nif] do\n    {expected_key, expected_nonce} = derived_key(b)\n\n    state\n    |> exact(e, :aead_key, key, expected_key)\n    |> exact(e, :aead_nonce, nonce, expected_nonce)\n    |> exact(e, :aead_aad, aad, <<1, b.context::binary>>)\n    |> exact(e, :aead_input, input, if(encrypt?, do: plaintext(b[:values]), else: b[:ct]))\n    |> exact(e, :aead_tag, tag, if(encrypt?, do: 16, else: b[:tag]))\n  end\n\n  defp crypto_call(_, e, state, _b) do\n    valid(state, e, :undeclared_crypto_call, false)\n  end\n\n",
        mutated:
          "  defp crypto(e, state, mfa, args, _side) do\n    if Enum.any?(e.stack, fn {m, _, _} -> m == Envelope end) do\n      state |> claim(e) |> pending(e.pid, mfa, args)\n    else\n      b = state.bound\n      state = claim(state, e) |> pending(e.pid, mfa, args)\n\n      state =\n        case {mfa, args} do\n          {{:crypto, :generate_key, 2}, [:ecdh, :x25519]} ->\n            state\n\n          {{:crypto, function, 1}, [16]}\n          when function in [:strong_rand_bytes, :strong_rand_bytes_nif] ->\n            state\n\n          {{:crypto, :ensure_int_as_bin, 1}, [value]} ->\n            valid(\n              state,\n              e,\n              :crypto_integer_input,\n              value in [:undefined, b[:pk], b[:sk], b[:epk], b[:esk]]\n            )\n\n          {{:crypto, :evp_generate_key_nif, 2}, [:x25519, :undefined]} ->\n            state\n\n          {{:crypto, :max_bytes, 0}, []} ->\n            state\n\n          {{:crypto, :hash, 2}, [:sha256, ref]} ->\n            exact(state, e, :key_hash_input, ref, b[:ref])\n\n          {{:crypto, :hash, 4}, [:sha256, ref, size, 20_000]} ->\n            state |> exact(e, :key_hash_input, ref, b[:ref]) |> exact(e, :key_hash_size, size, 16)\n\n          {{:crypto, :hash_nif, 2}, [:sha256, ref]} ->\n            exact(state, e, :key_hash_input, ref, b[:ref])\n\n          {{:crypto, :generate_key, 3}, [kind, :x25519, :undefined]} when kind in [:ecdh, :eddh] ->\n            valid(state, e, :ephemeral_generation, {:crypto, :generate_key, 2} in e.stack)\n\n          {{:crypto, :generate_key, _}, _} ->\n            valid(state, e, :ephemeral_generation, false)\n\n          {{:crypto, :compute_key, 4}, [kind, pk, sk, :x25519]} when kind in [:ecdh, :eddh] ->\n            valid(state, e, :key_agreement, {pk, sk} in [{b[:pk], b[:esk]}, {b[:epk], b[:sk]}])\n\n          {{:crypto, :evp_compute_key_nif, 3}, [:x25519, pk, sk]} ->\n            valid(state, e, :key_agreement, {pk, sk} in [{b[:pk], b[:esk]}, {b[:epk], b[:sk]}])\n\n          {{:crypto, function, 4}, [:hmac, :sha256, key, data]} when function in [:mac, :mac_nif] ->\n            expected = hmac_inputs(b)\n            valid(state, e, :hmac_transfer, {key, data} in expected)\n\n          {{:crypto, :alias, 2}, [:sha256, key]} ->\n            valid(\n              state,\n              e,\n              :hmac_alias,\n              Enum.any?(hmac_inputs(b), fn {expected, _} -> expected == key end)\n            )\n\n          {{:crypto, :alias, 2}, [:aes_256_gcm, key]} ->\n            exact(state, e, :aead_alias, key, elem(derived_key(b), 0))\n\n          {{:crypto, function, 7}, [:aes_256_gcm, key, nonce, input, aad, tag, encrypt?]}\n          when function in [:crypto_one_time_aead, :aead_cipher_nif] ->\n            {expected_key, expected_nonce} = derived_key(b)\n\n            state\n            |> exact(e, :aead_key, key, expected_key)\n            |> exact(e, :aead_nonce, nonce, expected_nonce)\n            |> exact(e, :aead_aad, aad, <<1, b.context::binary>>)\n            |> exact(e, :aead_input, input, if(encrypt?, do: plaintext(b[:values]), else: b[:ct]))\n            |> exact(e, :aead_tag, tag, if(encrypt?, do: 16, else: b[:tag]))\n\n          _ ->\n            valid(state, e, :undeclared_crypto_call, false)\n        end\n\n      %{state | crypto: [mfa | state.crypto]}\n    end\n  end\n\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "  defp returned(state, e, {:crypto, :generate_key, 2}, [:ecdh, :x25519], {pk, sk} = pair, _side) do\n    state = exact(state, e, :keypair_copy, pair, state.bound[:nif_keypair])\n\n    if Map.has_key?(state.bound, :pk),\n      do: state |> bind(:epk, pk) |> bind(:esk, sk),\n      else: state |> bind(:pk, pk) |> bind(:sk, sk)\n  end\n\n",
        mutated:
          "  defp returned(state, e, {:crypto, :generate_key, 2}, _, {pk, sk}, _side) do\n    if Enum.any?(e.stack, fn {m, _, _} -> m == Envelope end),\n      do: state |> bind(:epk, pk) |> bind(:esk, sk),\n      else: state |> bind(:pk, pk) |> bind(:sk, sk)\n  end\n\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "  defp returned(state, e, {:crypto, :generate_key, 3}, _, {pk, sk} = pair, _side) do\n    state = exact(state, e, :keypair_copy, pair, state.bound[:nif_keypair])\n\n    if Enum.any?(e.stack, fn {m, _, _} -> m == Envelope end),\n      do: state |> bind(:epk, pk) |> bind(:esk, sk),\n      else: state\n  end\n\n",
        mutated:
          "  defp returned(state, e, {:crypto, :generate_key, 3}, _, {pk, sk}, _side) do\n    if Enum.any?(e.stack, fn {m, _, _} -> m == Envelope end),\n      do: state |> bind(:epk, pk) |> bind(:esk, sk),\n      else: state\n  end\n\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "  defp returned(state, e, {Envelope, :seal, 3}, _, {:ok, envelope}, _side) do\n    b = state.bound\n\n    expected =\n      if b[:epk] && b[:ct] && b[:tag], do: <<1, b.epk::binary, b.tag::binary, b.ct::binary>>\n\n    state |> exact(e, :crypto_envelope, envelope, expected) |> bind(:envelope, envelope)\n  end\n\n  defp returned(state, e, {:crypto, :compute_key, 4}, args, value, _side) do\n    state\n    |> exact(e, :crypto_shared, value, apply(:crypto, :compute_key, args))\n    |> bind(:shared, value)\n  end\n\n  defp returned(state, e, {:crypto, :mac, 4}, args, value, _side),\n    do: exact(state, e, :crypto_hmac, value, apply(:crypto, :mac, args))\n\n",
        mutated:
          "  defp returned(state, _e, {Envelope, :seal, 3}, _, {:ok, envelope}, _side),\n    do: bind(state, :envelope, envelope)\n\n  defp returned(state, _e, {:crypto, :compute_key, 4}, _, value, _side),\n    do: bind(state, :shared, value)\n\n  defp returned(state, _e, {:crypto, :mac, 4}, _, _, _side), do: state\n\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "  defp returned(\n         state,\n         e,\n         {:crypto, :crypto_one_time_aead, 7},\n         [_, _, _, _, _, _, false],\n         value,\n         _side\n       ),\n       do: exact(state, e, :crypto_plaintext, value, plaintext(state.bound[:values]))\n\n",
        mutated:
          "  defp returned(state, _e, {:crypto, :crypto_one_time_aead, 7}, [_, _, _, _, _, _, false], _, _side),\n    do: state\n\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "      frame?(mfa) ->\n        state |> check_frame(e, mfa, args, side) |> claim(e) |> pending(pid, mfa, args)\n",
        mutated:
          "      m == Envelope and f != :context ->\n        state |> claim(e) |> pending(pid, mfa, args)\n\n      frame?(mfa) ->\n        state |> check_frame(e, mfa, args, side) |> claim(e) |> pending(pid, mfa, args)\n"
      },
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original:
          "    |> Enum.filter(fn e -> match?({_, :call, _}, e.event) and PermittedTrace.frame?(e.mfa) end)\n",
        mutated:
          "    |> Enum.filter(fn e ->\n      match?({_, :call, _}, e.event) and PermittedTrace.frame?(e.mfa) and\n        (elem(e.mfa, 0) != Envelope or e.mfa == {Envelope, :context, 4})\n    end)\n"
      },
      %{
        path: "test/support/exit_boundary/frame_bindings.ex",
        original:
          "    |> Enum.filter(&(elem(&1.event, 1) == :call and PermittedTrace.frame?(&1.mfa)))\n",
        mutated:
          "    |> Enum.filter(fn e ->\n      elem(e.event, 1) == :call and PermittedTrace.frame?(e.mfa) and\n        (elem(e.mfa, 0) != Envelope or e.mfa == {Envelope, :context, 4})\n    end)\n"
      }
    ]
  end

  # Disable caller-return construction and its copies; the store, trace,
  # crypto transfers and all input arguments are still compared.
  def edits(:return) do
    [
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original: "  alias AshOnetime.Test.ExitBoundary.Returns\n",
        mutated: ""
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "  defp validate_delivery(state, e, result, side) do\n    state =\n      if Map.has_key?(state.bound, :delivered_return),\n        do: exact(state, e, :return, result, state.bound.delivered_return),\n        else: state\n\n    case result do\n      {:ok, _, %Delivery{outcome: :executed, values: values}} ->\n        exact(state, e, :delivery_values, values, side.values)\n\n      {:ok, _, %Delivery{outcome: outcome, values: values}}\n      when outcome in [:replayed, :recovered] ->\n        exact(state, e, :delivery_values, values, %{})\n\n      {:error, _} ->\n        state\n\n      _ ->\n        state\n    end\n  end\n\n",
        mutated: "  defp validate_delivery(state, _e, _result, _side), do: state\n\n"
      },
      %{
        path: "test/support/exit_boundary/comparator.ex",
        original:
          "  defp exact_return(_projected, state) do\n    # Per-side return equality uses the untouched native term. The sequence\n    # comparison separately checks its statement-grounded database projections.\n    source = Enum.fetch!(state.run.run.events, state.at.run_index).event\n\n    value =\n      case source do\n        {_, :return_from, {:erlang, :send, 2}, {:result, _, value, _}} -> value\n        {_, :return_from, _, value} -> value\n        {_, :send, {:result, _, value, _}, _} -> value\n        {_, :call, {:erlang, :send, [_, {:result, _, value, _}]}} -> value\n      end\n\n    expected = state.run.bound.delivered_return\n\n    if value === expected,\n      do: state,\n      else: error(state, :return, [:return, :delivered], value, expected)\n  end\n\n",
        mutated: "  defp exact_return(_value, state), do: state\n\n"
      },
      %{
        path: "test/support/exit_boundary/comparator.ex",
        original:
          "  defp raw_return(state, events) do\n    case Enum.find(\n           events,\n           &match?(%{event: {_, :call, {AshOnetime.Delivery, :normalize, [_, _, _]}}}, &1)\n         ) do\n      nil ->\n        state\n\n      %{event: {_, :call, {_, _, [raw, _, _]}}} = source ->\n        at = %{role: source.role, run_index: source.index, mfa: source.mfa, stack: source.stack}\n        term(raw, state.twin.run.result, %{state | at: at}, [:return, :raw])\n    end\n  end\n\n",
        mutated: "  defp raw_return(state, _events), do: state\n\n"
      },
      %{
        path: "test/support/exit_boundary/comparator.ex",
        original:
          "    state =\n      case Returns.raw(run) do\n        {:found, raw} -> term(raw, twin.run.result, %{state | at: :return}, [:return, :raw])\n        nil -> term(run.run.result, twin.run.result, %{state | at: :return}, [:return])\n      end\n\n",
        mutated: ""
      },
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original:
          "  defp expected_return({Delivery, f, _}, _, _, b) when f in [:armed_call, :armed, :finish],\n    do: bound_return(b, :delivered_return)\n\n  defp expected_return({AshOnetime, :deliver, _}, _, _, b), do: bound_return(b, :delivered_return)\n  defp expected_return({Delivery, :deliver, 2}, _, _, b), do: bound_return(b, :delivered_return)\n  defp expected_return({Delivery, :dispatch, 2}, _, _, b), do: {:value, b[:raw_return]}\n\n  defp expected_return({Delivery, :\"-armed/4-fun-0-\", 7}, _, side, _),\n    do: {:value, {:ok, Returns.delivery(side.row, side.values)}}\n\n  defp expected_return({Delivery, :open, 7}, _, side, _),\n    do: {:value, {:ok, Returns.delivery(side.row, side.values)}}\n\n",
        mutated:
          "  defp expected_return({Delivery, f, _}, _, _, _)\n       when f in [:armed_call, :armed, :finish, :deliver, :dispatch, :open, :\"-armed/4-fun-0-\"],\n       do: :paired\n\n  defp expected_return({AshOnetime, :deliver, _}, _, _, _), do: :paired\n\n"
      },
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original:
          "  defp expected_return({Delivery, :normalize, 3}, [raw, type, opts], _, _) do\n    result = Returns.delivered(raw, type, opts, :delivery)\n\n    {:value,\n     if(match?({:error, _}, result),\n       do: result,\n       else: Tuple.delete_at(result, tuple_size(result) - 1)\n     )}\n  end\n\n",
        mutated: "  defp expected_return({Delivery, :normalize, 3}, _, _, _), do: :paired\n\n"
      },
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original:
          "  defp bound_return(b, key) do\n    case Map.fetch(b, key) do\n      {:ok, value} -> {:value, value}\n      :error -> :paired\n    end\n  end\n\n",
        mutated: ""
      }
    ]
  end

  def edits(:context) do
    [
      %{
        path: "test/support/exit_boundary/comparator.ex",
        original:
          "    state =\n      Enum.reduce(expected, state, fn {key, value}, s ->\n        case Map.fetch(private, key) do\n          {:ok, ^value} -> s\n          :error -> s\n          {:ok, actual} -> error(s, :context, path ++ [:context, :private, key], actual, value)\n        end\n      end)\n\n",
        mutated: ""
      }
    ]
  end

  def edits(:o3) do
    [
      %{
        path: "test/support/exit_boundary/clock_expressions.ex",
        original:
          "          with {:ok, start} <- started(s, e.pid, AshOnetime.ExternalRecovery) do\n            {stop, _} = read(s, e.role, {:monotonic_time, :native})\n            {:ok, stop - start}\n          end\n",
        mutated: "          {:ok, duration}\n"
      }
    ]
  end

  def edits(:host_multiplicity) do
    [
      %{
        path: "test/support/exit_boundary/host_call.ex",
        original:
          "  def indexes(events) do\n    indexes =\n      case Enum.find(events, &(&1.mfa in @calls and elem(&1.event, 1) == :call)) do\n        nil ->\n          []\n\n        start ->\n          stop = Enum.find(events, &host_return?(&1, start))\n          interior(events, start, stop)\n      end\n\n    MapSet.new(indexes)\n  end\n\n  defp host_return?(event, start),\n    do:\n      event.pid == start.pid and event.index > start.index and\n        event.mfa == start.mfa and length(event.stack) == length(start.stack) + 1 and\n        elem(event.event, 1) in [:return_from, :exception_from]\n\n  defp interior(_events, _start, nil), do: []\n\n  defp interior(events, start, stop) do\n    events\n    |> Enum.filter(fn e ->\n      e.pid == start.pid and e.index > start.index and e.index < stop.index and\n        start.mfa in e.stack and not peer?(e)\n    end)\n    |> Enum.map(& &1.index)\n  end\n\n",
        mutated:
          "  def indexes(events) do\n    events\n    |> Enum.filter(&(&1.mfa in @calls and elem(&1.event, 1) == :call))\n    |> Enum.reduce([], fn start, owned ->\n      stop = Enum.find(events, fn event ->\n        event.pid == start.pid and event.index > start.index and event.mfa == start.mfa and\n          length(event.stack) == length(start.stack) + 1 and\n          elem(event.event, 1) in [:return_from, :exception_from]\n      end)\n\n      if stop do\n        for event <- events,\n            event.pid == start.pid and event.index > start.index and event.index < stop.index,\n            start.mfa in event.stack and not peer?(event),\n            reduce: owned do\n          acc -> [event.index | acc]\n        end\n      else\n        owned\n      end\n    end)\n    |> MapSet.new()\n  end\n\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original: "        |> valid(e, :host_multiplicity, state.host_calls == 0)\n",
        mutated: ""
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "  defp segment_marker({_, :call, {Producer, :produce, _}}, _state, row) do\n    if row.branch == :producer_failure, do: :produce_failure, else: :local\n  end\n",
        mutated:
          "  defp segment_marker({_, :call, {Producer, :produce, _}}, state, row) do\n    if state.host_calls == 0 do\n      if row.branch == :producer_failure, do: :produce_failure, else: :local\n    end\n  end\n"
      },
      %{
        path: "test/support/exit_boundary/permitted_trace.ex",
        original:
          "  defp finish(state, side) do\n    state =\n      exact(\n        state,\n        %{index: :terminal, role: :caller},\n        :permitted_segment_order,\n        Enum.map(state.segments, &elem(&1, 0)),\n        state.allowed\n      )\n\n    expected =\n      if not side.row.external? and\n           side.row.branch not in [:transaction, :direct, :replay, :recovered] and\n           side.row.fault != :codec_decode, do: 1, else: 0\n\n    exact(\n      state,\n      %{index: :terminal, role: :caller},\n      :host_multiplicity,\n      state.host_calls,\n      expected\n    )\n  end\n\n",
        mutated:
          "  defp finish(state, _side) do\n    exact(\n      state,\n      %{index: :terminal, role: :caller},\n      :permitted_segment_order,\n      Enum.map(state.segments, &elem(&1, 0)),\n      state.allowed\n    )\n  end\n\n"
      },
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original: "      children = children(events, e)\n",
        mutated:
          "      children = children(events, e) |> Enum.reject(fn child ->\n        e.mfa == {Delivery, :produce, 4} and\n          child.mfa == {AshOnetime.Test.ExitBoundary.Producer, :produce, 2}\n      end)\n"
      },
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original:
          "  defp program({Delivery, :produce, 4}, [_, module, _, _], %{row: %{fault: fault}}, _) do\n    tail = if fault in [:producer_error, :producer_raise], do: :invalid, else: :seal\n\n    List.duplicate({Delivery, :\"-produce/4-fun-0-\", 1}, 2) ++\n      [{module, :produce, 2}, {Delivery, tail, if(tail == :seal, do: 2, else: 0)}]\n  end\n",
        mutated:
          "  defp program({Delivery, :produce, 4}, [_, _module, _, _], %{row: %{fault: fault}}, _) do\n    tail = if fault in [:producer_error, :producer_raise], do: :invalid, else: :seal\n\n    List.duplicate({Delivery, :\"-produce/4-fun-0-\", 1}, 2) ++\n      [{Delivery, tail, if(tail == :seal, do: 2, else: 0)}]\n  end\n"
      }
    ]
  end

  def edits(:o2) do
    [
      %{
        path: "test/support/exit_boundary/comparator.ex",
        original:
          "  defp uuid_identity(a, b, state, path) do\n    normalize = fn\n      <<_::128>> = uuid -> Ecto.UUID.load!(uuid)\n      uuid -> uuid\n    end\n\n    a = normalize.(a)\n    b = normalize.(b)\n\n    exact? =\n      a === b and\n        Map.get(state.pairing.uuid_forward, a, a) === b and\n        Map.get(state.pairing.uuid_reverse, b, b) === a\n\n    if exact? or\n         (Map.fetch(state.pairing.uuid_forward, a) === {:ok, b} and\n            Map.fetch(state.pairing.uuid_reverse, b) === {:ok, a}),\n       do: state,\n       else: error(state, :o2_uuid, path, a, b)\n  end\n\n",
        mutated:
          "  defp uuid_identity(a, b, state, path) do\n    normalize = fn\n      <<_::128>> = uuid -> Ecto.UUID.load!(uuid)\n      uuid -> uuid\n    end\n\n    a = normalize.(a)\n    b = normalize.(b)\n\n    case {a, b} do\n      {nil, nil} -> state\n      _ ->\n        case {Ecto.UUID.dump(a), Ecto.UUID.dump(b)} do\n          {{:ok, _}, {:ok, _}} -> state\n                _ -> error(state, :o2_uuid, path, a, b)\n        end\n    end\n  end\n\n"
      }
    ]
  end

  def edits(:backend_copy) do
    [
      %{
        path: "test/support/exit_boundary/comparator.ex",
        original: "      {{ah, _}, {bh, _}} -> identity(ah, bh, state, path)\n",
        mutated: "      {{_ah, _}, {_bh, _}} -> state\n"
      }
    ]
  end

  def edits(:cross_lease_map) do
    [
      %{
        path: "test/support/exit_boundary/allocation.ex",
        original: "      bind_lease(acc, a, b)\n",
        mutated: "      _ = acc\n      bind_lease(initial, a, b)\n"
      }
    ]
  end

  def edits(:o4) do
    [
      %{
        path: "test/support/exit_boundary/comparator.ex",
        original:
          "  defp column_value(a, b, \"claim_retention_seconds\", state, path) do\n    state = claim_bind_copy(a, :run, state, path)\n    state = claim_bind_copy(b, :twin, state, path)\n    term(a, b, state, path)\n  end\n\n",
        mutated:
          "  defp column_value(a, b, \"claim_retention_seconds\", state, path) do\n    state = claim_bind_copy(a, :run, state, path)\n    state = claim_bind_copy(b, :twin, state, path)\n    state\n  end\n\n"
      }
    ]
  end

  def edits(:order) do
    [
      %{
        path: "test/support/exit_boundary/trace_program.ex",
        original:
          "      order_errors =\n        if expected == :ordinary or actual === expected,\n",
        mutated:
          "      order_errors =\n        if expected == :ordinary or actual === expected or\n             (e.mfa == {Delivery, :open, 7} and\n                expected == [{Process, :get, 1}, {AshOnetime.Store, :committed_completion, 2},\n                  {Envelope, :context, 4}, {Envelope, :open, 5}] and\n                actual == [{Process, :get, 1}, {Envelope, :context, 4},\n                  {AshOnetime.Store, :committed_completion, 2}, {Envelope, :open, 5}]),\n"
      }
    ]
  end

  def edits(:stream_length) do
    [
      %{
        path: "test/support/exit_boundary/connection_reads.ex",
        original:
          "        state = exact(state, read, :receive_length, read.length, expected.length)\n",
        mutated: ""
      }
    ]
  end

  def edits(:stream_timeout) do
    [
      %{
        path: "test/support/exit_boundary/connection_reads.ex",
        original:
          "        state = exact(state, read, :receive_timeout, read.timeout, expected.timeout)\n",
        mutated: ""
      }
    ]
  end

  def edits(:stream_required) do
    [
      %{
        path: "test/support/exit_boundary/connection_reads.ex",
        original:
          "      {:error, reason} ->\n        failure(state, read, :receive_required, reason, :framing_requires_a_read)\n",
        mutated: "      {:error, _reason} ->\n        state\n"
      }
    ]
  end

  def edits(:stream_active_source) do
    [
      %{
        path: "test/support/exit_boundary/native_transport.ex",
        original:
          "        if bound?, do: state, else: failure(state, source, :native_option_source)\n",
        mutated: "        if bound?, do: state, else: state\n"
      }
    ]
  end

  def edits(:stream_passive_source) do
    [
      %{
        path: "test/support/exit_boundary/native_transport.ex",
        original: "            else: failure(state, source, :native_passive_source)\n",
        mutated: "            else: state\n"
      }
    ]
  end

  def edits(:stream_query_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_decoders.ex",
        original: "        state = exact(state, e, :decoder_query_copy, query, origin.query)\n",
        mutated: ""
      }
    ]
  end

  def edits(:stream_replay_source) do
    [
      %{
        path: "test/support/exit_boundary/connection_decoders.ex",
        original:
          "  defp decoder_event(%{event: {pid, :send, {:tcp, _port, _bytes}, pid}} = e, state) do\n    bound? = MapSet.member?(state.replay_sends, e.index)\n    if bound?, do: state, else: failure(state, e, :decoder_replay_source, false)\n  end\n",
        mutated:
          "  defp decoder_event(%{event: {pid, :send, {:tcp, _port, _bytes}, pid}}, state), do: state\n"
      }
    ]
  end

  def edits(:history_status) do
    [
      %{
        path: "test/support/exit_boundary/connection_history.ex",
        original:
          "  @impl true\n  def format_status(status) do\n    Map.new(status, fn\n      {:log, _value} -> {:log, []}\n      {key, _value} when key in [:state, :message, :reason] -> {key, :native_connection_history}\n      entry -> entry\n    end)\n  end\n\n",
        mutated: ""
      }
    ]
  end

  def edits(:stream_tls_binding) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original: "    |> mismatch(:tls_local_endpoint, local_matches?)\n",
        mutated: "    |> mismatch(:tls_local_endpoint, is_boolean(local_matches?))\n"
      }
    ]
  end

  def edits(:stream_tls_workers) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original: "    |> mismatch(:tls_connection_workers, connection_workers?(binding))\n",
        mutated:
          "    |> mismatch(:tls_connection_workers, is_boolean(connection_workers?(binding)))\n"
      }
    ]
  end

  def edits(:stream_state_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_states.ex",
        original:
          "        state = exact(state, source, :state_input_copy, protocol, expected.protocol)\n",
        mutated:
          "        state = exact(state, source, :state_input_copy, expected.protocol, expected.protocol)\n"
      }
    ]
  end

  def edits(:stream_state_holder_update) do
    [
      %{
        path: "test/support/exit_boundary/connection_states.ex",
        original: "        |> exact(source, :state_holder_update, protocol, version.protocol)\n",
        mutated: "        |> exact(source, :state_holder_update, protocol, protocol)\n"
      }
    ]
  end

  def edits(:stream_monitor_source) do
    [
      %{
        path: "test/support/exit_boundary/collector.ex",
        original: "    case Map.fetch(state.monitors, pid) do\n      {:ok, ^ref} ->\n",
        mutated: "    case Map.fetch(state.monitors, pid) do\n      {:ok, _ref} ->\n"
      }
    ]
  end

  def edits(:stream_buffer_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_states.ex",
        original: "    state = exact(state, source, :state_buffer_copy, buffer, expected)\n",
        mutated:
          "    _ = buffer\n    state = exact(state, source, :state_buffer_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_helper_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_states.ex",
        original: "    state = exact(state, source, :state_helper_copy, actual, expected)\n",
        mutated:
          "    _ = actual\n    state = exact(state, source, :state_helper_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_status_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_states.ex",
        original: "      state = exact(state, source, :state_status_copy, actual, expected)\n",
        mutated:
          "      _ = actual\n      state = exact(state, source, :state_status_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_factory_value) do
    [
      %{
        path: "test/support/exit_boundary/connection_states.ex",
        original: "    exact(state, source, :state_status_factory_value, actual, expected)\n",
        mutated:
          "    _ = actual\n    exact(state, source, :state_status_factory_value, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_error_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_states.ex",
        original: "    state = exact(state, source, :state_error_copy, actual, expected)\n",
        mutated:
          "    _ = actual\n    state = exact(state, source, :state_error_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_message_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_states.ex",
        original: "    state = exact(state, source, :state_message_copy, actual, expected)\n",
        mutated:
          "    _ = actual\n    state = exact(state, source, :state_message_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_tls_callback_result) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original: "    tls_exact(state, source, :tls_callback_result, actual, expected)\n",
        mutated:
          "    _ = actual\n    tls_exact(state, source, :tls_callback_result, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_tls_callback_input) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original:
          "    |> tls_exact(source, :tls_callback_input, name, version.name)\n    |> tls_exact(source, :tls_callback_input, actions, [])\n",
        mutated:
          "    |> tls_exact(source, :tls_callback_input, name, name)\n    |> tls_exact(source, :tls_callback_input, actions, actions)\n"
      }
    ]
  end

  def edits(:stream_tls_active_option) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original:
          "        state = tls_exact(state, source, :tls_active_option_copy, mode, expected)\n",
        mutated:
          "        _ = mode\n        state = tls_exact(state, source, :tls_active_option_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_tls_passive_option) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original:
          "      state = tls_exact(state, source, :tls_passive_option, length(options), 1)\n",
        mutated: "      state = tls_exact(state, source, :tls_passive_option, 1, 1)\n"
      },
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original: "      state = tls_exact(state, source, :tls_passive_option, options, [])\n",
        mutated:
          "      _ = options\n      state = tls_exact(state, source, :tls_passive_option, [], [])\n"
      }
    ]
  end

  def edits(:stream_tls_machine_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original: "    state = tls_exact(state, source, :tls_machine_copy, actual, expected)\n",
        mutated:
          "    _ = actual\n    state = tls_exact(state, source, :tls_machine_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_tls_machine_program) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original:
          "    state = tls_exact(state, source, :tls_machine_program_copy, actual, expected)\n",
        mutated:
          "    _ = actual\n    state = tls_exact(state, source, :tls_machine_program_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_tls_state_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original: "    state = tls_exact(state, source, :tls_state_copy, actual, expected)\n",
        mutated:
          "    _ = actual\n    state = tls_exact(state, source, :tls_state_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_tls_worker_state_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original:
          "      state = tls_exact(state, source, :tls_worker_state_copy, actual, expected)\n",
        mutated:
          "      _ = actual\n      state = tls_exact(state, source, :tls_worker_state_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_frame_ownership) do
    [
      %{
        path: "test/support/exit_boundary/wire.ex",
        original: "      if length(phases) == 1 do\n",
        mutated: "      if phases != [] do\n"
      }
    ]
  end

  def edits(:stream_active_mode) do
    [
      %{
        path: "test/support/exit_boundary/native_transport.ex",
        original: "      _ ->\n        failure(state, source, :native_active_mode)\n",
        mutated:
          "      _ -> active_delivery(source, %{mode: true, origin: :unchecked_active_mode}, state)\n"
      }
    ]
  end

  def edits(:stream_tls_record_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original:
          "        state = tls_exact(state, source, :tls_record_copy, records, expected)\n",
        mutated:
          "        _ = records\n        state = tls_exact(state, source, :tls_record_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_tls_forward_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original: "    state = tls_exact(state, source, :tls_forward_copy, actual, expected)\n",
        mutated:
          "    _ = actual\n    state = tls_exact(state, source, :tls_forward_copy, expected, expected)\n"
      }
    ]
  end

  def edits(:stream_tls_reply_copy) do
    [
      %{
        path: "test/support/exit_boundary/connection_tls.ex",
        original:
          "            state = tls_exact(state, source, :tls_reply_copy, arguments, [from, reply])\n",
        mutated:
          "            _ = arguments\n            state = tls_exact(state, source, :tls_reply_copy, [from, reply], [from, reply])\n"
      }
    ]
  end

  def edits(:stream_service_completion) do
    [
      %{
        path: "test/support/exit_boundary/collector.ex",
        original:
          "  defp service_completed?(receipt) do\n    not is_nil(receipt.called) and not is_nil(receipt.returned) and\n      receipt.received_stamp < receipt.called_stamp and\n      receipt.called_stamp < receipt.returned_stamp\n  end\n",
        mutated: "  defp service_completed?(_receipt), do: true\n"
      }
    ]
  end

  def compare(pair, rule), do: with_mutant(rule, fn -> Comparator.compare(pair) end)

  # Change a real TLS sender's private state argument, restoring it inside the
  # actual callee before encryption or transport. Loaded code alone changes;
  # native workers, the socket, server and captured events remain untouched.
  def with_tls_sender_mutant(callback), do: with_tls_sender_mutant(:helper_state, callback)

  def with_tls_sender_mutant(rule, callback) do
    required =
      case rule do
        :helper_state -> 2
        rule when rule in [:reply_copy, :reply_value] -> 7
        rule when rule in [:hibernate_name, :hibernate_actions] -> 5
        _ -> 3
      end

    with_owner_mutant(:tls_sender, required, &tls_sender_form(&1, &2, rule), callback)
  end

  def machine_copy_control(rule, position) do
    with_machine_peer(:assert_machine_copy, [rule, position])
  end

  def with_tls_connection_mutant(rule, callback),
    do: with_owner_mutant(:tls_gen_connection, 1, &receiver_form(&1, &2, rule), callback)

  def with_postgrex_inputs(targets, callback) do
    required = fn sites -> sites > map_size(targets) end

    with_owner_mutant(
      Postgrex.Protocol,
      required,
      &owner_inputs_form(&1, &2, targets),
      callback
    )
  end

  def machine_program_control(targets) do
    with_machine_peer(:assert_machine_program, [targets])
  end

  def machine_reply_control do
    with_machine_peer(:assert_machine_reply, [])
  end

  # OTP's own peer I/O server avoids the parent VM's user_drv/group machines.
  # Only the real fixture's TLS machines run here; no Repo pool is started.
  # The process preflight and both soft-purge checks remain mandatory.
  defp with_machine_peer(function, arguments) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

    try do
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])

      :ok =
        :peer.call(peer, Application, :put_env, [
          :ash_onetime,
          AshOnetime.Test.Repo,
          AshOnetime.Test.Repo.config()
        ])

      :ok = :peer.call(peer, __MODULE__, :prepare_machine_peer, [])
      :peer.call(peer, __MODULE__, function, arguments, 120_000)
    after
      :ok = :peer.stop(peer)
    end
  end

  def prepare_machine_peer do
    :ok = Application.load(:ash_onetime)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ssl)

    :logger.add_primary_filter(:ash_onetime_native_diagnostics, {
      &Diagnostics.logger_filter/2,
      nil
    })
  end

  # Crypto NIF resources in captured SSL state belong to this VM. Keep both
  # the real capture and every assertion here; only the :ok verdict crosses
  # the peer boundary, after exact native and comparator restoration.
  def assert_machine_copy(corruption, position) do
    run =
      machine_mutation(corruption, &ConnectionNative.observe_tls/0)

    assert run.result == []

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    corrupted =
      Enum.filter(events, fn
        %{event: {_, :call, {:gen_statem, :loop_event, arguments}}} ->
          match?({:native_foreign_machine, _}, Enum.at(arguments, position))

        _ ->
          false
      end)

    assert corrupted != []
    native = ConnectionTls.build(%{events: events}, run.tls_binding)

    assert Enum.map(native.errors, & &1.rule) ==
             List.duplicate(:tls_machine_copy, length(corrupted))

    assert Enum.map(native.errors, & &1.index) == Enum.map(corrupted, & &1.index)

    for mutant <- [:stream_tls_worker_state_copy, :stream_tls_machine_copy] do
      checked =
        with_mutant(mutant, fn ->
          ConnectionTls.build(%{events: events}, run.tls_binding)
        end)

      expected =
        if mutant == :stream_tls_machine_copy,
          do: [],
          else: List.duplicate(:tls_machine_copy, length(corrupted))

      assert Enum.map(checked.errors, & &1.rule) == expected
    end

    assert Enum.map(ConnectionTls.build(%{events: events}, run.tls_binding).errors, & &1.index) ==
             Enum.map(corrupted, & &1.index)

    restored = ConnectionNative.observe_tls()

    restored_events =
      restored.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
    IO.puts("CONNECTION_TLS_MACHINE_COPY: owning RED; sole catcher; restore; fresh GREEN")
    :ok
  end

  def assert_machine_program(targets) do
    run = machine_input_mutation(targets, &ConnectionNative.observe_tls/0)
    assert run.result == []

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    corrupted =
      for %{event: {_, :call, {:gen_statem, function, arguments}}} = source <- events,
          positions = Map.get(targets, {function, length(arguments)}, []),
          position <- positions do
        wrapped? = match?({:native_foreign_helper, _}, Enum.at(arguments, position))

        assert wrapped?,
               "native machine input must be wrapped: #{inspect(source.mfa)} argument #{position}"

        {source.index, [2, 2, position]}
      end

    assert corrupted != []

    for {function, arity} <- Map.keys(targets) do
      assert Enum.any?(events, &(&1.mfa == {:gen_statem, function, arity}))
    end

    native = ConnectionTls.build(%{events: events}, run.tls_binding)

    assert Enum.map(native.errors, & &1.rule) ==
             List.duplicate(:tls_machine_program_copy, length(corrupted))

    assert Enum.map(native.errors, &{&1.index, &1.path}) == corrupted

    for mutant <- [
          :stream_tls_machine_program,
          :stream_tls_machine_copy,
          :stream_tls_worker_state_copy
        ] do
      checked =
        with_mutant(mutant, fn ->
          ConnectionTls.build(%{events: events}, run.tls_binding)
        end)

      expected = if mutant == :stream_tls_machine_program, do: [], else: native.errors
      assert checked.errors == expected
    end

    assert ConnectionTls.build(%{events: events}, run.tls_binding).errors == native.errors
    restored = ConnectionNative.observe_tls()

    restored_events =
      restored.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
    IO.puts("CONNECTION_MACHINE_PROGRAM: owning RED; sole catcher; exact restore; fresh GREEN")

    :ok
  end

  def assert_machine_reply do
    targets = %{{:reply, 2} => [0, 1]}

    run =
      with_owner_mutant(:gen_statem, &(&1 > 1), &owner_inputs_form(&1, &2, targets), fn ->
        with_owner_mutant(
          :ssl_gen_statem,
          &(&1 > 1),
          &remote_reply_form/2,
          &ConnectionNative.observe_tls/0
        )
      end)

    assert run.result == []

    events =
      run.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    corrupted =
      for %{event: {_, :call, {:gen_statem, :reply, [from, reply]}}} = source <- events,
          match?({:native_foreign_helper, _}, from) do
        wrapped? = match?({:native_foreign_helper, _}, reply)
        assert wrapped?
        source
      end

    assert corrupted != []

    assert Enum.any?(corrupted, fn source ->
      Enum.any?(source.stack, fn
        {:ssl_gen_statem, _, _} -> true
        _ -> false
      end)
    end)

    coordinates =
      for source <- corrupted, position <- [0, 1], do: {source.index, [2, 2, position]}

    native = ConnectionTls.build(%{events: events}, run.tls_binding)

    assert Enum.map(native.errors, & &1.rule) ==
             List.duplicate(:tls_machine_program_copy, length(coordinates))

    assert Enum.map(native.errors, &{&1.index, &1.path}) == coordinates

    for mutant <- [
          :stream_tls_machine_program,
          :stream_tls_machine_copy,
          :stream_tls_worker_state_copy
        ] do
      checked =
        with_mutant(mutant, fn -> ConnectionTls.build(%{events: events}, run.tls_binding) end)

      expected = if mutant == :stream_tls_machine_program, do: [], else: native.errors
      assert checked.errors == expected
    end

    assert ConnectionTls.build(%{events: events}, run.tls_binding).errors == native.errors
    restored = ConnectionNative.observe_tls()

    restored_events =
      restored.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> Map.put(event, :index, index) end)

    assert ConnectionTls.build(%{events: restored_events}, restored.tls_binding).errors == []
    IO.puts("CONNECTION_MACHINE_REPLY: owning RED; sole catcher; exact restore; fresh GREEN")
    :ok
  end

  defp remote_reply_form({:function, annotation, function, arity, clauses}, sites) do
    {clauses, sites} = remote_reply_calls(clauses, sites)
    {{:function, annotation, function, arity, clauses}, sites}
  end

  defp remote_reply_form(form, sites), do: {form, sites}

  defp remote_reply_calls(
         {:call, location, {:remote, _, {:atom, _, :gen_statem}, {:atom, _, :reply}} = callee,
          arguments},
         sites
       )
       when length(arguments) == 2 do
    {{:call, location, callee, helper_arguments(arguments, [0, 1], location)}, sites + 1}
  end

  defp remote_reply_calls(form, sites) when is_tuple(form) do
    {elements, sites} = form |> Tuple.to_list() |> Enum.map_reduce(sites, &remote_reply_calls/2)
    {List.to_tuple(elements), sites}
  end

  defp remote_reply_calls(form, sites) when is_list(form),
    do: Enum.map_reduce(form, sites, &remote_reply_calls/2)

  defp remote_reply_calls(form, sites), do: {form, sites}

  defp machine_mutation(rule, callback) do
    with_owner_mutant(:gen_statem, 3, &machine_form(&1, &2, rule), callback)
  end

  defp machine_input_mutation(targets, callback) do
    required = fn sites -> sites > map_size(targets) end

    with_owner_mutant(
      :gen_statem,
      required,
      &owner_inputs_form(&1, &2, targets),
      callback
    )
  end

  def with_postgrex_outputs(targets, callback) do
    required = fn sites -> sites > map_size(targets) end

    with_owner_mutant(
      Postgrex.Protocol,
      required,
      &postgrex_outputs_form(&1, &2, targets),
      callback
    )
  end

  defp with_owner_mutant(module, required, transform, callback) do
    loaded? = :code.is_loaded(module) != false
    {:module, ^module} = :code.ensure_loaded(module)

    if module == :gen_statem do
      IO.puts(
        "NATIVE_MACHINE_OWNER_READY: " <>
          Diagnostics.render(%{loaded_before: loaded?, sticky: :code.is_sticky(module)})
      )
    end

    if module == :gen_statem, do: require_machine_idle!()
    {^module, original, path} = :code.get_object_code(module)

    {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(original, [:abstract_code])

    {:ok, ^module, _baseline, original_warnings} =
      :compile.forms(forms, [:binary, :return, :debug_info])

    {forms, sites} = Enum.map_reduce(forms, 0, transform)
    valid? = if is_function(required, 1), do: required.(sites), else: sites == required
    unless valid?, do: raise("native mutant requires every pinned owner site")

    {:ok, ^module, mutant, ^original_warnings} =
      :compile.forms(forms, [:binary, :return, :debug_info])

    sticky? = :code.is_sticky(module)
    if module == :gen_statem, do: require_machine_idle!()

    try do
      if sticky?, do: true = :code.unstick_mod(module)
      {:module, ^module} = :code.load_binary(module, path, mutant)
      Compiled.with_object(module, mutant, callback)
    after
      try do
        true = :code.soft_purge(module)
        {:module, ^module} = :code.load_binary(module, path, original)
        true = :code.soft_purge(module)
        {^module, ^original, ^path} = :code.get_object_code(module)
      after
        if sticky?, do: true = :code.stick_mod(module)
        ^sticky? = :code.is_sticky(module)
      end

      if module == :gen_statem,
        do: IO.puts("NATIVE_MACHINE_OWNER_RESTORED: original bytes and sticky flag")
    end
  end

  defp require_machine_idle! do
    executors =
      for pid <- Process.list(),
          {:current_stacktrace, stack} <- [Process.info(pid, :current_stacktrace)],
          mfa = :proc_lib.translate_initial_call(pid),
          current_machine?(mfa, stack),
          do: %{mfa: mfa}

    for executor <- executors do
      IO.puts("NATIVE_MACHINE_CURRENT_EXECUTOR: " <> Diagnostics.render(executor))
    end

    unless executors == [],
      do: raise("native machine mutation requires no current gen_statem executor")
  end

  defp current_machine?({module, _function, _arity}, stack) do
    attributes = :erlang.get_module_info(module, :attributes)

    behaviours =
      Keyword.get_values(attributes, :behaviour) ++ Keyword.get_values(attributes, :behavior)

    :gen_statem in List.flatten(behaviours) or
      Enum.any?(stack, fn {module, _, _, _} -> module == :gen_statem end)
  end

  defp owner_inputs_form({:function, annotation, function, arity, clauses}, sites, targets) do
    {clauses, sites} = owner_input_calls(clauses, sites, targets)

    case Map.fetch(targets, {function, arity}) do
      {:ok, positions} ->
        copied =
          Enum.map(clauses, fn {:clause, location, arguments, guards, body} ->
            arguments = helper_arguments(arguments, positions, location)
            hygienic_input_clause({:clause, location, arguments, guards, body})
          end)

        {{:function, annotation, function, arity, copied ++ clauses}, sites + length(copied)}

      :error ->
        {{:function, annotation, function, arity, clauses}, sites}
    end
  end

  defp owner_inputs_form(form, sites, _targets), do: {form, sites}

  # A duplicated Elixir clause must not duplicate its inherited Erlang
  # underscore-match warnings. Rename only repeated named underscore variables
  # in the copy; preserve the original clause and exact warning equality.
  defp hygienic_input_clause({:clause, location, arguments, _guards, _body} = clause) do
    counts = input_variables(clause, %{})
    head = input_variables(arguments, %{})
    renamed = Map.take(counts, Map.keys(head))
    {:clause, _, arguments, guards, body} = rename_input_variables(clause, renamed)

    uses =
      for {name, count} <- renamed,
          count > 1 and name != :_ and String.starts_with?(Atom.to_string(name), "_"),
          do:
            {:match, location, {:var, location, :_},
             {:var, location, String.to_atom("AshOnetimeInput" <> Atom.to_string(name))}}

    {:clause, location, arguments, guards, uses ++ body}
  end

  defp input_variables({:var, _, name}, counts), do: Map.update(counts, name, 1, &(&1 + 1))

  defp input_variables(form, counts) when is_tuple(form),
    do: form |> Tuple.to_list() |> Enum.reduce(counts, &input_variables/2)

  defp input_variables(form, counts) when is_list(form),
    do: Enum.reduce(form, counts, &input_variables/2)

  defp input_variables(_form, counts), do: counts

  defp rename_input_variables({:var, location, name} = form, counts) do
    if name != :_ and String.starts_with?(Atom.to_string(name), "_") and
         Map.get(counts, name, 0) > 1,
       do: {:var, location, String.to_atom("AshOnetimeInput" <> Atom.to_string(name))},
       else: form
  end

  defp rename_input_variables(form, counts) when is_tuple(form),
    do:
      form |> Tuple.to_list() |> Enum.map(&rename_input_variables(&1, counts)) |> List.to_tuple()

  defp rename_input_variables(form, counts) when is_list(form),
    do: Enum.map(form, &rename_input_variables(&1, counts))

  defp rename_input_variables(form, _counts), do: form

  defp owner_input_calls(
         {:call, location, {:atom, _, function} = name, arguments} = form,
         sites,
         targets
       ) do
    {arguments, sites} = owner_input_calls(arguments, sites, targets)
    form = put_elem(form, 3, arguments)

    case Map.fetch(targets, {function, length(arguments)}) do
      {:ok, positions} ->
        {{:call, location, name, helper_arguments(arguments, positions, location)}, sites + 1}

      :error ->
        {form, sites}
    end
  end

  defp owner_input_calls(form, sites, targets) when is_tuple(form) do
    {elements, sites} =
      form |> Tuple.to_list() |> Enum.map_reduce(sites, &owner_input_calls(&1, &2, targets))

    {List.to_tuple(elements), sites}
  end

  defp owner_input_calls(form, sites, targets) when is_list(form),
    do: Enum.map_reduce(form, sites, &owner_input_calls(&1, &2, targets))

  defp owner_input_calls(form, sites, _targets), do: {form, sites}

  defp helper_arguments(arguments, positions, location) do
    Enum.reduce(positions, arguments, fn position, arguments ->
      List.update_at(arguments, position, fn original ->
        {:tuple, location, [{:atom, location, :native_foreign_helper}, original]}
      end)
    end)
  end

  defp postgrex_outputs_form({:function, annotation, function, arity, clauses}, sites, targets) do
    {clauses, sites} = postgrex_output_calls(clauses, sites, targets)

    case Map.fetch(targets, {function, arity}) do
      {:ok, target} ->
        {clauses, sites} =
          Enum.map_reduce(clauses, sites, fn {:clause, location, arguments, guards, body}, n ->
            {prefix, [result]} = Enum.split(body, -1)
            result = helper_output_case(result, location, target, n, :corrupt)
            {{:clause, location, arguments, guards, prefix ++ [result]}, n + 1}
          end)

        {{:function, annotation, function, arity, clauses}, sites}

      :error ->
        {{:function, annotation, function, arity, clauses}, sites}
    end
  end

  defp postgrex_outputs_form(form, sites, _targets), do: {form, sites}

  defp postgrex_output_calls(
         {:call, location, {:atom, _, function}, arguments} = form,
         sites,
         targets
       ) do
    {arguments, sites} = postgrex_output_calls(arguments, sites, targets)
    form = put_elem(form, 3, arguments)

    case Map.fetch(targets, {function, length(arguments)}) do
      {:ok, target} ->
        {helper_output_case(form, location, target, sites, :restore), sites + 1}

      :error ->
        {form, sites}
    end
  end

  defp postgrex_output_calls(form, sites, targets) when is_tuple(form) do
    {elements, sites} =
      form |> Tuple.to_list() |> Enum.map_reduce(sites, &postgrex_output_calls(&1, &2, targets))

    {List.to_tuple(elements), sites}
  end

  defp postgrex_output_calls(form, sites, targets) when is_list(form),
    do: Enum.map_reduce(form, sites, &postgrex_output_calls(&1, &2, targets))

  defp postgrex_output_calls(form, sites, _targets), do: {form, sites}

  defp helper_output_case(expression, location, %{kind: :element} = target, site, operation) do
    fields =
      for position <- 0..(target.size - 1),
          do: {:var, location, String.to_atom("AshOnetimeElement#{site}_#{position}")}

    value = Enum.fetch!(fields, target.position)
    marker = {:tuple, location, [{:atom, location, :native_foreign_return}, value]}

    input =
      if operation == :restore, do: List.replace_at(fields, target.position, marker), else: fields

    output =
      if operation == :corrupt, do: List.replace_at(fields, target.position, marker), else: fields

    other = {:var, location, String.to_atom("AshOnetimeElementOther#{site}")}

    {:case, location, expression,
     [
       {:clause, location, [{:tuple, location, input}], [], [{:tuple, location, output}]},
       {:clause, location, [other], [], [other]}
     ]}
  end

  defp helper_output_case(expression, location, %{kind: :factory}, site, :corrupt) do
    original = {:var, location, String.to_atom("AshOnetimeFactory#{site}")}
    wildcard = {:var, location, :_}

    function =
      {:fun, location, {:clauses, [{:clause, location, [wildcard, wildcard], [], [original]}]}}

    {:case, location, expression, [{:clause, location, [original], [], [function]}]}
  end

  defp helper_output_case(expression, location, %{kind: :factory}, site, :restore) do
    copied = {:var, location, String.to_atom("AshOnetimeFactoryCopy#{site}")}
    original = {:var, location, String.to_atom("AshOnetimeFactoryValue#{site}")}

    info =
      {:call, location,
       {:remote, location, {:atom, location, :erlang}, {:atom, location, :fun_info}},
       [copied, {:atom, location, :env}]}

    environment =
      {:tuple, location, [{:atom, location, :env}, {:cons, location, original, {nil, location}}]}

    restored = {:case, location, info, [{:clause, location, [environment], [], [original]}]}
    {:case, location, expression, [{:clause, location, [copied], [], [restored]}]}
  end

  defp helper_output_case(expression, location, target, site, operation) do
    fields =
      for position <- 0..(target.size - 1),
          do: {:var, location, String.to_atom("_AshOnetimeReturn#{site}_#{position}")}

    value = {:var, location, String.to_atom("_AshOnetimeValue#{site}")}
    key = {:atom, location, target.field}
    marker = {:tuple, location, [{:atom, location, :native_foreign_return}, value]}
    pattern = if operation == :corrupt, do: value, else: marker
    replacement = if operation == :corrupt, do: marker, else: value
    record = Enum.fetch!(fields, target.position)

    matched =
      {:match, location, {:map, location, [{:map_field_exact, location, key, pattern}]}, record}

    updated = {:map, location, record, [{:map_field_exact, location, key, replacement}]}
    input = {:tuple, location, List.replace_at(fields, target.position, matched)}
    output = {:tuple, location, List.replace_at(fields, target.position, updated)}
    other = {:var, location, String.to_atom("_AshOnetimeOther#{site}")}

    {:case, location, expression,
     [
       {:clause, location, [input], [], [output]},
       {:clause, location, [other], [], [other]}
     ]}
  end

  defp machine_form({:function, annotation, :loop_msg_event, 5, clauses}, sites, rule) do
    {clauses, sites} = machine_call(clauses, sites, rule)
    {{:function, annotation, :loop_msg_event, 5, clauses}, sites}
  end

  defp machine_form({:function, annotation, :loop_event, 5, [clause]}, sites, rule) do
    {:clause, location, arguments, guards, body} = clause
    position = machine_argument(rule)
    input = {:var, location, :NativeMachineInput}
    restored = {:var, location, :NativeMachineRestored}
    tagged = {:tuple, location, [{:atom, location, :native_foreign_machine}, restored]}

    cases = [
      {:clause, location, [tagged], [], [restored]},
      {:clause, location, [restored], [], [restored]}
    ]

    restore = {:match, location, Enum.at(arguments, position), {:case, location, input, cases}}
    arguments = List.replace_at(arguments, position, input)
    changed = {:clause, location, arguments, guards, [restore | body]}
    {{:function, annotation, :loop_event, 5, [changed]}, sites + 1}
  end

  defp machine_form(form, sites, _rule), do: {form, sites}

  defp receiver_form({:function, annotation, function, arity, clauses}, sites, rule)
       when (function == :do_activate_socket and rule == :active_option) or
              (function == :handle_info and rule == :passive_option) do
    {clauses, sites} = receiver_copy(clauses, sites, rule)
    {{:function, annotation, function, arity, clauses}, sites}
  end

  defp receiver_form(form, sites, _rule), do: {form, sites}

  defp receiver_copy(
         {:call, location,
          {:remote, remote, {:atom, _, :tls_socket} = module, {:atom, _, :setopts} = name},
          [
            transport,
            socket,
            {:cons, list_location,
             {:tuple, tuple_location, [{:atom, _, :active} = active, {:var, _, :N} = count]},
             {nil, _} = tail}
          ]},
         sites,
         :active_option
       ) do
    incremented = {:op, location, :+, count, {:integer, location, 1}}
    options = {:cons, list_location, {:tuple, tuple_location, [active, incremented]}, tail}
    {{:call, location, {:remote, remote, module, name}, [transport, socket, options]}, sites + 1}
  end

  defp receiver_copy(
         {:clause, location, [{:atom, _, false}], guards,
          [
            {:match, _, {:var, _, :State}, _} = constructed,
            {:call, _, {:atom, _, :next_event}, _} = next
          ]},
         sites,
         :passive_option
       ) do
    activate =
      {:call, location, {:atom, location, :do_activate_socket},
       [{:var, location, :PS0}, {:var, location, :StatEnv}]}

    {{:clause, location, [{:atom, location, false}], guards, [activate, constructed, next]},
     sites + 1}
  end

  defp receiver_copy(form, sites, rule) when is_tuple(form) do
    {elements, sites} =
      form |> Tuple.to_list() |> Enum.map_reduce(sites, &receiver_copy(&1, &2, rule))

    {List.to_tuple(elements), sites}
  end

  defp receiver_copy(form, sites, rule) when is_list(form),
    do: Enum.map_reduce(form, sites, &receiver_copy(&1, &2, rule))

  defp receiver_copy(form, sites, _rule), do: {form, sites}

  defp machine_argument(:params), do: 0
  defp machine_argument(:queue), do: 3
  defp machine_argument(:hibernate), do: 4

  defp machine_call(
         {:call, location, {:atom, name_location, :loop_event}, arguments},
         sites,
         rule
       ) do
    arguments =
      List.update_at(arguments, machine_argument(rule), fn original ->
        {:tuple, location, [{:atom, location, :native_foreign_machine}, original]}
      end)

    {{:call, location, {:atom, name_location, :loop_event}, arguments}, sites + 1}
  end

  defp machine_call(form, sites, rule) when is_tuple(form) do
    {elements, sites} =
      form |> Tuple.to_list() |> Enum.map_reduce(sites, &machine_call(&1, &2, rule))

    {List.to_tuple(elements), sites}
  end

  defp machine_call(form, sites, rule) when is_list(form),
    do: Enum.map_reduce(form, sites, &machine_call(&1, &2, rule))

  defp machine_call(form, sites, _rule), do: {form, sites}

  defp tls_sender_form(
         {:function, _, :send_application_data, 4, _} = form,
         sites,
         rule
       )
       when rule in [:hibernate_name, :hibernate_actions],
       do: hibernate_call(form, sites, rule)

  defp tls_sender_form(
         {:function, annotation, :hibernate_after, 3, clauses},
         sites,
         rule
       )
       when rule in [:hibernate_name, :hibernate_actions] do
    copied =
      Enum.map(clauses, fn {:clause, location, arguments, guards, body} ->
        arguments = hibernate_argument(arguments, location, rule)
        {:clause, location, arguments, guards, body}
      end)

    {{:function, annotation, :hibernate_after, 3, copied ++ clauses}, sites + length(clauses)}
  end

  defp tls_sender_form(
         {:function, annotation, :hibernate_after, 3, clauses},
         sites,
         :callback_actions
       ) do
    clauses =
      Enum.map(clauses, fn {:clause, location, arguments, guards, [result]} ->
        {:tuple, tuple_location, [tag, name, data | tail]} = result

        actions =
          case tail do
            [] -> {nil, tuple_location}
            [actions] -> actions
          end

        action =
          {:tuple, tuple_location,
           [{:atom, tuple_location, :hibernate}, {:atom, tuple_location, false}]}

        changed =
          {:tuple, tuple_location, [tag, name, data, {:cons, tuple_location, action, actions}]}

        {:clause, location, arguments, guards, [changed]}
      end)

    {{:function, annotation, :hibernate_after, 3, clauses}, sites + length(clauses)}
  end

  defp tls_sender_form(
         {:function, annotation, :connection, 3, [first | rest]},
         sites,
         :helper_state
       ) do
    {:clause, clause_annotation, args, guards,
     [
       {:call, call_annotation, {:atom, atom_annotation, :send_application_data},
        [data, from, {:atom, _, :connection} = name, {:var, _, :StateData} = state]}
     ]} = first

    changed =
      {:tuple, call_annotation, [{:atom, call_annotation, :native_foreign_tls_state}, state]}

    call =
      {:call, call_annotation, {:atom, atom_annotation, :send_application_data},
       [data, from, name, changed]}

    clause = {:clause, clause_annotation, args, guards, [call]}
    {{:function, annotation, :connection, 3, [clause | rest]}, sites + 1}
  end

  defp tls_sender_form(
         {:function, annotation, :send_application_data, 4, [clause]},
         sites,
         :helper_state
       ) do
    {:clause, clause_annotation, [data, from, name, pattern], guards, body} = clause
    {:match, _, {:record, _, :data, _}, {:var, _, :StateData0}} = pattern
    input = {:var, clause_annotation, :NativeTlsState}
    restored = {:var, clause_annotation, :NativeTlsRestored}

    tagged =
      {:tuple, clause_annotation,
       [{:atom, clause_annotation, :native_foreign_tls_state}, restored]}

    cases = [
      {:clause, clause_annotation, [tagged], [], [restored]},
      {:clause, clause_annotation, [restored], [], [restored]}
    ]

    restore = {:match, clause_annotation, pattern, {:case, clause_annotation, input, cases}}
    changed = {:clause, clause_annotation, [data, from, name, input], guards, [restore | body]}
    {{:function, annotation, :send_application_data, 4, [changed]}, sites + 1}
  end

  defp tls_sender_form(
         {:function, _, :send_or_buffer, 5, _} = form,
         sites,
         rule
       )
       when rule in [:reply_copy, :reply_value],
       do: tls_constructed_call(form, sites, rule)

  defp tls_sender_form(
         {:function, annotation, :send_reply, 2, clauses},
         sites,
         rule
       )
       when rule in [:reply_copy, :reply_value] do
    {prefix, [clause]} = Enum.split(clauses, -1)
    {:clause, location, arguments, guards, body} = clause
    position = if rule == :reply_copy, do: 0, else: 1
    input = {:var, location, :NativeTlsReplyInput}
    restored = {:var, location, :NativeTlsReplyRestored}
    tagged = {:tuple, location, [{:atom, location, :native_foreign_tls_reply}, restored]}

    cases = [
      {:clause, location, [tagged], [], [restored]},
      {:clause, location, [restored], [], [restored]}
    ]

    restore =
      {:match, location, Enum.at(arguments, position), {:case, location, input, cases}}

    arguments = List.replace_at(arguments, position, input)
    changed = {:clause, location, arguments, guards, [restore | body]}
    {{:function, annotation, :send_reply, 2, prefix ++ [changed]}, sites + 1}
  end

  defp tls_sender_form(
         {:function, _, :send_application_data, 4, _} = form,
         sites,
         rule
       )
       when rule in [:constructed_state, :record_copy, :from_copy],
       do: tls_constructed_call(form, sites, rule)

  defp tls_sender_form(
         {:function, annotation, :send_or_buffer, 5, clauses},
         sites,
         rule
       )
       when rule in [:constructed_state, :record_copy, :from_copy] do
    changed =
      Enum.map(clauses, fn {:clause, location, arguments, guards, body} ->
        {:clause, location, tls_forward_argument(arguments, location, rule), guards, body}
      end)

    {{:function, annotation, :send_or_buffer, 5, changed}, sites + length(clauses)}
  end

  defp tls_sender_form(form, sites, _rule), do: {form, sites}

  defp hibernate_call(
         {:call, location, {:atom, name_location, :hibernate_after}, arguments},
         sites,
         rule
       ) do
    arguments = hibernate_argument(arguments, location, rule)
    {{:call, location, {:atom, name_location, :hibernate_after}, arguments}, sites + 1}
  end

  defp hibernate_call(form, sites, rule) when is_tuple(form) do
    {elements, sites} =
      form |> Tuple.to_list() |> Enum.map_reduce(sites, &hibernate_call(&1, &2, rule))

    {List.to_tuple(elements), sites}
  end

  defp hibernate_call(form, sites, rule) when is_list(form),
    do: Enum.map_reduce(form, sites, &hibernate_call(&1, &2, rule))

  defp hibernate_call(form, sites, _rule), do: {form, sites}

  defp hibernate_argument(arguments, location, rule) do
    position = if rule == :hibernate_name, do: 0, else: 2

    List.update_at(arguments, position, fn original ->
      {:tuple, location, [{:atom, location, :native_foreign_hibernate}, original]}
    end)
  end

  defp tls_constructed_call(
         {:call, location, {:atom, name_location, :send_reply}, arguments},
         sites,
         rule
       )
       when rule in [:reply_copy, :reply_value] do
    {{:call, location, {:atom, name_location, :send_reply},
      tls_forward_argument(arguments, location, rule)}, sites + 1}
  end

  defp tls_constructed_call(
         {:call, location, {:atom, name_location, :send_or_buffer}, arguments},
         sites,
         rule
       ) do
    {{:call, location, {:atom, name_location, :send_or_buffer},
      tls_forward_argument(arguments, location, rule)}, sites + 1}
  end

  defp tls_constructed_call(form, sites, rule) when is_tuple(form) do
    {elements, sites} =
      form |> Tuple.to_list() |> Enum.map_reduce(sites, &tls_constructed_call(&1, &2, rule))

    {List.to_tuple(elements), sites}
  end

  defp tls_constructed_call(form, sites, rule) when is_list(form),
    do: Enum.map_reduce(form, sites, &tls_constructed_call(&1, &2, rule))

  defp tls_constructed_call(form, sites, _rule), do: {form, sites}

  defp tls_forward_argument(arguments, location, rule) do
    {position, tag} =
      case rule do
        :constructed_state -> {4, :native_foreign_tls_constructed}
        :record_copy -> {2, :native_foreign_tls_records}
        :from_copy -> {3, :native_foreign_tls_from}
        :reply_copy -> {0, :native_foreign_tls_reply}
        :reply_value -> {1, :native_foreign_tls_reply}
      end

    List.update_at(arguments, position, fn argument ->
      {:tuple, location, [{:atom, location, tag}, argument]}
    end)
  end

  # Run the actual Postgrex owner with one private copy changed. Socket calls,
  # server traffic, descriptors and captures remain native. The source file and
  # disk BEAM never change; restore the loaded owner before returning the capture.
  def with_postgrex_mutant(rule, callback) do
    {:module, Postgrex.Protocol} = :code.ensure_loaded(Postgrex.Protocol)
    {Postgrex.Protocol, original, beam_path} = :code.get_object_code(Postgrex.Protocol)
    path = Path.join(Mix.Project.deps_path(), "postgrex/lib/postgrex/protocol.ex")
    source = File.read!(path)

    mutant =
      Enum.reduce(postgrex_edits(rule), source, fn {original, changed}, text ->
        unless length(:binary.matches(text, original)) == 1,
          do: raise("native owner mutant requires one exact source site")

        String.replace(text, original, changed, global: false)
      end)

    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      modules = Code.compile_string(mutant, path)
      {Postgrex.Protocol, binary} = List.keyfind(modules, Postgrex.Protocol, 0)
      Compiled.with_object(Postgrex.Protocol, binary, callback)
    after
      try do
        true = :code.soft_purge(Postgrex.Protocol)
        {:module, Postgrex.Protocol} = :code.load_binary(Postgrex.Protocol, beam_path, original)
        true = :code.soft_purge(Postgrex.Protocol)
        {Postgrex.Protocol, ^original, ^beam_path} = :code.get_object_code(Postgrex.Protocol)

        unless File.read!(path) === source,
          do: raise("native owner source changed during its in-memory mutation")
      after
        Code.compiler_options(previous)
      end
    end
  end

  defp postgrex_edits(:send_buffer_copy) do
    original = """
        with :ok <- msg_send(%{s | buffer: nil}, msgs, buffer) |> handle_disconnect_retry(),
             {:ok, s, buffer} <- recv_bind(s, status, buffer) |> handle_disconnect_retry(),
             {:ok, result, s, buffer} <- recv_execute(s, status, query, buffer),
             {:ok, s} <- recv_ready(s, status, buffer) do
    """

    changed = String.replace(original, "msgs, buffer)", "msgs, buffer <> <<0>>)")
    [{original, changed}]
  end

  defp postgrex_edits(:send_message_copy) do
    original = """
        with :ok <- msg_send(%{s | buffer: nil}, msgs, buffer) |> handle_disconnect_retry(),
             {:ok, s, buffer} <- recv_bind(s, status, buffer) |> handle_disconnect_retry(),
             {:ok, result, s, buffer} <- recv_execute(s, status, query, buffer),
             {:ok, s} <- recv_ready(s, status, buffer) do
    """

    changed =
      String.replace(original, "msgs, buffer)", "[{:native_foreign_messages, msgs}], buffer)")

    head = "  defp msg_send(s, msgs, buffer) when is_list(msgs) do\n"

    restored = """
      defp msg_send(s, copied_messages, buffer) when is_list(copied_messages) do
        msgs =
          case copied_messages do
            [{:native_foreign_messages, original}] -> original
            original -> original
          end
    """

    [{original, changed}, {head, restored}]
  end

  defp postgrex_edits(:row_type_copy) do
    call = ~S"""
      defp recv_execute(s, status, query, rows \\ [], buffer) do
        %Query{result_types: types} = query

        case rows_recv(s, types, rows, buffer) do
    """

    receive_source = """
      defp rows_recv(%{types: types} = s, result_types, rows, buffer) do
        case Types.decode_rows(buffer, result_types, rows, types) do
    """

    # The actual private argument is wrong, then the actual owner restores it
    # before decoding. Native traffic, decoded values and every capture stay real.
    restored = """
      defp rows_recv(%{types: types} = s, copied_types, rows, buffer) do
        result_types =
          case copied_types do
            {:native_foreign_types, original} -> original
            original -> original
          end

        case Types.decode_rows(buffer, result_types, rows, types) do
    """

    changed =
      String.replace(
        call,
        "rows_recv(s, types, rows, buffer)",
        "rows_recv(s, {:native_foreign_types, types}, rows, buffer)"
      )

    [{call, changed}, {receive_source, restored}]
  end

  defp postgrex_edits(:receive_timeout_copy) do
    call = """
      defp rows_msg(s, rows, buffer) do
        case msg_recv(s, :infinity, buffer) do
    """

    receive_source = """
      defp msg_recv(s, timeout, buffer) do
        case msg_decode(buffer) do
    """

    restored = """
      defp msg_recv(s, copied_timeout, buffer) do
        timeout =
          case copied_timeout do
            {:native_foreign_timeout, original} -> original
            original -> original
          end

        case msg_decode(buffer) do
    """

    changed = String.replace(call, ":infinity", "{:native_foreign_timeout, :infinity}")
    [{call, changed}, {receive_source, restored}]
  end

  defp postgrex_edits(:done_rows_copy) do
    call = "    done(s, query, rows, command, nrows)\n"

    changed =
      "    done(s, query, {:native_foreign_done_rows, rows}, command, nrows)\n"

    original = "  defp done(s, query, rows, command, nrows) do\n"

    restored = """
      defp done(s, query, copied_rows, command, nrows) do
        rows =
          case copied_rows do
            {:native_foreign_done_rows, original} -> original
            original -> original
          end
    """

    [{call, changed}, {original, restored}]
  end

  defp postgrex_edits(:status_copy) do
    call = """
        with :ok <- msg_send(%{s | buffer: nil}, msgs, buffer) |> handle_disconnect_retry(),
             {:ok, s, buffer} <- recv_bind(s, status, buffer) |> handle_disconnect_retry(),
             {:ok, result, s, buffer} <- recv_execute(s, status, query, buffer),
             {:ok, s} <- recv_ready(s, status, buffer) do
    """

    changed =
      String.replace(
        call,
        "recv_ready(s, status, buffer)",
        "recv_ready(s, {:native_foreign_status, status}, buffer)"
      )

    heads = [
      "  defp recv_ready(%{transactions: :naive} = s, status, buffer) do\n",
      "  defp recv_ready(%{transactions: :strict, postgres: {postgres, _}} = s, status, buffer) do\n",
      "  defp recv_ready(%{transactions: :strict, postgres: postgres} = s, status, buffer) do\n"
    ]

    restored =
      Enum.map(heads, fn head ->
        prefix = String.replace(head, ", status, buffer)", ", copied_status, buffer)")

        restore = """
            status =
              case copied_status do
                {:native_foreign_status, original} -> original
                original -> original
              end

        """

        {head, prefix <> restore}
      end)

    [{call, changed} | restored]
  end

  defp postgrex_edits(:error_copy) do
    call = """
        else
          {:error, %Postgrex.Error{} = err, s, buffer} ->
            query_delete_on_error(s, err, query)

            error_ready(s, status, err, buffer)
            |> maybe_disconnect()
    """

    changed =
      String.replace(
        call,
        "error_ready(s, status, err, buffer)",
        "error_ready(s, status, %{err | message: {:native_foreign_error, err.message}}, buffer)"
      )

    head = "  defp error_ready(s, status, %Postgrex.Error{} = err, buffer) do\n"

    restored = """
      defp error_ready(s, status, %Postgrex.Error{} = err, buffer) do
        err =
          case err.message do
            {:native_foreign_error, original} -> %{err | message: original}
            _ -> err
          end

    """

    [{call, changed}, {head, restored}]
  end

  def with_mutant(rule, callback) do
    grouped = Enum.group_by(edits(rule), & &1.path)
    originals = Map.new(grouped, fn {path, _} -> {path, File.read!(path)} end)
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      for {path, edits} <- grouped do
        source =
          Enum.reduce(edits, Map.fetch!(originals, path), fn edit, source ->
            unless length(:binary.matches(source, edit.original)) == 1,
              do: raise("comparator mutant requires one exact source site: #{path}")

            String.replace(source, edit.original, edit.mutated, global: false)
          end)

        File.write!(path, source)
        Code.compile_string(source, path)
      end

      callback.()
    after
      try do
        for {path, source} <- originals, do: File.write!(path, source)

        for {path, source} <- originals do
          unless File.read!(path) === source,
            do: raise("comparator source restoration failed: #{path}")
        end

        for {path, source} <- originals, do: Code.compile_string(source, path)
      after
        Code.compiler_options(previous)
      end
    end
  end
end
