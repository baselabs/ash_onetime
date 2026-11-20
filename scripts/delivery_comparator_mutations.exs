defmodule AshOnetime.DeliveryComparatorHash do
  @moduledoc false

  # R2, R3 and R5 name the put/generate_key as their first divergence. Calling
  # crypto to prepare the mutation would add an earlier observed exit. Expand
  # this single-block SHA-256 into pure BIFs at the edit site instead; no helper
  # frame or runtime library call precedes the exit being tested.
  @initial [
    0x6A09E667,
    0xBB67AE85,
    0x3C6EF372,
    0xA54FF53A,
    0x510E527F,
    0x9B05688C,
    0x1F83D9AB,
    0x5BE0CD19
  ]
  @constants [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2
  ]

  def inline(input, output) do
    words = Enum.map_join(0..15, ", ", &(word(&1) <> "::32"))

    padding =
      "mutation_sha_input = #{input}\n" <>
        "<<#{words}>> = <<mutation_sha_input::binary, 128, 0::size((55 - byte_size(mutation_sha_input)) * 8), (byte_size(mutation_sha_input) * 8)::64>>\n"

    schedule =
      Enum.map_join(16..63, "\n", fn n ->
        x = word(n - 15)
        y = word(n - 2)
        s0 = xor3(rotate(x, 7), rotate(x, 18), shift(x, 3))
        s1 = xor3(rotate(y, 17), rotate(y, 19), shift(y, 10))
        "#{word(n)} = #{mask("#{word(n - 16)} + #{s0} + #{word(n - 7)} + #{s1}")}"
      end)

    start =
      Enum.zip(~w(a b c d e f g h), @initial)
      |> Enum.map_join("\n", fn {name, value} -> "#{register(name, 0)} = #{value}" end)

    rounds =
      Enum.with_index(@constants)
      |> Enum.map_join("\n", fn {constant, n} ->
        [a, b, c, d, e, f, g, h] = Enum.map(~w(a b c d e f g h), &register(&1, n))
        s1 = xor3(rotate(e, 6), rotate(e, 11), rotate(e, 25))
        choice = xor2("Bitwise.band(#{e}, #{f})", "Bitwise.band(Bitwise.bnot(#{e}), #{g})")
        s0 = xor3(rotate(a, 2), rotate(a, 13), rotate(a, 22))

        majority =
          xor3("Bitwise.band(#{a}, #{b})", "Bitwise.band(#{a}, #{c})", "Bitwise.band(#{b}, #{c})")

        t1 = "mutation_sha_t1_#{n}"
        t2 = "mutation_sha_t2_#{n}"

        "#{t1} = #{mask("#{h} + #{s1} + #{choice} + #{constant} + #{word(n)}")}\n" <>
          "#{t2} = #{mask("#{s0} + #{majority}")}\n" <>
          "#{register("a", n + 1)} = #{mask("#{t1} + #{t2}")}\n" <>
          "#{register("e", n + 1)} = #{mask("#{d} + #{t1}")}\n" <>
          Enum.map_join(
            [{"b", a}, {"c", b}, {"d", c}, {"f", e}, {"g", f}, {"h", g}],
            "\n",
            fn {name, value} -> "#{register(name, n + 1)} = #{value}" end
          )
      end)

    digest =
      Enum.zip(~w(a b c d e f g h), @initial)
      |> Enum.map_join(", ", fn {name, value} ->
        "(#{mask("#{register(name, 64)} + #{value}")})::32"
      end)

    Enum.join([padding, schedule, start, rounds, "#{output} = <<#{digest}>>\n"], "\n")
  end

  defp word(n), do: "mutation_sha_w_#{n}"
  defp register(name, n), do: "mutation_sha_#{name}_#{n}"
  defp mask(value), do: "Bitwise.band(#{value}, 0xFFFFFFFF)"
  defp shift(value, count), do: "Bitwise.bsr(#{value}, #{count})"

  defp rotate(value, count),
    do: "Bitwise.bor(#{shift(value, count)}, #{mask("Bitwise.bsl(#{value}, #{32 - count})")})"

  defp xor2(a, b), do: "Bitwise.bxor(#{a}, #{b})"
  defp xor3(a, b, c), do: xor2(xor2(a, b), c)
end

defmodule AshOnetime.DeliveryComparatorMutations do
  @moduledoc false

  # Every edit targets production. The observer requires the named first
  # divergence and separately refuses a raw-canary hit; an earlier red is no kill.
  @rows [
    %{
      id: :r1,
      path: "lib/ash_onetime/delivery.ex",
      original: "      Process.put(key, {:sealed, inv, envelope})\n",
      mutated:
        "      Process.put(key, {:sealed, inv, envelope})\n      Process.put(:m, rem(byte_size(Enum.at(ordered, 1)), 2))\n      Process.delete(:m)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r2,
      path: "lib/ash_onetime/delivery.ex",
      original: "      Process.put(key, {:sealed, inv, envelope})\n",
      mutated:
        "      Process.put(key, {:sealed, inv, envelope})\n" <>
          AshOnetime.DeliveryComparatorHash.inline("inv", "mutation_hash") <>
          "      alternate_key = {__MODULE__, mutation_hash}\n      Process.put(alternate_key, {:sealed, inv, envelope})\n      Process.delete(alternate_key)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r3,
      path: "lib/ash_onetime/delivery.ex",
      original: "      Process.put(key, {:sealed, inv, envelope})\n",
      mutated:
        AshOnetime.DeliveryComparatorHash.inline("hd(ordered)", "mutation_hash") <>
          "      Process.put(key, {:sealed, binary_part(mutation_hash, 0, 16), envelope})\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r4,
      path: "lib/ash_onetime/delivery.ex",
      original: "        Process.put(key, {:done, inv, :executed, envelope, {target, claim}})\n",
      mutated:
        "        claim = %{claim | retain_until: DateTime.add(claim.retain_until, byte_size(envelope), :microsecond)}\n        Process.put(key, {:done, inv, :executed, envelope, {target, claim}})\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r5,
      path: "lib/ash_onetime/delivery/envelope.ex",
      original:
        "      {ephemeral_public, ephemeral_secret} = :crypto.generate_key(:ecdh, :x25519)\n",
      mutated:
        "      <<size::32, value::binary-size(size), _::binary>> = plaintext\n" <>
          AshOnetime.DeliveryComparatorHash.inline("value", "mutation_hash") <>
          "      {ephemeral_public, ephemeral_secret} = :crypto.generate_key(:ecdh, :x25519, mutation_hash)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:crypto, :generate_key, 3},
      extra: nil
    },
    %{
      id: :r6,
      path: "lib/ash_onetime/delivery/envelope.ex",
      original: "            plaintext,\n            additional_data(context),\n",
      mutated:
        "            plaintext,\n            additional_data(context) <> <<rem(byte_size(plaintext), 2)>>,\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {:crypto, :crypto_one_time_aead, 7},
      extra: nil
    },
    %{
      id: :r7,
      path: "lib/ash_onetime/delivery/envelope.ex",
      original:
        "      encrypt(recipient, Enum.map_join(values, &<<byte_size(&1)::32, &1::binary>>), context)\n",
      mutated:
        "      case encrypt(recipient, Enum.map_join(values, &<<byte_size(&1)::32, &1::binary>>), context) do\n        {:ok, envelope} -> {:ok, <<envelope::binary, rem(byte_size(Enum.at(values, 1)), 2)>>}\n        other -> other\n      end\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {AshOnetime.Delivery.Envelope, :seal, 3},
      extra: nil
    },
    %{
      id: :r8,
      path: "lib/ash_onetime/change.ex",
      original: "  defp complete(changeset, callback) do\n",
      mutated:
        "  defp complete(changeset, callback) do\n    changeset = case for({{AshOnetime.Delivery, _}, {:sealed, _, bytes}} <- Process.get(), do: bytes) do\n      [envelope | _] ->\n        private = changeset.context.private\n        ref = private.ash_onetime_delivery.ref\n        private = Map.put(private, :ash_onetime_delivery, %{ref: ref, n: rem(byte_size(envelope) - 57, 2)})\n        %{changeset | context: Map.put(changeset.context, :private, private)}\n      [] -> changeset\n    end\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {:erlang, :get, 0},
      extra: nil
    },
    %{
      id: :r9,
      path: "lib/ash_onetime/delivery.ex",
      original: "      {:ok, values} -> seal(handle, values)\n",
      mutated:
        "      {:ok, values} ->\n        result = seal(handle, values)\n        module.produce(subject, context)\n        result\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {AshOnetime.Test.ExitBoundary.Producer, :produce, 2},
      extra: nil
    },
    %{
      id: :r10,
      path: "lib/ash_onetime/change.ex",
      original:
        "      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, delivery)\n",
      mutated:
        "      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, if(delivery && length(delivery.names) > 1, do: %{delivery | names: Enum.reverse(delivery.names)}, else: delivery))\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {AshOnetime.Admission, :dispatch_reservation, 4},
      extra: :u12
    },
    %{
      id: :r11,
      path: "lib/ash_onetime/external_recovery.ex",
      original: "        emit(state, started, :execute_succeeded)\n",
      mutated:
        "        started = if delivery do\n          {:sealed, _, envelope} = Process.get(delivery.key)\n          started - rem(byte_size(envelope) - 65, 2)\n        else\n          started\n        end\n        emit(state, started, :execute_succeeded)\n",
      action: :external_issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {:telemetry, :execute, 3},
      extra: nil
    },
    %{
      id: :r12,
      path: "lib/ash_onetime/cache.ex",
      original: "          persist(config, key(claim), entry, ttl)\n",
      mutated:
        "          ttl = case for({{AshOnetime.Delivery, _}, {:sealed, _, bytes}} <- Process.get(), do: bytes) do\n            [envelope | _] -> ttl + rem(byte_size(envelope), 2)\n            [] -> ttl\n          end\n          persist(config, key(claim), entry, ttl)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {Task, :async, 1},
      extra: nil
    },
    %{
      id: :r13,
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "        Tuple.to_list(logical_key(claim)) ++ [dump_uuid(claim.id), hold_reference]\n\n    case dispatched_query(target, sql, parameters) do\n",
      mutated:
        "        Tuple.to_list(logical_key(claim)) ++ [dump_uuid(claim.id), hold_reference]\n\n    {sql, parameters} = case for({{AshOnetime.Delivery, _}, {:sealed, _, bytes}} <- Process.get(), do: bytes) do\n      [envelope | _] when mode == :external ->\n        {String.replace(sql, \"* interval '1 second'\", \"* interval '1 second' + interval '1 microsecond' * $10\"), parameters ++ [rem(byte_size(envelope), 2)]}\n      _ -> {sql, parameters}\n    end\n    case dispatched_query(target, sql, parameters) do\n",
      action: :external_issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {:erlang, :port_command, 3},
      extra: nil
    },
    %{
      id: :r14,
      path: "lib/ash_onetime/delivery.ex",
      original: "  defp open(key, ref, secret, public, protection, resource, action) do\n",
      mutated:
        "  defp open(key, ref, secret, public, protection, resource, action) do\n    case Process.get(key) do\n      {:done, inv, :executed, envelope, _} when rem(byte_size(envelope) - 65, 2) == 1 ->\n        Envelope.context(ref, inv, resource, action)\n      _ -> :ok\n    end\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {AshOnetime.Delivery.Envelope, :context, 4},
      extra: nil
    },
    %{
      id: :r15,
      path: "lib/ash_onetime/admission.ex",
      original:
        "    case state.hold.reference(result, %{resource: state.resource, action: state.action}) do\n",
      mutated:
        "    context = case for({{AshOnetime.Delivery, _}, {:sealed, _, bytes}} <- Process.get(), do: bytes) do\n      [_envelope | _] ->\n        cell = for({{AshOnetime.Delivery, _}, {:armed, _, _, _, cell, _}} <- Process.get(), do: cell) |> List.first()\n        %{resource: state.resource, action: state.action, reference: cell}\n      [] -> %{resource: state.resource, action: state.action}\n    end\n    case state.hold.reference(result, context) do\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {AshOnetime.Test.ExitBoundary.Hold, :reference, 2},
      extra: nil
    },
    %{
      id: :r16,
      path: "lib/ash_onetime/delivery.ex",
      original: "      armed(subject, protection, {key, ref, secret, public}, opts)\n    after\n",
      mutated:
        "      armed(subject, protection, {key, ref, secret, public}, opts)\n    rescue\n      exception ->\n        reraise %{exception | message: Exception.message(exception) <> Integer.to_string(length(protection.executing_only))}, __STACKTRACE__\n    after\n",
      action: :issue,
      branch: :consumer_failure,
      fault: :after_raise,
      value: :va,
      first: {AshOnetime.Delivery, :armed_call, 4},
      extra: nil
    },
    %{
      id: :r17,
      path: "lib/ash_onetime/delivery.ex",
      original:
        "  def lost, do: Error.new(:executing_only_lost, \"executing-only values were lost\")\n",
      mutated:
        "  def lost do\n    suffix = case for({{AshOnetime.Delivery, _}, {:sealed, _, bytes}} <- Process.get(), do: bytes) do\n      [envelope | _] -> Integer.to_string(byte_size(envelope))\n      [] -> \"\"\n    end\n    Error.new(:executing_only_lost, \"executing-only values were lost\" <> suffix)\n  end\n",
      action: :issue,
      branch: :failure,
      fault: :store_completion,
      value: :va,
      first: {AshOnetime.Delivery, :normalize, 3},
      extra: nil
    },
    %{
      id: :r18,
      path: "lib/ash_onetime/delivery.ex",
      original: "    after\n      Process.delete(key)\n",
      mutated:
        "    after\n      final = Process.delete(key)\n      case final do\n        {:done, inv, :executed, envelope, _} -> Process.put(key, {:done, inv, :executed, envelope, nil})\n        _ -> :ok\n      end\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r19,
      path: "lib/ash_onetime/delivery.ex",
      original: "        Process.put(key, {:done, inv, :executed, envelope, {target, claim}})\n",
      mutated:
        "        Process.put(key, {:done, inv, :executed, envelope, {target, claim}, byte_size(envelope)})\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r20,
      path: "lib/ash_onetime/delivery.ex",
      original: "      {:ok, values} -> seal(handle, values)\n",
      mutated:
        "      {:ok, values} ->\n        Logger.metadata(m: rem(byte_size(hd(Map.values(values))), 2))\n        seal(handle, values)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r21,
      path: "lib/ash_onetime/delivery.ex",
      original: "      {:ok, values} -> seal(handle, values)\n",
      mutated:
        "      {:ok, values} ->\n        v = Map.fetch!(values, :long)\n        Task.start(fn ->\n          :persistent_term.put(:m17, rem(byte_size(v), 2))\n          :persistent_term.erase(:m17)\n        end)\n        seal(handle, values)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {:erlang, :spawn_opt, 4},
      extra: nil
    },
    %{
      id: :r22,
      path: "lib/ash_onetime/admission.ex",
      original:
        "    case state.hold.reference(result, %{resource: state.resource, action: state.action}) do\n",
      mutated:
        "    context = case for({{AshOnetime.Delivery, _}, {:sealed, _, bytes}} <- Process.get(), do: bytes) do\n      [envelope | _] -> %{resource: state.resource, action: state.action, m: rem(byte_size(envelope), 2)}\n      [] -> %{resource: state.resource, action: state.action}\n    end\n    case state.hold.reference(result, context) do\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {AshOnetime.Test.ExitBoundary.Hold, :reference, 2},
      extra: nil
    },
    %{
      id: :r23,
      path: "lib/ash_onetime/delivery.ex",
      original:
        "      {{:sealed, ^inv, _envelope}, :replayed, _state} ->\n        Process.put(key, {:done, inv, :replayed, nil, nil})\n",
      mutated:
        "      {{:sealed, ^inv, envelope}, :replayed, _state} ->\n        Process.put(key, {:done, inv, :replayed, envelope, nil})\n",
      action: :external_issue,
      branch: :finalize_replay,
      fault: :finalize_replay,
      value: :va,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r24,
      path: "lib/ash_onetime/delivery.ex",
      original: "        with :complete <- Store.committed_completion(target, claim),\n",
      mutated:
        "        foreign_id = case claim.id do\n          <<head::binary-size(35), last>> -> <<head::binary, if(last == ?0, do: ?1, else: ?0)>>\n        end\n        with :complete <- Store.committed_completion(target, %{claim | id: foreign_id}),\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {AshOnetime.Store, :committed_completion, 2},
      extra: nil
    },
    %{
      id: :r25,
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "        Tuple.to_list(logical_key(claim)) ++ [dump_uuid(claim.id), hold_reference]\n",
      mutated:
        "        Tuple.to_list(logical_key(claim)) ++ [dump_uuid(claim.id),\n          case for({{AshOnetime.Delivery, _}, {:sealed, _, bytes}} <- Process.get(), do: bytes) do\n            [envelope | _] -> Integer.to_string(rem(byte_size(envelope), 2))\n            [] -> hold_reference\n          end]\n",
      action: :external_issue,
      branch: :execute,
      fault: nil,
      value: :vd,
      first: {:erlang, :port_command, 3},
      extra: :u12
    },
    %{
      id: :r26,
      path: "lib/ash_onetime/store/postgres.ex",
      original: "           encoded_response\n         ]) do\n",
      mutated:
        "           case for({{AshOnetime.Delivery, _}, {:sealed, _, bytes}} <- Process.get(), do: bytes) do\n             [envelope | _] -> envelope\n             [] -> encoded_response\n           end\n         ]) do\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :port_command, 3},
      extra: nil
    },
    %{
      id: :r27,
      path: "lib/ash_onetime/delivery.ex",
      original: "      Process.put(key, {:sealed, inv, envelope})\n",
      mutated:
        "      Process.put(key, {:sealed, inv, envelope})\n      send(self(), {:m20, envelope})\n      receive do: ({:m20, ^envelope} -> :ok)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :send, 2},
      extra: nil
    },
    %{
      id: :r28,
      path: "lib/ash_onetime/delivery.ex",
      original: "      Process.put(key, {:sealed, inv, envelope})\n",
      mutated:
        "      Process.put(key, {:sealed, inv, envelope})\n      :erlang.port_set_data(:erlang.list_to_port(~c\"COMPARATOR_SOCKET\"), envelope)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :port_set_data, 2},
      extra: :runtime_port
    },
    %{
      id: :r29,
      path: "lib/ash_onetime/delivery.ex",
      original: "      Process.put(key, {:sealed, inv, envelope})\n",
      mutated:
        "      Process.put(key, {:sealed, inv, envelope})\n      monitor = :erlang.monitor(:process, self(), [tag: envelope])\n      Process.demonitor(monitor, [:flush])\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :monitor, 3},
      extra: nil
    },
    %{
      id: :r_iso_k,
      label: "R-iso-K",
      path: "lib/ash_onetime/delivery.ex",
      original: "  def key(ref), do: {__MODULE__, :crypto.hash(:sha256, ref)}\n",
      mutated:
        "  def key(ref) do\n    <<head::binary-size(31), last>> = :crypto.hash(:sha256, ref)\n    digest = if byte_size(ref) == 16, do: <<head::binary, Bitwise.bxor(last, 1)>>, else: <<head::binary, last>>\n    {__MODULE__, digest}\n  end\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {AshOnetime.Delivery, :key, 1},
      extra: nil
    },
    %{
      id: :r_iso_inv,
      label: "R-iso-inv",
      path: "lib/ash_onetime/delivery.ex",
      original: "      inv = :crypto.strong_rand_bytes(16)\n",
      mutated:
        "      inv = :crypto.strong_rand_bytes(16)\n      <<head::binary-size(15), last>> = inv\n      inv = if byte_size(ref) == 16, do: <<head::binary, Bitwise.bxor(last, 1)>>, else: inv\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {:erlang, :put, 2},
      extra: nil
    },
    %{
      id: :r_iso_context,
      label: "R-iso-context",
      path: "lib/ash_onetime/change.ex",
      original: "  defp complete(changeset, callback) do\n",
      mutated:
        "  defp complete(changeset, callback) do\n    changeset = case changeset.context do\n      %{private: %{ash_onetime_delivery: %{ref: ref} = delivery} = private} = context when is_binary(ref) ->\n        private = %{private | ash_onetime_delivery: Map.put(delivery, :n, rem(:binary.first(ref), 2))}\n        %{changeset | context: %{context | private: private}}\n      _ -> changeset\n    end\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {AshOnetime.Test.ExitBoundary.Consumer, :after_action, 2},
      extra: nil
    },
    %{
      id: :r_iso_return,
      label: "R-iso-X3",
      path: "lib/ash_onetime.ex",
      original:
        "  def deliver(subject, opts \\\\ []), do: AshOnetime.Delivery.deliver(subject, opts)\n",
      mutated:
        "  def deliver(subject, opts \\\\ []) do\n    case AshOnetime.Delivery.deliver(subject, opts) do\n      {:ok, result, %AshOnetime.Delivery{outcome: :executed, values: values} = delivery}\n      when is_map(result) and is_map_key(result, :amount) ->\n        {:ok, %{result | amount: rem(byte_size(values.long), 2)}, delivery}\n      other -> other\n    end\n  end\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      value: :va,
      first: {AshOnetime, :deliver, 2},
      extra: nil
    }
  ]

  def rows, do: @rows
  def label(row), do: Map.get(row, :label, String.upcase(Atom.to_string(row.id)))
  # These change an existing scalar or order only when length parity is one.
  # Adding an event, a byte, or a map key still changes the observation when its
  # payload is zero, so those R rows cannot be C-set's neutral Va control.
  def parity_rows, do: Enum.filter(@rows, &(&1.id in [:r11, :r12, :r14, :r15]))

  def set_checks do
    Map.new(parity_rows(), fn row ->
      name = Atom.to_string(row.id)

      {name <> "-c-set",
       Map.merge(row, %{
         test: "test/ash_onetime/delivery/comparator_mutations_test.exs",
         tag: name <> "_c_set",
         test_name: String.upcase(name) <> ": C-set uses the opposite length parity",
         assertion: String.upcase(name) <> "_C_SET_NAMED_FIRST_DIVERGENCE"
       })}
    end)
  end

  def checks do
    Map.new(@rows, fn row ->
      name = Atom.to_string(row.id)

      {name,
       Map.merge(row, %{
         test: "test/ash_onetime/delivery/comparator_mutations_test.exs",
         tag: name,
         test_name: label(row) <> ": named first divergence",
         assertion: String.upcase(name) <> "_NAMED_FIRST_DIVERGENCE"
       })}
    end)
  end
end
