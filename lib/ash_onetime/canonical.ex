defmodule AshOnetime.Canonical do
  @moduledoc """
  Bounded, deterministic encoding for an explicit closed value algebra.

  Accepted values are `nil`, booleans, bounded integers, bounded binaries,
  atoms, proper lists, and non-struct maps recursively containing only those
  values. Floats, tuples, structs, improper lists, PIDs, ports, references, and
  functions are deliberately outside the algebra and return a typed error.

  `AshOnetime.Fingerprint` is SHA-256 over these bytes. Token bodies are signed over them.

  ## Format 1

  `format/0` returns `1`. Format 1 bytes never change: the same value always encodes to
  the same bytes in every release. A different encoding is a new format with a new number.

  Every value is one frame: a one-byte domain tag, a 32-bit unsigned big-endian payload
  length, then the payload.

  | Tag    | Value     | Payload                                                     |
  | ------ | --------- | ----------------------------------------------------------- |
  | `0x00` | `nil`     | empty                                                       |
  | `0x01` | boolean   | one byte: `0x01` for `true`, `0x00` for `false`             |
  | `0x02` | integer   | decimal ASCII, `-` for negatives, no leading zeros or `+`   |
  | `0x03` | binary    | the bytes                                                   |
  | `0x04` | atom      | the atom's UTF-8 name                                       |
  | `0x05` | list      | 32-bit item count, then each item's frame in list order     |
  | `0x06` | map       | 32-bit entry count, then key frame and value frame per entry |

  Map entries are ordered by the complete encoded key bytes compared as unsigned bytes, so
  construction order is irrelevant. Keys of different types order by tag; a shorter binary
  key orders before a longer one because the length precedes the bytes. Distinct keys
  always encode to distinct bytes.

  ## Bounds

  `bounds/0` returns the limits. A value outside them returns
  `{:error, %AshOnetime.Error{code: :limit_exceeded, details: %{limit: limit, maximum: maximum}}}`,
  where `limit` is the key below.

  | Limit                | Maximum           | Counts                                        |
  | -------------------- | ----------------- | --------------------------------------------- |
  | `:integer_magnitude` | 2^255 - 1         | absolute value of one integer                 |
  | `:binary_bytes`      | 16,384            | bytes in one binary                           |
  | `:container_items`   | 256               | items in one list or entries in one map       |
  | `:total_values`      | 2,048             | every value, containers and map keys included |
  | `:depth`             | 16                | containers enclosing the deepest value        |
  | `:encoded_bytes`     | 65,536            | bytes of the complete encoding                |

  ## Vectors

  The package ships `priv/vectors/canonical-1.json`
  (`Application.app_dir(:ash_onetime, "priv/vectors/canonical-1.json")`). It holds values
  with their format 1 bytes and SHA-256 fingerprints, values each bound rejects, and byte
  strings a decoder must refuse. The file is immutable: format 1 vectors are only ever
  added in a new file. An implementation in another language conforms when it produces
  every accepted encoding and refuses every rejection.
  """

  alias AshOnetime.Error

  @nil_tag 0x00
  @boolean_tag 0x01
  @integer_tag 0x02
  @binary_tag 0x03
  @atom_tag 0x04
  @list_tag 0x05
  @map_tag 0x06

  @format 1

  @bounds %{
    integer_magnitude: Integer.pow(2, 255) - 1,
    binary_bytes: 16_384,
    container_items: 256,
    total_values: 2_048,
    depth: 16,
    encoded_bytes: 65_536
  }

  @max_integer @bounds.integer_magnitude
  @max_binary_bytes @bounds.binary_bytes
  @max_container_items @bounds.container_items
  @max_total_values @bounds.total_values
  @max_depth @bounds.depth
  @max_encoded_bytes @bounds.encoded_bytes
  @frame_header_bytes 5
  @container_count_bytes 4

  @type value ::
          nil
          | boolean()
          | integer()
          | binary()
          | atom()
          | [value()]
          | %{optional(value()) => value()}

  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @type bounds :: %{
          integer_magnitude: pos_integer(),
          binary_bytes: pos_integer(),
          container_items: pos_integer(),
          total_values: pos_integer(),
          depth: pos_integer(),
          encoded_bytes: pos_integer()
        }

  @doc "Returns the format number of the bytes `encode/1` produces."
  @spec format() :: 1
  def format, do: @format

  @doc "Returns the bounds `encode/1` enforces, keyed by the `:limit` its errors name."
  @spec bounds() :: bounds()
  def bounds, do: @bounds

  @doc """
  Encodes `value` to its format 1 bytes, or returns a `:limit_exceeded` or
  `:unsupported_term` error.
  """
  @spec encode(term()) :: result(binary())
  def encode(value) do
    case encode_value(value, 0, %{values: 0, bytes: 0}) do
      {:ok, encoded, _state} -> {:ok, encoded}
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _exception -> {:error, unsupported_error()}
  catch
    _kind, _reason -> {:error, unsupported_error()}
  end

  defp encode_value(_value, depth, _state) when depth > @max_depth,
    do: {:error, limit_error(:depth, @max_depth)}

  defp encode_value(nil, _depth, state), do: encode_scalar(@nil_tag, <<>>, state)

  defp encode_value(value, _depth, state) when is_boolean(value) do
    payload = if value, do: <<1>>, else: <<0>>
    encode_scalar(@boolean_tag, payload, state)
  end

  defp encode_value(value, _depth, state) when is_integer(value) do
    if abs(value) <= @max_integer do
      encode_scalar(@integer_tag, Integer.to_string(value), state)
    else
      {:error, limit_error(:integer_magnitude, @max_integer)}
    end
  end

  defp encode_value(value, _depth, state) when is_binary(value) do
    if byte_size(value) <= @max_binary_bytes do
      encode_scalar(@binary_tag, value, state)
    else
      {:error, limit_error(:binary_bytes, @max_binary_bytes)}
    end
  end

  defp encode_value(value, _depth, state) when is_atom(value),
    do: encode_scalar(@atom_tag, Atom.to_string(value), state)

  defp encode_value(%_{} = _value, _depth, _state), do: {:error, unsupported_error()}

  defp encode_value(value, depth, state) when is_list(value) do
    with {:ok, count} <- proper_list_length(value),
         :ok <- check_container_count(count),
         {:ok, state} <- add_value(state, @frame_header_bytes + @container_count_bytes),
         {:ok, entries, state} <- encode_list(value, depth + 1, state, []) do
      payload = [<<count::unsigned-big-32>>, Enum.reverse(entries)] |> IO.iodata_to_binary()
      {:ok, frame(@list_tag, payload), state}
    end
  end

  defp encode_value(value, depth, state) when is_map(value) do
    count = map_size(value)

    with :ok <- check_container_count(count),
         {:ok, state} <- add_value(state, @frame_header_bytes + @container_count_bytes),
         {:ok, entries, state} <- encode_map(Map.to_list(value), depth + 1, state, []) do
      ordered = Enum.sort_by(entries, &elem(&1, 0))

      payload =
        [<<count::unsigned-big-32>>, Enum.map(ordered, fn {key, item} -> [key, item] end)]
        |> IO.iodata_to_binary()

      {:ok, frame(@map_tag, payload), state}
    end
  end

  defp encode_value(_value, _depth, _state), do: {:error, unsupported_error()}

  defp encode_scalar(tag, payload, state) do
    with {:ok, state} <- add_value(state, @frame_header_bytes + byte_size(payload)) do
      {:ok, frame(tag, payload), state}
    end
  end

  defp encode_list([], _depth, state, encoded), do: {:ok, encoded, state}

  defp encode_list([value | rest], depth, state, encoded) do
    with {:ok, bytes, state} <- encode_value(value, depth, state) do
      encode_list(rest, depth, state, [bytes | encoded])
    end
  end

  defp encode_map([], _depth, state, encoded), do: {:ok, encoded, state}

  defp encode_map([{key, value} | rest], depth, state, encoded) do
    with {:ok, key_bytes, state} <- encode_value(key, depth, state),
         {:ok, value_bytes, state} <- encode_value(value, depth, state) do
      encode_map(rest, depth, state, [{key_bytes, value_bytes} | encoded])
    end
  end

  defp proper_list_length(value), do: proper_list_length(value, 0)
  defp proper_list_length([], count), do: {:ok, count}

  defp proper_list_length([_head | tail], count) when count < @max_container_items,
    do: proper_list_length(tail, count + 1)

  defp proper_list_length([_head | _tail], @max_container_items),
    do: {:error, limit_error(:container_items, @max_container_items)}

  defp proper_list_length(_improper_tail, _count), do: {:error, unsupported_error()}

  defp check_container_count(count) when count <= @max_container_items, do: :ok

  defp check_container_count(_count),
    do: {:error, limit_error(:container_items, @max_container_items)}

  defp add_value(%{values: values, bytes: bytes} = state, added_bytes) do
    cond do
      values + 1 > @max_total_values ->
        {:error, limit_error(:total_values, @max_total_values)}

      bytes + added_bytes > @max_encoded_bytes ->
        {:error, limit_error(:encoded_bytes, @max_encoded_bytes)}

      true ->
        {:ok, %{state | values: values + 1, bytes: bytes + added_bytes}}
    end
  end

  defp frame(tag, payload),
    do: <<tag, byte_size(payload)::unsigned-big-32, payload::binary>>

  defp limit_error(limit, maximum),
    do:
      Error.new(:limit_exceeded, "canonical value exceeds a bounded limit", %{
        limit: limit,
        maximum: maximum
      })

  defp unsupported_error,
    do: Error.new(:unsupported_term, "value is outside the canonical algebra")
