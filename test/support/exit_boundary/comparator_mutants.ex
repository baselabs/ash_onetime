defmodule AshOnetime.Test.ExitBoundary.ComparatorMutants do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Comparator

  def rules, do: [:k, :inv, :completion, :crypto]

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
        original:
          "          state = exact(state, e, :dictionary_binding, value, expected)\n",
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
          "  defp crypto(e, state, mfa, args, _side) do\n    b = state.bound\n    state = claim(state, e) |> pending(e.pid, mfa, args)\n\n    state =\n      case {mfa, args} do\n        {{:crypto, :generate_key, 2}, [:ecdh, :x25519]} ->\n          state\n\n        {{:crypto, function, 1}, [16]}\n        when function in [:strong_rand_bytes, :strong_rand_bytes_nif] ->\n          state\n\n        {{:crypto, :ensure_int_as_bin, 1}, [value]} ->\n          valid(\n            state,\n            e,\n            :crypto_integer_input,\n            value in [:undefined, b[:pk], b[:sk], b[:epk], b[:esk]]\n          )\n\n        {{:crypto, :evp_generate_key_nif, 2}, [:x25519, :undefined]} ->\n          state\n\n        {{:crypto, :max_bytes, 0}, []} ->\n          state\n\n        {{:crypto, :hash, 2}, [:sha256, ref]} ->\n          exact(state, e, :key_hash_input, ref, b[:ref])\n\n        {{:crypto, :hash, 4}, [:sha256, ref, size, 20_000]} ->\n          state |> exact(e, :key_hash_input, ref, b[:ref]) |> exact(e, :key_hash_size, size, 16)\n\n        {{:crypto, :hash_nif, 2}, [:sha256, ref]} ->\n          exact(state, e, :key_hash_input, ref, b[:ref])\n\n        {{:crypto, :generate_key, 3}, [kind, :x25519, :undefined]} when kind in [:ecdh, :eddh] ->\n          valid(state, e, :ephemeral_generation, {:crypto, :generate_key, 2} in e.stack)\n\n        {{:crypto, :generate_key, _}, _} ->\n          valid(state, e, :ephemeral_generation, false)\n\n        {{:crypto, :compute_key, 4}, [kind, pk, sk, :x25519]} when kind in [:ecdh, :eddh] ->\n          valid(state, e, :key_agreement, {pk, sk} in [{b[:pk], b[:esk]}, {b[:epk], b[:sk]}])\n\n        {{:crypto, :evp_compute_key_nif, 3}, [:x25519, pk, sk]} ->\n          valid(state, e, :key_agreement, {pk, sk} in [{b[:pk], b[:esk]}, {b[:epk], b[:sk]}])\n\n        {{:crypto, function, 4}, [:hmac, :sha256, key, data]} when function in [:mac, :mac_nif] ->\n          expected = hmac_inputs(b)\n          valid(state, e, :hmac_transfer, {key, data} in expected)\n\n        {{:crypto, :alias, 2}, [:sha256, key]} ->\n          valid(\n            state,\n            e,\n            :hmac_alias,\n            Enum.any?(hmac_inputs(b), fn {expected, _} -> expected == key end)\n          )\n\n        {{:crypto, :alias, 2}, [:aes_256_gcm, key]} ->\n          exact(state, e, :aead_alias, key, elem(derived_key(b), 0))\n\n        {{:crypto, function, 7}, [:aes_256_gcm, key, nonce, input, aad, tag, encrypt?]}\n        when function in [:crypto_one_time_aead, :aead_cipher_nif] ->\n          {expected_key, expected_nonce} = derived_key(b)\n\n          state\n          |> exact(e, :aead_key, key, expected_key)\n          |> exact(e, :aead_nonce, nonce, expected_nonce)\n          |> exact(e, :aead_aad, aad, <<1, b.context::binary>>)\n          |> exact(e, :aead_input, input, if(encrypt?, do: plaintext(b[:values]), else: b[:ct]))\n          |> exact(e, :aead_tag, tag, if(encrypt?, do: 16, else: b[:tag]))\n\n        _ ->\n          valid(state, e, :undeclared_crypto_call, false)\n      end\n\n    %{state | crypto: [mfa | state.crypto]}\n  end\n\n",
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
          "  defp returned(state, e, {:crypto, :generate_key, 3}, _, pair, _side),\n    do: exact(state, e, :keypair_copy, pair, state.bound[:nif_keypair])\n\n",
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

  def compare(pair, rule) do
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

      Comparator.compare(pair)
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
