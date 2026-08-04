defmodule AshOnetime.Codec.ActionResult do
  @moduledoc """
  JSON codec for declared generic action return values.
  """

  @behaviour AshOnetime.Codec

  alias AshOnetime.{Codec, Error}
  alias AshOnetime.Codec.JSON

  @tag "action-result-json"
  @adapter "action_result"

  @impl true
  def format_tag, do: @tag

  @impl true
  def encode(value, contract, opts), do: encode_envelope(value, contract, @tag, opts)

  @impl true
  def decode(raw_tag, payload, contract, opts),
    do: decode_envelope(raw_tag, payload, contract, @tag, opts)

  @doc false
  def encode_envelope(value, %{kind: :action_result} = contract, raw_tag, _opts) do
    with true <- raw_tag in [@tag, JSON.format_tag()],
         :ok <- Codec.validate_value(value, contract),
         {:ok, shape, dumped} <- dump(value, contract),
         :ok <- Codec.validate_value(dumped, contract, :payload),
         {:ok, payload} <- JSON.pack(@adapter, shape, dumped, contract) do
      {:ok, raw_tag, payload}
    else
      false -> codec_mismatch()
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def encode_envelope(_value, _contract, _raw_tag, _opts), do: value_invalid()

  @doc false
  def decode_envelope(raw_tag, payload, contract, expected_tag, _opts) do
    with true <- raw_tag == expected_tag,
         {:ok, shapes} <- expected_shapes(contract),
         {:ok, shape, dumped} <- JSON.unpack_shape(payload, @adapter, shapes, contract),
         :ok <- Codec.validate_value(dumped, contract, :payload),
         {:ok, value} <- load(shape, dumped, contract),
         :ok <- Codec.validate_value(value, contract) do
      {:ok, value}
    else
      false -> codec_mismatch()
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp dump(:ok, %{result_mode: :ok}), do: {:ok, "ok", nil}

  defp dump(nil, %{result_mode: {:typed, _type, _constraints, true}}),
    do: {:ok, "nil", nil}

  defp dump(value, %{result_mode: {:typed, type, constraints, _allow_nil?}}) do
    case Ash.Type.dump_to_embedded(type, value, constraints) do
      {:ok, dumped} -> {:ok, "typed", dumped}
      _other -> value_invalid()
    end
  end

  defp dump(_value, _contract), do: value_invalid()

  defp load("ok", nil, %{result_mode: :ok}), do: {:ok, :ok}

  defp load("nil", nil, %{result_mode: {:typed, _type, _constraints, true}}),
    do: {:ok, nil}

  defp load("typed", value, %{result_mode: {:typed, type, constraints, _allow_nil?}})
       when not is_nil(value) do
    with {:ok, cast} <- Ash.Type.cast_from_embedded(type, value, constraints),
         {:ok, constrained} <- apply_constraints(type, cast, constraints) do
      {:ok, constrained}
    else
      _other -> value_invalid()
    end
  end

  defp load(_shape, _value, _contract), do: value_invalid()

  defp apply_constraints(type, value, constraints) do
    case Ash.Type.apply_constraints(type, value, constraints) do
      {:ok, constrained} -> {:ok, constrained}
      other -> other
    end
  end

  defp expected_shapes(%{result_mode: :ok}), do: {:ok, ["ok"]}
  defp expected_shapes(%{result_mode: {:typed, _, _, true}}), do: {:ok, ["typed", "nil"]}
  defp expected_shapes(%{result_mode: {:typed, _, _, false}}), do: {:ok, ["typed"]}
  defp expected_shapes(_contract), do: value_invalid()

  defp value_invalid,
    do: {:error, Error.new(:response_value_invalid, "response value does not match its contract")}

  defp codec_mismatch,
    do: {:error, Error.new(:response_codec_mismatch, "response codec tag does not match")}
end
