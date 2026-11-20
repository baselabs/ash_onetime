defmodule AshOnetime.Canonical do
  @moduledoc """
  Bounded, deterministic encoding for an explicit closed value algebra.

  Accepted values are `nil`, booleans, bounded integers, bounded binaries,
  atoms, proper lists, and non-struct maps recursively containing only those
  values. Floats, tuples, structs, improper lists, PIDs, ports, references, and
  functions are deliberately outside the algebra and return a typed error.

  Every value has a pinned domain tag and a 32-bit byte length. Containers also
  carry a 32-bit item count. Map entries are ordered by the complete encoded key
  bytes, making construction order irrelevant.
  """

  alias AshOnetime.Error

  @nil_tag 0x00
  @boolean_tag 0x01
  @integer_tag 0x02
  @binary_tag 0x03
  @atom_tag 0x04
  @list_tag 0x05
  @map_tag 0x06

  @max_integer Integer.pow(2, 255) - 1
  @max_binary_bytes 16_384
  @max_container_items 256
  @max_total_values 2_048
  @max_depth 16
  @max_encoded_bytes 65_536
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

  @max_integer Integer.pow(2, 255) - 1
  @max_binary_bytes 16_384
  @max_container_items 256
  @max_total_values 2_048
  @max_depth 16
  @max_encoded_bytes 65_536

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
