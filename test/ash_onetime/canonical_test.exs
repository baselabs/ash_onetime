defmodule AshOnetime.CanonicalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshOnetime.Canonical
  alias AshOnetime.Canonical.Decoder
  alias AshOnetime.Error

  @max_integer Integer.pow(2, 255) - 1

  @tag :canonical_mutation
  test "integer encoding uses its distinct pinned domain tag" do
    assert {:ok, <<0x02, 0, 0, 0, 1, "1">>} = Canonical.encode(1)
    assert {:ok, <<0x03, 0, 0, 0, 1, "1">>} = Canonical.encode("1")
  end

  property "type tags keep scalar domains distinct" do
    check all({left, right} <- distinct_scalar_pair()) do
      assert {:ok, left_bytes} = Canonical.encode(left)
      assert {:ok, right_bytes} = Canonical.encode(right)
      refute left_bytes == right_bytes
    end
  end

  @tag :canonical_order_mutation
  property "map encoding follows independently sorted encoded keys" do
    check all(left <- integer(), right <- integer()) do
      value = %{"bb" => left, "a" => right}
      expected = independently_encoded_map!(value)

      assert {:ok, ^expected} = Canonical.encode(value)
    end
  end

  test "map entries sort by complete encoded key bytes" do
    assert {:ok, encoded} = Canonical.encode(%{"bb" => 2, "a" => 1})

    assert encoded ==
             <<0x06, 0, 0, 0, 29, 0, 0, 0, 2, 0x03, 0, 0, 0, 1, "a", 0x02, 0, 0, 0, 1, "1", 0x03,
               0, 0, 0, 2, "bb", 0x02, 0, 0, 0, 1, "2">>
  end

  defp independently_encoded_map!(value) do
    entries =
      value
      |> Enum.map(fn {key, item} ->
        {:ok, encoded_key} = Canonical.encode(key)
        {:ok, encoded_item} = Canonical.encode(item)
        {encoded_key, encoded_item}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    payload =
      IO.iodata_to_binary([
        <<map_size(value)::unsigned-big-32>>,
        Enum.map(entries, fn {key, item} -> [key, item] end)
      ])

    <<0x06, byte_size(payload)::unsigned-big-32, payload::binary>>
  end

  property "integer magnitude is bounded on both signs" do
    check all(excess <- integer(1..1_000_000)) do
      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :integer_magnitude}}} =
               Canonical.encode(@max_integer + excess)

      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :integer_magnitude}}} =
               Canonical.encode(-@max_integer - excess)
    end
  end

  test "integer magnitude accepts both exact edges" do
    assert {:ok, _encoded} = Canonical.encode(@max_integer)
    assert {:ok, _encoded} = Canonical.encode(-@max_integer)
  end

  property "per-container count rejects every generated excess" do
    check all(excess <- integer(1..32), container <- member_of([:list, :map])) do
      count = 256 + excess

      value =
        case container do
          :list -> Enum.to_list(1..count)
          :map -> Map.new(1..count, &{&1, nil})
        end

      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :container_items}}} =
               Canonical.encode(value)
    end
  end

  property "total recursive count rejects generated excesses" do
    check all(excess <- integer(1..9)) do
      value =
        List.duplicate(List.duplicate(nil, 256), 7) ++
          [List.duplicate(nil, 247 + excess)]

      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :total_values}}} =
               Canonical.encode(value)
    end
  end

  test "container and total recursive count accept exact edges" do
    assert {:ok, _encoded} = Canonical.encode(List.duplicate(nil, 256))
    assert {:ok, _encoded} = Canonical.encode(Map.new(1..256, &{&1, nil}))

    exact_total =
      List.duplicate(List.duplicate(nil, 256), 7) ++ [List.duplicate(nil, 247)]

    assert {:ok, _encoded} = Canonical.encode(exact_total)
  end

  property "depth rejects every generated excess" do
    check all(excess <- integer(1..8)) do
      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :depth}}} =
               Canonical.encode(nest(:value, 16 + excess))
    end
  end

  test "depth accepts the exact edge" do
    assert {:ok, _encoded} = Canonical.encode(nest(:value, 16))
  end

  property "individual binary bytes reject every generated excess" do
    check all(excess <- integer(1..256)) do
      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :binary_bytes}}} =
               Canonical.encode(:binary.copy(<<0>>, 16_384 + excess))
    end
  end

  property "aggregate encoded bytes reject generated over-limit values" do
    check all(chunk_size <- integer(16_377..16_384)) do
      value = List.duplicate(:binary.copy(<<0>>, chunk_size), 4)

      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :encoded_bytes}}} =
               Canonical.encode(value)
    end
  end

  test "binary and encoded byte limits accept their exact edges" do
    assert {:ok, _encoded} = Canonical.encode(:binary.copy(<<0>>, 16_384))

    exact =
      List.duplicate(:binary.copy(<<0>>, 16_384), 3) ++
        [:binary.copy(<<0>>, 16_355)]

    one_over =
      List.duplicate(:binary.copy(<<0>>, 16_384), 3) ++
        [:binary.copy(<<0>>, 16_356)]

    assert {:ok, encoded} = Canonical.encode(exact)
    assert byte_size(encoded) == 65_536

    assert {:error, %Error{code: :limit_exceeded, details: %{limit: :encoded_bytes}}} =
             Canonical.encode(one_over)
  end

  property "unsupported terms remain rejected inside generated containers" do
    check all(unsupported <- unsupported_term(), wrappers <- wrappers()) do
      nested = Enum.reduce(wrappers, unsupported, &wrap/2)

      assert {:error, %Error{code: :unsupported_term}} = Canonical.encode(nested)
    end
  end

  property "unsupported terms remain rejected as generated map keys" do
    check all(unsupported <- unsupported_term()) do
      assert {:error, %Error{code: :unsupported_term}} =
               Canonical.encode(%{unsupported => "value"})
    end
  end

  property "mixed list and map nesting rejects depth excess" do
    check all(wrappers <- list_of(member_of([:list, :map]), length: 17)) do
      nested = Enum.reduce(wrappers, :value, &wrap/2)

      assert {:error, %Error{code: :limit_exceeded, details: %{limit: :depth}}} =
               Canonical.encode(nested)
    end
  end

  test "structs and improper lists reject without raising at every nesting" do
    for unsupported <- [%URI{scheme: "https"}, [1 | 2]] do
      assert {:error, %Error{code: :unsupported_term}} = Canonical.encode(unsupported)

      assert {:error, %Error{code: :unsupported_term}} =
               Canonical.encode(%{"outer" => [unsupported]})
    end
  end

  @tag :canonical_decoder_identity_mutation
  test "decoder rejects trailing, duplicate, and noncanonical map bytes" do
    assert {:ok, canonical} = Canonical.encode(%{"a" => 1, "b" => 2})
    assert {:ok, %{"a" => 1, "b" => 2}} = Decoder.decode(canonical)

    assert {:error, %Error{code: :invalid_encoding}} = Decoder.decode(canonical <> <<0>>)

    [first, second] = map_entries(canonical)
    duplicate = map_encoding([first, second, first])
    reversed = map_encoding([second, first])

    assert {:error, %Error{code: :duplicate_map_key}} = Decoder.decode(duplicate)
    assert {:error, %Error{code: :noncanonical_encoding}} = Decoder.decode(reversed)
  end

  property "the decoder is a total inverse of the encoder over in-algebra values" do
    check all(value <- canonical_value()) do
      assert {:ok, encoded} = Canonical.encode(value)
      assert {:ok, decoded} = Decoder.decode(encoded)
      assert decoded == value
    end
  end

  property "the decoder accepts only an exact canonical encoding (non-malleable)" do
    # The decoder is the anti-malleability boundary on the token verify path: it re-encodes what
    # it decoded and demands byte-identity. So a flipped byte must either fail to decode, or land
    # on the canonical encoding of some value and decode to exactly that — never accept a
    # NON-canonical encoding. (A flip that turns `true`→`false` or `1`→`2` is a different but still
    # canonical encoding; the signature, not the decoder, rejects the value change.)
    check all(
            value <- canonical_value(),
            index <- integer(0..4096),
            xor <- integer(1..255)
          ) do
      assert {:ok, encoded} = Canonical.encode(value)
      mutated = mutate_byte(encoded, rem(index, byte_size(encoded)), xor)

      case Decoder.decode(mutated) do
        {:ok, decoded} -> assert Canonical.encode(decoded) == {:ok, mutated}
        {:error, %Error{}} -> :ok
      end
    end
  end

  @tag :canonical_surface_mutation
  test "canonical public surface does not export decoding" do
    Code.ensure_loaded!(Canonical)
    refute function_exported?(Canonical, :decode, 1)
  end

  @tag :canonical_decoder_docs_mutation
  test "canonical decoder module stays hidden from public documentation" do
    Code.ensure_loaded!(Decoder)
    assert :hidden = decoder_moduledoc()
  end

  defp distinct_scalar_pair do
    one_of([
      StreamData.map(integer(-1_000_000..1_000_000), &{&1, Integer.to_string(&1)}),
      StreamData.map(member_of([:alpha, :beta, :gamma]), &{&1, Atom.to_string(&1)}),
      constant({nil, false}),
      constant({false, 0}),
      constant({<<>>, []}),
      constant({[], %{}})
    ])
  end

  defp canonical_value, do: canonical_value(0)

  defp canonical_value(depth) when depth >= 3, do: canonical_scalar()

  defp canonical_value(depth) do
    one_of([
      canonical_scalar(),
      list_of(canonical_value(depth + 1), max_length: 3),
      map_of(canonical_scalar(), canonical_value(depth + 1), max_length: 3)
    ])
  end

  defp canonical_scalar do
    one_of([
      constant(nil),
      boolean(),
      integer(-100_000..100_000),
      string(:alphanumeric, max_length: 8),
      # decode uses String.to_existing_atom, so the generated atoms must already exist
      member_of([:alpha, :beta, :gamma, :ok, :error])
    ])
  end

  defp mutate_byte(binary, index, xor) do
    <<prefix::binary-size(^index), byte, suffix::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, xor)::8, suffix::binary>>
  end

  defp decoder_moduledoc do
    case Code.fetch_docs(Decoder) do
      {:docs_v1, _annotation, _language, _format, moduledoc, _metadata, _docs} -> moduledoc
      other -> other
    end
  end

  defp unsupported_term do
    one_of([
      constant(1.0),
      constant({1, 2}),
      constant(%URI{scheme: "https"}),
      constant([1 | 2])
    ])
  end

  defp wrappers, do: list_of(member_of([:list, :map]), min_length: 1, max_length: 8)

  defp wrap(:list, value), do: [value]
  defp wrap(:map, value), do: %{"nested" => value}

  defp nest(value, 0), do: value
  defp nest(value, depth), do: [nest(value, depth - 1)]

  defp map_entries(<<0x06, payload_size::32, payload::binary-size(payload_size)>>) do
    <<count::32, entries::binary>> = payload
    take_entries(entries, count, [])
  end

  defp take_entries(<<>>, 0, entries), do: Enum.reverse(entries)

  defp take_entries(binary, count, entries) do
    {key, rest} = take_frame(binary)
    {value, tail} = take_frame(rest)
    take_entries(tail, count - 1, [key <> value | entries])
  end

  defp take_frame(<<_tag, size::32, _payload::binary-size(size), _rest::binary>> = binary) do
    frame_size = size + 5
    <<frame::binary-size(^frame_size), rest::binary>> = binary
    {frame, rest}
  end

  defp map_encoding(entries) do
    payload = [<<length(entries)::32>>, entries] |> IO.iodata_to_binary()
    <<0x06, byte_size(payload)::32, payload::binary>>
  end
end
