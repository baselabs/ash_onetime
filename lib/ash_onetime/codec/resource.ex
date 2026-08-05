defmodule AshOnetime.Codec.Resource do
  @moduledoc """
  JSON codec for allowlisted fields of Ash resource action results.
  """

  @behaviour AshOnetime.Codec

  alias Ash.NotLoaded
  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type, as: AshType
  alias AshOnetime.{Codec, Error, Response}
  alias AshOnetime.Codec.JSON

  @tag "resource-json"
  @adapter "resource"

  @impl true
  def format_tag, do: @tag

  @impl true
  def encode(value, contract, opts), do: encode_envelope(value, contract, @tag, opts)

  @impl true
  def decode(raw_tag, payload, contract, opts),
    do: decode_envelope(raw_tag, payload, contract, @tag, opts)

  @doc false
  def normalize(:ok, %{kind: :resource, result_mode: :ok}), do: {:ok, :ok}

  def normalize(%resource{} = value, %{resource: resource, kind: :resource} = contract) do
    with :ok <- Response.validate_fields(resource, contract.fields),
         :ok <- unloaded_relationships(value, resource),
         {:ok, values} <- projection_values(value, contract) do
      rehydrate(values, contract)
    end
  end

  def normalize(_value, _contract), do: value_invalid()

  @doc false
  def require_normalized(value, contract) do
    with {:ok, normalized} <- normalize(value, contract),
         true <- normalized == value do
      {:ok, normalized}
    else
      false -> value_invalid()
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc false
  def encode_envelope(
        %resource{} = value,
        %{resource: resource, kind: :resource} = contract,
        raw_tag,
        _opts
      ) do
    with true <- raw_tag in [@tag, JSON.format_tag()],
         :ok <- Response.validate_fields(resource, contract.fields),
         :ok <- unloaded_relationships(value, resource),
         {:ok, projected} <- project(value, contract),
         {:ok, payload} <- JSON.pack(@adapter, "resource", projected, contract) do
      {:ok, raw_tag, payload}
    else
      false -> codec_mismatch()
      {:error, %Error{} = error} -> {:error, error}
      _other -> value_invalid()
    end
  end

  def encode_envelope(:ok, %{kind: :resource, result_mode: :ok} = contract, raw_tag, _opts) do
    with true <- raw_tag in [@tag, JSON.format_tag()],
         {:ok, payload} <- JSON.pack(@adapter, "ok", nil, contract) do
      {:ok, raw_tag, payload}
    else
      false -> codec_mismatch()
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def encode_envelope(_value, _contract, _raw_tag, _opts), do: value_invalid()

  @doc false
  def decode_envelope(
        raw_tag,
        payload,
        %{kind: :resource, result_mode: {:resource, _state}} = contract,
        expected_tag,
        _opts
      ) do
    with true <- raw_tag == expected_tag,
         :ok <- Response.validate_fields(contract.resource, contract.fields),
         {:ok, projected} <- JSON.unpack(payload, @adapter, "resource", contract),
         true <- is_map(projected),
         true <- declared_fields_match?(Map.keys(projected), contract.fields),
         {:ok, values} <- restore_values(projected, contract),
         {:ok, resource} <- rehydrate(values, contract) do
      {:ok, resource}
    else
      false ->
        {:error, Error.new(:response_fields_invalid, "persisted response fields are invalid")}

      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        value_invalid()
    end
  end

  def decode_envelope(
        raw_tag,
        payload,
        %{kind: :resource, result_mode: :ok} = contract,
        expected_tag,
        _opts
      ) do
    with true <- raw_tag == expected_tag,
         {:ok, nil} <- JSON.unpack(payload, @adapter, "ok", contract) do
      {:ok, :ok}
    else
      false -> codec_mismatch()
      {:error, %Error{} = error} -> {:error, error}
      _other -> value_invalid()
    end
  end

  def decode_envelope(_raw_tag, _payload, _contract, _expected_tag, _opts), do: value_invalid()

  defp project(value, contract) do
    attributes = Map.new(ResourceInfo.attributes(contract.resource), &{&1.name, &1})

    Enum.reduce_while(contract.fields, {:ok, %{}}, fn field, {:ok, result} ->
      attribute = Map.fetch!(attributes, field)
      field_value = Map.get(value, field)

      with true <- Ash.Resource.selected?(value, field),
           :ok <- validate_nil(field, field_value, contract),
           :ok <- Codec.validate_value(field_value, contract),
           {:ok, dumped} <-
             AshType.dump_to_embedded(attribute.type, field_value, attribute.constraints),
           :ok <- Codec.validate_value(dumped, contract, :payload) do
        {:cont, {:ok, Map.put(result, Atom.to_string(field), dumped)}}
      else
        _other -> {:halt, value_invalid()}
      end
    end)
    |> validate_projection(contract, :payload)
  end

  defp projection_values(value, contract) do
    contract.fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, result} ->
      field_value = Map.get(value, field)

      with true <- Ash.Resource.selected?(value, field),
           :ok <- validate_nil(field, field_value, contract),
           :ok <- Codec.validate_value(field_value, contract) do
        {:cont, {:ok, Map.put(result, field, field_value)}}
      else
        _other -> {:halt, value_invalid()}
      end
    end)
    |> validate_projection(contract, :value)
  end

  defp restore_values(projected, contract) do
    attributes = Map.new(ResourceInfo.attributes(contract.resource), &{&1.name, &1})

    Enum.reduce_while(contract.fields, {:ok, %{}}, fn field, {:ok, result} ->
      attribute = Map.fetch!(attributes, field)

      with {:ok, cast} <-
             AshType.cast_from_embedded(
               attribute.type,
               projected[Atom.to_string(field)],
               attribute.constraints
             ),
           {:ok, value} <- apply_constraints(attribute, cast),
           :ok <- validate_nil(field, value, contract),
           :ok <- Codec.validate_value(value, contract) do
        {:cont, {:ok, Map.put(result, field, value)}}
      else
        _other -> {:halt, value_invalid()}
      end
    end)
    |> validate_projection(contract, :value)
  end

  defp validate_projection({:ok, projection}, contract, phase) do
    case Codec.validate_value(projection, contract, phase) do
      :ok -> {:ok, projection}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_projection(error, _contract, _phase), do: error

  defp validate_nil(field, nil, contract) do
    case Enum.find(contract.field_specs, fn {name, _type, _constraints, _allow_nil?} ->
           name == field
         end) do
      {^field, _type, _constraints, true} -> :ok
      _other -> value_invalid()
    end
  end

  defp validate_nil(_field, _value, _contract), do: :ok

  defp apply_constraints(attribute, value) do
    case AshType.apply_constraints(attribute.type, value, attribute.constraints) do
      {:ok, constrained} -> {:ok, constrained}
      other -> other
    end
  end

  defp rehydrate(values, contract) do
    resource = contract.resource

    restored =
      resource
      |> struct()
      |> unload(ResourceInfo.attributes(resource), :attribute)
      |> unload(ResourceInfo.relationships(resource), :relationship)
      |> unload(ResourceInfo.calculations(resource), :calculation)
      |> unload(ResourceInfo.aggregates(resource), :aggregate)
      |> Map.merge(values)
      |> Map.put(:__metadata__, result_metadata(contract))
      |> Ecto.put_meta(state: resource_state(contract.result_mode))

    {:ok, restored}
  rescue
    _exception -> value_invalid()
  end

  defp unload(resource, fields, type) do
    Enum.reduce(fields, resource, fn field, result ->
      Map.put(result, field.name, %NotLoaded{
        field: field.name,
        type: type,
        resource: resource.__struct__
      })
    end)
  end

  defp unloaded_relationships(value, resource) do
    if Enum.all?(
         ResourceInfo.relationships(resource),
         &relationship_unloaded?(value, &1, resource)
       ) do
      :ok
    else
      value_invalid()
    end
  end

  defp relationship_unloaded?(value, relationship, resource) do
    case Map.get(value, relationship.name) do
      %NotLoaded{field: field, type: :relationship, resource: sentinel_resource} ->
        field == relationship.name and sentinel_resource == resource

      _other ->
        false
    end
  end

  defp declared_fields_match?(actual, expected) do
    MapSet.new(actual) == MapSet.new(Enum.map(expected, &Atom.to_string/1))
  end

  defp result_metadata(contract) do
    metadata = %{selected: contract.fields}

    case contract.trusted do
      %{tenant: tenant} when not is_nil(tenant) -> Map.put(metadata, :tenant, tenant)
      _ -> metadata
    end
  end

  defp resource_state({:resource, state}), do: state

  defp value_invalid,
    do:
      {:error,
       Error.new(:response_value_invalid, "response resource does not match its contract")}

  defp codec_mismatch,
    do: {:error, Error.new(:response_codec_mismatch, "response codec tag does not match")}
end
