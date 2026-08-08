defmodule AshOnetime.Response do
  @moduledoc false

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type, as: AshType
  alias AshOnetime.{Codec, Error, ResponseClassifier}
  alias AshOnetime.Codec.Resource, as: ResourceCodec
  alias AshOnetime.Store.{Claim, Result}

  @binding_prefix "ao:"
  @digest_bytes 32

  defmodule Contract do
    @moduledoc false
    @enforce_keys [
      :resource,
      :action_name,
      :action_type,
      :kind,
      :result_mode,
      :fields,
      :field_specs,
      :codec,
      :classifier,
      :limits,
      :trusted,
      :digest
    ]
    defstruct [
      :resource,
      :action_name,
      :action_type,
      :kind,
      :result_mode,
      :type,
      :allow_nil?,
      :codec,
      :classifier,
      :digest,
      fields: [],
      field_specs: [],
      constraints: [],
      codec_opts: [],
      limits: %{},
      trusted: %{}
    ]

    @type t :: %__MODULE__{}
  end

  @spec contract(module(), atom(), AshOnetime.Resource.Response.t(), map()) ::
          {:ok, Contract.t()} | {:error, Error.t()}
  def contract(resource, action_name, %AshOnetime.Resource.Response{} = response, trusted)
      when is_atom(resource) and is_atom(action_name) and is_map(trusted) do
    with action when not is_nil(action) <- ResourceInfo.action(resource, action_name),
         fields when is_list(fields) <- response.fields,
         classifier when is_atom(classifier) <- response.classify,
         codec_opts when is_list(codec_opts) <- response.codec_opts,
         true <- Keyword.keyword?(codec_opts),
         {:ok, limits} <- normalize_limits(response_limits(response, trusted)),
         :ok <- callbacks(response.codec),
         :ok <- callbacks(classifier, classify: 2),
         :ok <- Codec.validate_tag(response.codec.format_tag()),
         {:ok, shape} <- shape(resource, action, fields, trusted) do
      base =
        Map.merge(shape, %{
          resource: resource,
          action_name: action_name,
          action_type: action.type,
          fields: fields,
          codec: response.codec,
          codec_opts: codec_opts,
          classifier: classifier,
          limits: limits,
          trusted: trusted
        })

      digest = contract_digest(base)
      {:ok, struct!(Contract, Map.put(base, :digest, digest))}
    else
      false -> invalid_contract("response options are invalid")
      nil -> invalid_contract("response action does not exist")
      {:error, %Error{} = error} -> {:error, error}
      {:error, message} -> invalid_contract(message)
      _other -> invalid_contract("response contract is invalid")
    end
  rescue
    _exception -> invalid_contract("response contract is invalid")
  end

  def contract(_resource, _action_name, _response, _trusted) do
    invalid_contract("response contract is invalid")
  end

  @spec encode(term(), Contract.t(), keyword()) ::
          {:ok, map()} | {:reject, term()} | {:rollback, term()} | {:error, Error.t()}
  def encode(value, %Contract{} = contract, opts) when is_list(opts) do
    context = Map.merge(contract.trusted, Map.new(opts))

    case ResponseClassifier.classify(contract.classifier, value, context) do
      {:store, classified} -> encode_stored(classified, contract)
      {:reject, rejected} -> {:reject, rejected}
      {:rollback, reason} -> {:rollback, reason}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec replay(Result.t(), Contract.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def replay(
        %Result{
          status: :complete,
          reason: nil,
          payload: payload,
          claim:
            %Claim{
              strategy: :idempotency,
              state: :complete,
              response_partition: %Date{},
              response_codec: binding,
              response_digest: payload_digest
            } = claim,
          admission_dispatch: :sent,
          transaction: transaction
        },
        %Contract{} = contract,
        _opts
      )
      when transaction in [:open, :committed] and is_binary(payload) and is_binary(binding) and
             is_binary(payload_digest) do
    with :ok <- validate_complete_claim(claim),
         :ok <- validate_persisted_payload(payload, payload_digest, contract),
         {:ok, raw_tag, contract_digest} <- parse_binding(binding),
         :ok <- validate_codec_binding(raw_tag, contract),
         :ok <- validate_contract_binding(contract_digest, contract),
         {:ok, decoded} <- safe_decode(contract.codec, raw_tag, payload, contract),
         {:ok, normalized} <- validate_after_decode(decoded, contract) do
      {:ok, normalized}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        persisted_invalid()
    end
  end

  def replay(_result, _contract, _opts), do: persisted_invalid()

  defp encode_stored(value, contract) do
    with {:ok, prepared} <- validate_before_encode(value, contract),
         {:ok, raw_tag, payload} <- safe_encode(contract.codec, prepared, contract),
         :ok <- Codec.validate_tag(raw_tag),
         true <- raw_tag == contract.codec.format_tag(),
         true <- is_binary(payload) and byte_size(payload) <= Codec.max_bytes(contract),
         {:ok, decoded} <- safe_decode(contract.codec, raw_tag, payload, contract),
         {:ok, normalized} <- validate_after_decode(decoded, contract),
         :ok <- equal_result(prepared, normalized, contract) do
      {:ok,
       %{
         codec: binding(raw_tag, contract.digest),
         raw_tag: raw_tag,
         payload: payload,
         digest: :crypto.hash(:sha256, payload),
         result: normalized
       }}
    else
      false -> {:error, Error.new(:response_codec_mismatch, "response codec output is invalid")}
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:response_codec_failed, "response codec failed")}
    end
  end

  defp safe_encode(codec, value, contract) do
    codec.encode(value, contract, contract.codec_opts)
  rescue
    _exception -> {:error, Error.new(:response_codec_failed, "response codec failed")}
  catch
    _kind, _reason -> {:error, Error.new(:response_codec_failed, "response codec failed")}
  end

  defp safe_decode(codec, raw_tag, payload, contract) do
    codec.decode(raw_tag, payload, contract, contract.codec_opts)
  rescue
    _exception -> {:error, Error.new(:response_codec_failed, "response codec failed")}
  catch
    _kind, _reason -> {:error, Error.new(:response_codec_failed, "response codec failed")}
  end

  defp validate_before_encode(value, %{kind: :resource} = contract),
    do: ResourceCodec.normalize(value, contract)

  defp validate_before_encode(value, contract) do
    case Codec.validate_value(value, contract) do
      :ok -> {:ok, value}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_after_decode(value, %{kind: :resource} = contract),
    do: ResourceCodec.require_normalized(value, contract)

  defp validate_after_decode(value, contract) do
    case Codec.validate_value(value, contract) do
      :ok -> {:ok, value}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp equal_result(left, right, %{result_mode: :ok}) do
    if left == :ok and right == :ok,
      do: :ok,
      else: {:error, Error.new(:response_codec_failed, "response codec changed the result")}
  end

  defp equal_result(left, right, %{kind: :action_result, type: type}) do
    if AshType.equal?(type, left, right),
      do: :ok,
      else: {:error, Error.new(:response_codec_failed, "response codec changed the result")}
  end

  defp equal_result(left, right, %{kind: :resource, fields: fields, resource: resource}) do
    attributes = Map.new(ResourceInfo.attributes(resource), &{&1.name, &1})

    if Enum.all?(fields, &equal_field?(&1, attributes, left, right)) do
      :ok
    else
      {:error, Error.new(:response_codec_failed, "response codec changed the result")}
    end
  end

  defp equal_field?(field, attributes, left, right) do
    attribute = Map.fetch!(attributes, field)
    AshType.equal?(attribute.type, Map.get(left, field), Map.get(right, field))
  end

  defp shape(resource, %{type: type}, fields, trusted)
       when type in [:create, :update, :destroy] do
    with :ok <- validate_fields(resource, fields),
         {:ok, field_specs} <- field_specs(resource, fields) do
      result_mode =
        if type == :destroy and not Map.get(trusted, :return_destroyed?, false),
          do: :ok,
          else: {:resource, if(type == :destroy, do: :deleted, else: :loaded)}

      {:ok,
       %{
         kind: :resource,
         result_mode: result_mode,
         field_specs: field_specs,
         type: nil,
         constraints: [],
         allow_nil?: false
       }}
    end
  end

  defp shape(_resource, %{type: :action, returns: nil}, [], _trusted) do
    {:ok,
     %{
       kind: :action_result,
       result_mode: :ok,
       type: nil,
       constraints: [],
       field_specs: [],
       allow_nil?: false
     }}
  end

  defp shape(_resource, %{type: :action, returns: type} = action, [], _trusted) do
    normalized_type = AshType.get_type(type)

    case AshType.init(normalized_type, action.constraints) do
      {:ok, constraints} ->
        {:ok,
         %{
           kind: :action_result,
           result_mode: {:typed, normalized_type, constraints, action.allow_nil?},
           type: normalized_type,
           constraints: constraints,
           field_specs: [],
           allow_nil?: action.allow_nil?
         }}

      _other ->
        {:error, "generic action return constraints are invalid"}
    end
  end

  defp shape(_resource, %{type: :action}, _fields, _trusted) do
    {:error, "generic action response fields must be empty"}
  end

  defp shape(_resource, _action, _fields, _trusted), do: {:error, "action type is unsupported"}

  @doc false
  def validate_fields(resource, fields) do
    attributes = Map.new(ResourceInfo.attributes(resource), &{&1.name, &1})
    reserved = [:__struct__, :__metadata__, :__meta__, :calculations, :aggregates]

    valid? =
      fields == Enum.uniq(fields) and
        Enum.all?(fields, fn field ->
          case Map.get(attributes, field) do
            nil ->
              false

            attribute ->
              field not in reserved and attribute.public? and not attribute.sensitive?
          end
        end)

    if valid?,
      do: :ok,
      else: {:error, Error.new(:response_fields_invalid, "response fields are invalid")}
  end

  defp field_specs(resource, fields) do
    attributes = Map.new(ResourceInfo.attributes(resource), &{&1.name, &1})

    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, specs} ->
      attribute = Map.fetch!(attributes, field)
      type = AshType.get_type(attribute.type)

      case AshType.init(type, attribute.constraints) do
        {:ok, constraints} ->
          spec = {field, type, constraints, attribute.allow_nil?}
          {:cont, {:ok, [spec | specs]}}

        _other ->
          {:halt, {:error, "response field constraints are invalid"}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  end

  defp contract_digest(base) do
    descriptor =
      base
      |> Map.take([
        :resource,
        :action_name,
        :action_type,
        :kind,
        :result_mode,
        :fields,
        :field_specs,
        :type,
        :constraints,
        :allow_nil?,
        :codec,
        :codec_opts
      ])
      |> :erlang.term_to_binary([:deterministic])

    :crypto.hash(:sha256, descriptor)
  end

  defp binding(raw_tag, contract_digest) do
    @binding_prefix <> raw_tag <> ":" <> Base.url_encode64(contract_digest, padding: false)
  end

  defp parse_binding(binding) when byte_size(binding) <= 128 do
    case String.split(binding, ":") do
      ["ao", raw_tag, encoded_digest] when byte_size(encoded_digest) == 43 ->
        with :ok <- Codec.validate_tag(raw_tag),
             {:ok, digest} <- Base.url_decode64(encoded_digest, padding: false),
             true <- byte_size(digest) == @digest_bytes,
             true <- Base.url_encode64(digest, padding: false) == encoded_digest do
          {:ok, raw_tag, digest}
        else
          _other -> persisted_invalid()
        end

      _other ->
        persisted_invalid()
    end
  end

  defp parse_binding(_binding), do: persisted_invalid()

  defp callbacks(module, callbacks \\ [format_tag: 0, encode: 3, decode: 4]) do
    if is_atom(module) and Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      :ok
    else
      {:error, "response module does not implement its required callbacks"}
    end
  end

  # The response-level limits come from two sources with DIFFERENT vocabularies: the
  # consumer-declared `response.limits` (response-level keys: max_response_*) and the trusted
  # fallback `protection.limits` (protect-level keys: max_key_bytes, max_token_bytes,
  # max_scope_components, max_fingerprint_bytes, max_response_bytes, verifier_timeout_ms,
  # max_cache_entry_bytes). A consumer typo in `response.limits` must be rejected (F4); the
  # protect-level fallback is filtered to the keys the response codec understands so the two
  # vocabularies don't collide. The dual surface itself is ARCH-8's concern.
  defp response_limits(response, trusted) do
    case response.limits do
      nil ->
        known = Map.keys(Codec.hard_limits())

        trusted
        |> Map.get(:limits)
        |> Kernel.||([])
        |> Enum.filter(fn {key, _value} -> key in known end)

      response_limits ->
        response_limits
    end
  end

  defp normalize_limits(limits) when is_list(limits) do
    if Keyword.keyword?(limits),
      do: normalize_limits(Map.new(limits)),
      else: invalid_contract("response limits are invalid")
  end

  defp normalize_limits(%{} = limits) do
    hard_limits = Codec.hard_limits()
    unknown = Map.keys(limits) -- Map.keys(hard_limits)

    valid? =
      unknown == [] and
        Enum.all?(hard_limits, fn {name, maximum} ->
          case Map.fetch(limits, name) do
            :error -> true
            {:ok, value} -> is_integer(value) and value > 0 and value <= maximum
          end
        end)

    if valid? do
      {:ok, Map.merge(hard_limits, limits)}
    else
      invalid_contract("response limits are invalid")
    end
  end

  defp normalize_limits(_limits), do: invalid_contract("response limits are invalid")

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp validate_persisted_payload(payload, digest, contract) do
    cond do
      byte_size(payload) > Codec.max_bytes(contract) or byte_size(digest) != @digest_bytes ->
        persisted_invalid()

      not secure_equal?(digest, :crypto.hash(:sha256, payload)) ->
        {:error, Error.new(:response_digest_mismatch, "persisted response digest does not match")}

      true ->
        :ok
    end
  end

  defp validate_complete_claim(%Claim{} = claim) do
    valid? =
      valid_uuid?(claim.id) and valid_claim_hashes?(claim) and valid_idempotency_fields?(claim) and
        valid_complete_response?(claim) and valid_claim_timestamps?(claim)

    case valid? do
      true -> :ok
      _invalid -> persisted_invalid()
    end
  end

  defp valid_claim_hashes?(claim) do
    [claim.operation_hash, claim.scope_hash, claim.key_hash, claim.fingerprint]
    |> Enum.all?(&(is_binary(&1) and byte_size(&1) == @digest_bytes))
  end

  defp valid_idempotency_fields?(claim),
    do: is_nil(claim.issued_at) and is_nil(claim.expires_at) and is_nil(claim.verifier_id)

  defp valid_complete_response?(claim) do
    is_binary(claim.response_codec) and byte_size(claim.response_codec) > 0 and
      byte_size(claim.response_codec) <= 128 and
      is_binary(claim.response_digest) and byte_size(claim.response_digest) == @digest_bytes
  end

  defp valid_claim_timestamps?(claim) do
    DateTime.compare(claim.inserted_at, claim.admitted_at) in [:eq, :gt] and
      DateTime.compare(claim.retain_until, claim.admitted_at) == :gt
  rescue
    _exception -> false
  end

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> true
      _invalid -> false
    end
  end

  defp valid_uuid?(_id), do: false

  defp validate_codec_binding(raw_tag, contract) do
    if raw_tag == contract.codec.format_tag(),
      do: :ok,
      else:
        {:error, Error.new(:response_codec_mismatch, "persisted response codec does not match")}
  end

  defp validate_contract_binding(digest, contract) do
    if secure_equal?(digest, contract.digest),
      do: :ok,
      else:
        {:error,
         Error.new(:response_contract_mismatch, "persisted response contract does not match")}
  end

  defp invalid_contract(message), do: {:error, Error.new(:response_contract_invalid, message)}

  defp persisted_invalid do
    {:error, Error.new(:response_persisted_state_invalid, "persisted response state is invalid")}
  end
end
