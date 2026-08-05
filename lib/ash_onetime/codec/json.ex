defmodule AshOnetime.Codec.JSON do
  @moduledoc """
  Typed JSON response codec.
  """

  @behaviour AshOnetime.Codec

  alias AshOnetime.{Codec, Error}

  @tag "json"
  @envelope_keys MapSet.new(["adapter", "contract", "shape", "value"])

  @impl true
  def format_tag, do: @tag

  @impl true
  def encode(value, contract, opts) do
    case adapter(contract) do
      {:ok, adapter} -> adapter.encode_envelope(value, contract, @tag, opts)
      error -> error
    end
  end

  @impl true
  def decode(@tag, payload, contract, opts) do
    case adapter(contract) do
      {:ok, adapter} -> adapter.decode_envelope(@tag, payload, contract, @tag, opts)
      error -> error
    end
  end

  def decode(_tag, _payload, _contract, _opts) do
    {:error, Error.new(:response_codec_mismatch, "response codec tag does not match")}
  end

  @doc false
  def pack(adapter, shape, value, contract) do
    envelope = %{
      "adapter" => adapter,
      "contract" => Base.url_encode64(contract.digest, padding: false),
      "shape" => shape,
      "value" => value
    }

    with :ok <- Codec.validate_value(envelope, contract, :payload),
         {:ok, payload} <- Jason.encode(envelope) do
      if byte_size(payload) <= Codec.max_bytes(contract) and json_preflight?(payload, contract) do
        {:ok, payload}
      else
        {:error, Error.new(:response_payload_invalid, "response JSON could not be encoded")}
      end
    else
      _other ->
        {:error, Error.new(:response_payload_invalid, "response JSON could not be encoded")}
    end
  end

  @doc false
  def unpack(payload, adapter, shape, contract)
      when is_binary(payload) and byte_size(payload) > 0 do
    with true <- byte_size(payload) <= Codec.max_bytes(contract),
         true <- json_preflight?(payload, contract),
         {:ok, decoded} <- Jason.decode(payload, objects: :ordered_objects),
         {:ok, envelope} <- normalize(decoded, 0),
         :ok <- Codec.validate_value(envelope, contract, :payload),
         true <-
           is_map(envelope) and MapSet.equal?(MapSet.new(Map.keys(envelope)), @envelope_keys),
         true <- envelope["adapter"] == adapter,
         true <- envelope["shape"] == shape,
         true <- envelope["contract"] == Base.url_encode64(contract.digest, padding: false) do
      {:ok, envelope["value"]}
    else
      _other -> {:error, Error.new(:response_payload_invalid, "response JSON is invalid")}
    end
  end

  def unpack(_payload, _adapter, _shape, _contract) do
    {:error, Error.new(:response_payload_invalid, "response JSON is invalid")}
  end

  @doc false
  def unpack_shape(payload, adapter, shapes, contract) when is_list(shapes) do
    with true <- is_binary(payload) and byte_size(payload) > 0,
         true <- byte_size(payload) <= Codec.max_bytes(contract),
         true <- json_preflight?(payload, contract),
         {:ok, decoded} <- Jason.decode(payload, objects: :ordered_objects),
         {:ok, envelope} <- normalize(decoded, 0),
         :ok <- Codec.validate_value(envelope, contract, :payload),
         true <-
           is_map(envelope) and MapSet.equal?(MapSet.new(Map.keys(envelope)), @envelope_keys),
         true <- envelope["adapter"] == adapter,
         true <- envelope["shape"] in shapes,
         true <- envelope["contract"] == Base.url_encode64(contract.digest, padding: false) do
      {:ok, envelope["shape"], envelope["value"]}
    else
      _other -> {:error, Error.new(:response_payload_invalid, "response JSON is invalid")}
    end
  end

  defp adapter(%{kind: :resource}), do: {:ok, AshOnetime.Codec.Resource}
  defp adapter(%{kind: :action_result}), do: {:ok, AshOnetime.Codec.ActionResult}

  defp adapter(_contract),
    do: {:error, Error.new(:response_contract_invalid, "response kind is invalid")}

  defp normalize(_value, depth) when depth > 32, do: :error

  defp normalize(%Jason.OrderedObject{values: pairs}, depth) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, result} ->
        normalize_pair(key, value, result, depth)
      end)
    else
      :error
    end
  end

  defp normalize(values, depth) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case normalize(value, depth + 1) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | result]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp normalize(value, _depth)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize(_value, _depth), do: :error

  defp normalize_pair(key, value, result, depth) do
    case normalize(value, depth + 1) do
      {:ok, normalized} -> {:cont, {:ok, Map.put(result, key, normalized)}}
      :error -> {:halt, :error}
    end
  end

  defp json_preflight?(payload, contract) do
    limits = Codec.structural_limits(contract)

    state = %{
      depth: 0,
      nodes: 0,
      stack: [],
      in_string?: false,
      escaped?: false,
      in_scalar?: false,
      scalar_bytes: 0,
      invalid?: false,
      limits: limits
    }

    match?(
      {:ok, %{depth: 0, stack: [], in_string?: false, invalid?: false}},
      scan_json(payload, state)
    )
  end

  defp scan_json(<<>>, %{in_string?: true}), do: :error
  defp scan_json(<<>>, state), do: {:ok, %{state | in_scalar?: false, scalar_bytes: 0}}

  defp scan_json(<<_byte, rest::binary>>, %{in_string?: true, escaped?: true} = state),
    do: scan_json(rest, increment_scalar(%{state | escaped?: false}))

  defp scan_json(<<?\\, rest::binary>>, %{in_string?: true} = state),
    do: scan_json(rest, increment_scalar(%{state | escaped?: true}))

  defp scan_json(<<?\", rest::binary>>, %{in_string?: true} = state),
    do: scan_json(rest, %{state | in_string?: false, scalar_bytes: 0})

  defp scan_json(<<_byte, rest::binary>>, %{in_string?: true} = state),
    do: scan_json(rest, increment_scalar(state))

  defp scan_json(<<byte, rest::binary>>, state) when byte in [32, 9, 10, 13] do
    scan_json(rest, %{state | in_scalar?: false, scalar_bytes: 0})
  end

  defp scan_json(<<?\", rest::binary>>, state) do
    with {:ok, state} <- start_node(state) do
      scan_json(rest, %{state | in_string?: true, scalar_bytes: 0, in_scalar?: false})
    end
  end

  defp scan_json(<<byte, rest::binary>>, state) when byte in [?{, ?[] do
    with {:ok, state} <- start_node(state),
         true <- state.depth < state.limits.max_response_depth do
      frame = %{commas: 0, has_content?: false}
      scan_json(rest, %{state | depth: state.depth + 1, stack: [frame | state.stack]})
    else
      _other -> :error
    end
  end

  defp scan_json(<<byte, rest::binary>>, %{stack: [frame | stack]} = state)
       when byte in [?}, ?]] do
    entries = if frame.has_content?, do: frame.commas + 1, else: 0

    if entries <= state.limits.max_response_entries do
      scan_json(rest, %{
        state
        | depth: state.depth - 1,
          stack: stack,
          in_scalar?: false,
          scalar_bytes: 0
      })
    else
      :error
    end
  end

  defp scan_json(<<?,, rest::binary>>, %{stack: [frame | stack]} = state) do
    frame = %{frame | commas: frame.commas + 1}

    if frame.commas + 1 <= state.limits.max_response_entries do
      scan_json(rest, %{state | stack: [frame | stack], in_scalar?: false, scalar_bytes: 0})
    else
      :error
    end
  end

  defp scan_json(<<?:, rest::binary>>, state),
    do: scan_json(rest, %{state | in_scalar?: false, scalar_bytes: 0})

  defp scan_json(<<byte, rest::binary>>, %{in_scalar?: false} = state) do
    with {:ok, state} <- start_node(state) do
      scan_json(rest, increment_scalar(%{state | in_scalar?: true}, byte))
    end
  end

  defp scan_json(<<byte, rest::binary>>, state),
    do: scan_json(rest, increment_scalar(state, byte))

  defp start_node(state) do
    state = mark_content(state)
    nodes = state.nodes + 1

    if nodes <= state.limits.max_response_nodes,
      do: {:ok, %{state | nodes: nodes}},
      else: :error
  end

  defp mark_content(%{stack: [frame | stack]} = state),
    do: %{state | stack: [%{frame | has_content?: true} | stack]}

  defp mark_content(state), do: state

  defp increment_scalar(state, _byte \\ nil) do
    scalar_bytes = state.scalar_bytes + 1

    if scalar_bytes <= state.limits.max_response_scalar_bytes,
      do: %{state | scalar_bytes: scalar_bytes},
      else: %{state | invalid?: true}
  end
end
