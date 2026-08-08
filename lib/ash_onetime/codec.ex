defmodule AshOnetime.Codec do
  @moduledoc """
  Contract for response codecs and shared boundary validation.
  """

  alias Ash.{ForbiddenField, NotLoaded}
  alias Ash.Notifier.Notification
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshOnetime.Error

  @callback format_tag() :: binary()
  @callback encode(term(), map(), keyword()) ::
              {:ok, binary(), binary()} | {:error, Error.t()}
  @callback decode(binary(), binary(), map(), keyword()) ::
              {:ok, term()} | {:error, Error.t()}

  @tag_pattern ~r/\A[A-Za-z0-9._-]+\z/
  @default_depth 32
  @default_nodes 100_000
  @default_entries 10_000
  @default_scalar_bytes 16_777_216

  @spec hard_limits() :: map()
  def hard_limits do
    %{
      max_response_bytes: 16_777_216,
      max_response_depth: @default_depth,
      max_response_nodes: @default_nodes,
      max_response_entries: @default_entries,
      max_response_scalar_bytes: @default_scalar_bytes
    }
  end

  # The protect-only limit keys bound the key/verification/cache/scope/fingerprint paths but
  # NOT the response codec. The single source of the limit-key vocabulary's two halves: this
  # set (protect-only) and hard_limits/0's keys (response). Both the transformer (compile-time
  # ceiling validation) and Response.response_limit/1 (runtime select-out of protect-only keys
  # + typo rejection) read from here so the two cannot drift — adding a protect-only key in one
  # place carries to the other automatically.
  @protect_only_limit_keys [
    max_key_bytes: 4_096,
    max_token_bytes: 65_536,
    max_scope_components: 16,
    max_fingerprint_bytes: 1_048_576,
    verifier_timeout_ms: 30_000,
    max_cache_entry_bytes: 16_777_216
  ]

  @doc """
  The protect-only limit keys with their package ceilings (the half of the limit vocabulary
  that bounds the key/verification/cache paths, not the response codec). Single source shared
  with `Response.response_limit/1`'s typo-discrimination set.
  """
  @spec protect_only_ceilings() :: keyword()
  def protect_only_ceilings, do: @protect_only_limit_keys

  @doc """
  Returns the response structural limits for `contract`, merging the contract's declared
  limits over the package hard limits. Only the hard-limit keys are honored (`max_response_*`);
  any other keys in `contract.limits` are ignored, so this is safe to call on an un-normalized
  map. Values are taken as-is — callers building a `%AshOnetime.Response.Contract{}` must
  validate values (the `Response.contract/4` path does so via `normalize_limits/1`).
  """
  @spec structural_limits(map()) :: map()
  def structural_limits(contract) do
    known = hard_limits()
    Map.merge(known, Map.take(Map.get(contract, :limits, %{}), Map.keys(known)))
  end

  @spec validate_tag(term()) :: :ok | {:error, Error.t()}
  def validate_tag(tag)
      when is_binary(tag) and byte_size(tag) >= 1 and byte_size(tag) <= 81 do
    if Regex.match?(@tag_pattern, tag) do
      :ok
    else
      codec_error()
    end
  end

  def validate_tag(_tag), do: codec_error()

  @spec validate_value(term(), map(), atom()) :: :ok | {:error, Error.t()}
  def validate_value(value, contract, phase \\ :value) do
    limits = structural_limits(contract)
    depth = limits.max_response_depth
    nodes = limits.max_response_nodes
    entries = limits.max_response_entries
    scalar_bytes = limits.max_response_scalar_bytes

    case walk(value, 0, depth, nodes, entries, scalar_bytes, phase) do
      {:ok, _nodes} -> :ok
      :error -> {:error, Error.new(error_code(phase), "response value is not persistable")}
    end
  end

  @spec max_bytes(map()) :: pos_integer()
  def max_bytes(contract) do
    contract
    |> Map.get(:limits, %{})
    |> Map.get(:max_response_bytes, 16_777_216)
  end

  @spec ash_resource?(term()) :: boolean()
  def ash_resource?(%module{}) when is_atom(module) do
    is_list(ResourceInfo.attributes(module))
  rescue
    _exception -> false
  end

  def ash_resource?(_value), do: false

  defp walk(_value, depth, max_depth, _nodes, _entries, _scalar_bytes, _phase)
       when depth > max_depth,
       do: :error

  defp walk(_value, _depth, _max_depth, nodes, _entries, _scalar_bytes, _phase)
       when nodes <= 0,
       do: :error

  defp walk(value, _depth, _max_depth, _nodes, _entries, _scalar_bytes, _phase)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value),
       do: :error

  defp walk(%NotLoaded{}, _depth, _max_depth, _nodes, _entries, _scalar_bytes, _phase),
    do: :error

  defp walk(%ForbiddenField{}, _depth, _max_depth, _nodes, _entries, _scalar_bytes, _phase),
    do: :error

  defp walk(
         %Notification{},
         _depth,
         _max_depth,
         _nodes,
         _entries,
         _scalar_bytes,
         _phase
       ),
       do: :error

  defp walk({:error, _reason}, _depth, _max_depth, _nodes, _entries, _scalar_bytes, _phase),
    do: :error

  defp walk(%module{} = value, depth, max_depth, nodes, entries, scalar_bytes, phase) do
    cond do
      is_exception(value) ->
        :error

      ash_resource?(value) ->
        :error

      module in [Decimal, Date, DateTime, NaiveDateTime, Time] ->
        {:ok, nodes - 1}

      phase == :payload ->
        :error

      true ->
        walk(
          Map.from_struct(value),
          depth + 1,
          max_depth,
          nodes - 1,
          entries,
          scalar_bytes,
          phase
        )
    end
  end

  defp walk(value, _depth, _max_depth, nodes, _entries, _scalar_bytes, _phase)
       when is_atom(value) or is_number(value),
       do: {:ok, nodes - 1}

  defp walk(value, _depth, _max_depth, nodes, _entries, scalar_bytes, _phase)
       when is_binary(value) do
    if byte_size(value) <= scalar_bytes, do: {:ok, nodes - 1}, else: :error
  end

  defp walk(value, depth, max_depth, nodes, entries, scalar_bytes, phase)
       when is_list(value) do
    if not proper_list?(value) or list_length_at_most(value, entries) == :exceeded do
      :error
    else
      walk_many(value, depth + 1, max_depth, nodes - 1, entries, scalar_bytes, phase)
    end
  end

  defp walk(value, depth, max_depth, nodes, entries, scalar_bytes, phase)
       when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> walk(depth, max_depth, nodes, entries, scalar_bytes, phase)
  end

  defp walk(value, depth, max_depth, nodes, entries, scalar_bytes, phase)
       when is_map(value) do
    if map_size(value) > entries do
      :error
    else
      value
      |> Enum.flat_map(fn {key, item} -> [key, item] end)
      |> walk_many(depth + 1, max_depth, nodes - 1, entries, scalar_bytes, phase)
    end
  end

  defp walk(_value, _depth, _max_depth, _nodes, _entries, _scalar_bytes, _phase), do: :error

  defp walk_many(values, depth, max_depth, nodes, entries, scalar_bytes, phase) do
    Enum.reduce_while(values, {:ok, nodes}, fn value, {:ok, remaining} ->
      case walk(value, depth, max_depth, remaining, entries, scalar_bytes, phase) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp list_length_at_most(values, maximum), do: list_length_at_most(values, maximum, 0)
  defp list_length_at_most(_values, maximum, count) when count > maximum, do: :exceeded
  defp list_length_at_most([], _maximum, count), do: count

  defp list_length_at_most([_head | tail], maximum, count),
    do: list_length_at_most(tail, maximum, count + 1)

  defp error_code(:payload), do: :response_payload_invalid
  defp error_code(_phase), do: :response_value_invalid

  defp codec_error do
    {:error, Error.new(:response_codec_invalid, "response codec tag is invalid")}
  end
end