end

defmodule AshOnetime.Canonical.Decoder do
  @moduledoc false

  alias AshOnetime.Canonical
  alias AshOnetime.Error

  @decode_nil_tag 0x00
  @decode_boolean_tag 0x01
  @decode_integer_tag 0x02
  @decode_binary_tag 0x03
  @decode_atom_tag 0x04
  @decode_list_tag 0x05
  @decode_map_tag 0x06

  @bounds Canonical.bounds()
  @max_integer @bounds.integer_magnitude
  @max_binary_bytes @bounds.binary_bytes
  @max_container_items @bounds.container_items
  @max_total_values @bounds.total_values
  @max_depth @bounds.depth
  @max_encoded_bytes @bounds.encoded_bytes

  @spec decode(binary()) :: {:ok, Canonical.value()} | {:error, Error.t()}
  def decode(encoded) when is_binary(encoded) and byte_size(encoded) <= @max_encoded_bytes do
    with {:ok, value, raw, <<>>, _state} <- decode_frame(encoded, 0, %{values: 0}),
         true <- raw == encoded,
         {:ok, ^encoded} <- Canonical.encode(value) do
      {:ok, value}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_encoding, "canonical bytes are invalid")}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_encoding, "canonical bytes are invalid")}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_encoding, "canonical bytes are invalid")}
  end

  def decode(encoded) when is_binary(encoded),
    do: {:error, limit_error(:encoded_bytes, @max_encoded_bytes)}

  def decode(_encoded),
    do: {:error, Error.new(:invalid_encoding, "canonical input must be bytes")}

  defp decode_frame(_encoded, depth, _state) when depth > @max_depth,
    do: {:error, limit_error(:depth, @max_depth)}

  defp decode_frame(<<tag, size::unsigned-big-32, rest::binary>>, depth, state)
       when byte_size(rest) >= size do
    <<payload::binary-size(^size), tail::binary>> = rest
    raw = <<tag, size::unsigned-big-32, payload::binary>>

    with {:ok, state} <- add_decoded_value(state),
         {:ok, value, state} <- decode_payload(tag, payload, depth, state) do
      {:ok, value, raw, tail, state}
    end
  end

  defp decode_frame(_encoded, _depth, _state),
    do: {:error, Error.new(:invalid_encoding, "canonical frame is truncated")}

  defp decode_payload(@decode_nil_tag, <<>>, _depth, state), do: {:ok, nil, state}
  defp decode_payload(@decode_boolean_tag, <<0>>, _depth, state), do: {:ok, false, state}
  defp decode_payload(@decode_boolean_tag, <<1>>, _depth, state), do: {:ok, true, state}

  defp decode_payload(@decode_integer_tag, payload, _depth, state) do
    case Integer.parse(payload) do
      {integer, ""} when abs(integer) <= @max_integer ->
        if Integer.to_string(integer) == payload do
          {:ok, integer, state}
        else
          {:error, Error.new(:invalid_encoding, "integer payload is not canonical")}
        end

      _other ->
        {:error, Error.new(:invalid_encoding, "integer payload is not canonical")}
    end
  end

  defp decode_payload(@decode_binary_tag, payload, _depth, state) do
    if byte_size(payload) <= @max_binary_bytes do
      {:ok, payload, state}
    else
      {:error, limit_error(:binary_bytes, @max_binary_bytes)}
    end
  end

  defp decode_payload(@decode_atom_tag, payload, _depth, state) do
    atom = String.to_existing_atom(payload)

    if Atom.to_string(atom) == payload do
      {:ok, atom, state}
    else
      {:error, Error.new(:invalid_encoding, "atom payload is not canonical")}
    end
  rescue
    ArgumentError -> {:error, Error.new(:invalid_encoding, "atom is not already loaded")}
  end

  defp decode_payload(
         @decode_list_tag,
         <<count::unsigned-big-32, entries::binary>>,
         depth,
         state
       ) do
    with :ok <- check_container_count(count),
         {:ok, values, <<>>, state} <- decode_list(entries, count, depth + 1, state, []) do
      {:ok, Enum.reverse(values), state}
    else
      {:ok, _values, _tail, _state} ->
        {:error, Error.new(:invalid_encoding, "list payload has trailing bytes")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp decode_payload(
         @decode_map_tag,
         <<count::unsigned-big-32, entries::binary>>,
         depth,
         state
       ) do
    with :ok <- check_container_count(count),
         {:ok, value, <<>>, state} <-
           decode_map(entries, count, depth + 1, state, nil, %{}, %{}) do
      {:ok, value, state}
    else
      {:ok, _value, _tail, _state} ->
        {:error, Error.new(:invalid_encoding, "map payload has trailing bytes")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp decode_payload(_tag, _payload, _depth, _state),
    do: {:error, Error.new(:invalid_encoding, "canonical tag or payload is invalid")}

  defp decode_list(entries, 0, _depth, state, values),
    do: {:ok, values, entries, state}

  defp decode_list(entries, count, depth, state, values) do
    with {:ok, value, _raw, rest, state} <- decode_frame(entries, depth, state) do
      decode_list(rest, count - 1, depth, state, [value | values])
    end
  end

  defp decode_map(entries, 0, _depth, state, _previous, _seen, value),
    do: {:ok, value, entries, state}

  defp decode_map(entries, count, depth, state, previous, seen, value) do
    with {:ok, key, key_raw, after_key, state} <- decode_frame(entries, depth, state),
         :ok <- check_map_key(key_raw, previous, seen),
         {:ok, item, _item_raw, rest, state} <- decode_frame(after_key, depth, state) do
      decode_map(
        rest,
        count - 1,
        depth,
        state,
        key_raw,
        Map.put(seen, key_raw, true),
        Map.put(value, key, item)
      )
    end
  end

  defp check_map_key(key_raw, previous, seen) do
    cond do
      Map.has_key?(seen, key_raw) ->
        {:error, Error.new(:duplicate_map_key, "canonical map contains a duplicate key")}

      is_nil(previous) or key_raw > previous ->
        :ok

      true ->
        {:error, Error.new(:noncanonical_encoding, "canonical map keys are out of order")}
    end
  end

  defp add_decoded_value(%{values: values} = state) when values < @max_total_values,
    do: {:ok, %{state | values: values + 1}}

  defp add_decoded_value(_state),
    do: {:error, limit_error(:total_values, @max_total_values)}

  defp check_container_count(count) when count <= @max_container_items, do: :ok

  defp check_container_count(_count),
    do: {:error, limit_error(:container_items, @max_container_items)}

  defp limit_error(limit, maximum),
    do:
      Error.new(:limit_exceeded, "canonical value exceeds a bounded limit", %{
        limit: limit,
        maximum: maximum
      })
end
