defmodule AshOnetime.Token do
  @moduledoc """
  Mints, signs, and verifies bounded self-identifying canonical tokens.

  The signed body binds the algorithm, key identifier, namespace, keyed-effect
  key, issuance instant, and optional expiry instant. Verification requires an
  expected algorithm and namespace supplied outside the token.

  ## 1.x compatibility (window-bounded)

  Within 1.x, a reader verifies tokens minted by any earlier 1.x writer while those
  tokens remain inside their acceptance window (`max_age` + the `skew:` option) — the
  obligation expires with each token's own window, nothing is frozen forever. New
  envelope forms are additive; a breaking format change waits out the longest
  configured window (or verifies both forms through the transition). The rule is
  recorded as ADR-0008 in the repository's `docs/adr/` directory.
  """

  alias AshOnetime.Callback
  alias AshOnetime.Canonical
  alias AshOnetime.Canonical.Decoder
  alias AshOnetime.Clock
  alias AshOnetime.Error
  alias AshOnetime.Window

  @enforce_keys [:algorithm, :key_id, :namespace, :key, :issued_at]
  defstruct [:algorithm, :key_id, :namespace, :key, :issued_at, :expires_at]

  @type algorithm :: :hmac_sha256 | :ed25519
  @type t :: %__MODULE__{
          algorithm: algorithm(),
          key_id: binary(),
          namespace: binary(),
          key: binary(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t() | nil
        }

  @prefix "ash_onetime."
  @max_token_bytes 8_192
  @max_key_bytes 1_024
  @max_identifier_bytes 128
  # Compile-time gate read through Application.compile_env/2 so the value is frozen at
  # build time and consumers see it OFF unless they explicitly opt in via config. The
  # verify-side :clock override is off by default in EVERY build environment; the
  # ash_onetime test suite opts in via config/test.exs so it can pin evaluated_at. The
  # prior Mix.env() == :test gate was deployment-fragile: a consumer who builds deps with
  # MIX_ENV=test mix deps.compile shipped the override live (letting a caller who
  # influences verify/3 options shift the replay window). compile_env default-off removes
  # that — the override is disabled unless the consuming application explicitly configures
  # it, regardless of MIX_ENV. (get_env would be re-read at runtime, but the gate is
  # structurally a compile-time branch via `if @allow_... do`; compile_env makes that
  # explicit and prevents the config from being silently ignored.)
  @allow_clock_override Application.compile_env(:ash_onetime, :allow_clock_override, false)

  @body_fields ~w(algorithm expires_at issued_at key key_id namespace)
  @envelope_fields ~w(body signature)

  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @doc """
  Mints a token struct from a key and a keyword of binding options.

  The options carry the security-relevant fields the signed body will bind: `:algorithm`
  (`:hmac_sha256` or `:ed25519`), `:key_id` (the custody-scoped key identifier, ≤128 bytes),
  `:namespace` (the caller-supplied namespace, ≤128 bytes), `:issued_at` (a `DateTime`,
  defaulting to `Clock.now/0`), and optional `:expires_at` (a `DateTime` strictly after
  `issued_at`). Every field is validated before the struct is built; an invalid option or a
  non-binary key returns `{:error, %AshOnetime.Error{}}` without minting.
  """
  @spec mint(binary(), keyword()) :: result(t())
  def mint(key, options) when is_binary(key) and is_list(options) do
    with true <- Keyword.keyword?(options),
         {:ok, algorithm} <- fetch_algorithm(options),
         {:ok, key_id} <- fetch_identifier(options, :key_id, :invalid_key_id),
         {:ok, namespace} <- fetch_identifier(options, :namespace, :invalid_namespace),
         {:ok, issued_at} <- issued_at(options),
         {:ok, expires_at} <- validate_expiry(Keyword.get(options, :expires_at), issued_at),
         :ok <- validate_key(key) do
      {:ok,
       %__MODULE__{
         algorithm: algorithm,
         key_id: key_id,
         namespace: namespace,
         key: key,
         issued_at: issued_at,
         expires_at: expires_at
       }}
    else
      false -> {:error, Error.new(:invalid_options, "token options must be a keyword list")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def mint(_key, _options),
    do: {:error, Error.new(:invalid_key, "token key must be bytes")}

  @doc """
  Signs a minted token through an `AshOnetime.KeyCustody` module.

  `custody_context` is trusted holder configuration, passed unchanged to custody.
  Custody signs exactly the canonical body bytes in a supervised, unlinked worker.
  Its signature must be 32 bytes for HMAC-SHA256 or 64 bytes for pure Ed25519.
  The canonical envelope and `ash_onetime.` prefix are unchanged (ADR-0008).
  """
  @spec sign(t(), module(), term()) :: result(binary())
  def sign(%__MODULE__{} = token, custody, custody_context) when is_atom(custody) do
    with :ok <- validate_token(token),
         {:ok, body} <- token_body(token),
         {:ok, body_bytes} <- Canonical.encode(body),
         {:ok, signature} <- custody_sign(custody, token, body_bytes, custody_context),
         {:ok, envelope} <- Canonical.encode(%{"body" => body, "signature" => signature}),
         encoded = @prefix <> Base.url_encode64(envelope, padding: false),
         :ok <- check_token_size(encoded) do
      {:ok, encoded}
    end
  end

  def sign(_token, _custody, _custody_context),
    do: {:error, Error.new(:invalid_token, "token struct is invalid")}

  @doc """
  Verifies a token through custody against externally supplied expectations.

  Options must supply `:algorithm`, `:namespace` and `:max_age`, and may supply
  `:skew` (default 0) and `:custody_context`. Body validation, expectation binding,
  window validation and exact signature length checks happen before custody runs.
  Only custody's exact `:ok` accepts the signature. Custody failures have fixed
  package messages and empty details; holder diagnostics never escape.
  """
  @spec verify(binary(), module(), keyword()) :: result(t())
  def verify(encoded, custody, options)
      when is_binary(encoded) and is_atom(custody) and is_list(options) do
    with :ok <- check_token_size(encoded),
         true <- Keyword.keyword?(options),
         {:ok, expected_algorithm} <- fetch_algorithm(options),
         {:ok, expected_namespace} <- fetch_identifier(options, :namespace, :invalid_namespace),
         {:ok, raw} <- decode_wire(encoded),
         {:ok, body, signature} <- decode_envelope(raw),
         {:ok, token} <- token_from_body(body),
         :ok <- bind_expected(token, expected_algorithm, expected_namespace),
         :ok <- validate_window(token, options),
         :ok <- signature_length(token.algorithm, signature, :invalid_signature),
         {:ok, body_bytes} <- Canonical.encode(body),
         :ok <-
           custody_verify(
             custody,
             token,
             body_bytes,
             signature,
             Keyword.get(options, :custody_context)
           ) do
      {:ok, token}
    else
      false ->
        {:error, Error.new(:invalid_options, "verification options must be a keyword list")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def verify(encoded, _custody, _options) when is_binary(encoded) do
    with :ok <- check_token_size(encoded) do
      {:error, Error.new(:invalid_options, "verification arguments are invalid")}
    end
  end

  def verify(_encoded, _custody, _options),
    do: {:error, Error.new(:invalid_token, "token must be bytes")}

  defp validate_token(%__MODULE__{} = token) do
    with {:ok, _algorithm} <- validate_algorithm(token.algorithm),
         :ok <- validate_identifier(token.key_id, :invalid_key_id, :key_id),
         :ok <- validate_identifier(token.namespace, :invalid_namespace, :namespace),
         :ok <- validate_key(token.key),
         {:ok, issued_at} <- validate_datetime(token.issued_at, :invalid_issued_at),
         {:ok, _expires_at} <- validate_expiry(token.expires_at, issued_at) do
      :ok
    end
  end

  defp token_body(token) do
    with {:ok, issued_at} <- datetime_to_unix(token.issued_at, :invalid_issued_at),
         {:ok, expires_at} <- optional_datetime_to_unix(token.expires_at) do
      {:ok,
       %{
         "algorithm" => encode_algorithm(token.algorithm),
         "expires_at" => expires_at,
         "issued_at" => issued_at,
         "key" => token.key,
         "key_id" => token.key_id,
         "namespace" => token.namespace
       }}
    end
  end

  defp decode_wire(@prefix <> payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, raw} ->
        if Base.url_encode64(raw, padding: false) == payload do
          {:ok, raw}
        else
          {:error, Error.new(:noncanonical_envelope, "token base64url is not canonical")}
        end

      :error ->
        {:error, Error.new(:invalid_token, "token base64url is invalid")}
    end
  end

  defp decode_wire(_encoded),
    do: {:error, Error.new(:invalid_token, "token prefix is invalid")}

  defp decode_envelope(raw) do
    case Decoder.decode(raw) do
      {:ok, envelope} ->
        parse_envelope(envelope)

      {:error, %Error{code: :duplicate_map_key}} ->
        {:error, Error.new(:duplicate_field, "token contains a duplicate field")}

      {:error, %Error{code: :noncanonical_encoding}} ->
        {:error, Error.new(:noncanonical_envelope, "token envelope is not canonical")}

      {:error, %Error{}} ->
        {:error, Error.new(:malformed_token, "token envelope is malformed")}
    end
  end

  defp parse_envelope(%{"body" => body, "signature" => signature} = envelope)
       when map_size(envelope) == length(@envelope_fields) and is_map(body) and
              is_binary(signature) do
    if exact_fields?(envelope, @envelope_fields) do
      {:ok, body, signature}
    else
      {:error, Error.new(:malformed_token, "token envelope fields are inexact")}
    end
  end

  defp parse_envelope(_envelope),
    do: {:error, Error.new(:malformed_token, "token envelope shape is invalid")}

  defp token_from_body(body) when is_map(body) do
    if exact_fields?(body, @body_fields) do
      with {:ok, algorithm} <- decode_algorithm(body["algorithm"]),
           :ok <- validate_identifier(body["key_id"], :invalid_key_id, :key_id),
           :ok <- validate_identifier(body["namespace"], :invalid_namespace, :namespace),
           :ok <- validate_key(body["key"]),
           {:ok, issued_at} <- unix_to_datetime(body["issued_at"], :invalid_issued_at),
           {:ok, expires_at} <- optional_unix_to_datetime(body["expires_at"]),
           {:ok, expires_at} <- validate_expiry(expires_at, issued_at) do
        {:ok,
         %__MODULE__{
           algorithm: algorithm,
           key_id: body["key_id"],
           namespace: body["namespace"],
           key: body["key"],
           issued_at: issued_at,
           expires_at: expires_at
         }}
      end
    else
      {:error, Error.new(:malformed_token, "signed body fields are inexact")}
    end
  end

  defp bind_expected(token, expected_algorithm, expected_namespace) do
    cond do
      token.algorithm != expected_algorithm ->
        {:error, Error.new(:algorithm_mismatch, "token algorithm does not match expectation")}

      token.namespace != expected_namespace ->
        {:error, Error.new(:namespace_mismatch, "token namespace does not match expectation")}

      true ->
        :ok
    end
  end

  defp validate_window(token, options) do
    with {:ok, max_age} <- fetch_non_negative_integer(options, :max_age),
         {:ok, skew} <- optional_non_negative_integer(options, :skew, 0),
         {:ok, evaluated_at} <- evaluated_at(options),
         :ok <- Window.validate(token.issued_at, token.expires_at, evaluated_at, max_age, skew) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :invalid} -> {:error, Error.new(:invalid_window, "token time window is invalid")}
    end
  end

  defp issued_at(options) do
    case Keyword.fetch(options, :issued_at) do
      {:ok, value} -> validate_datetime(value, :invalid_issued_at)
      :error -> trusted_now(Keyword.get(options, :clock, Clock), :invalid_issued_at)
    end
  end

  defp evaluated_at(options) do
    if Keyword.has_key?(options, :evaluated_at) do
      {:error, Error.new(:invalid_options, "verification evaluation time is library-controlled")}
    else
      verification_clock(options)
    end
  end

  if @allow_clock_override do
    defp verification_clock(options) do
      trusted_now(Keyword.get(options, :clock, Clock), :invalid_evaluated_at)
    end
  else
    defp verification_clock(options) do
      case Keyword.fetch(options, :clock) do
        {:ok, _clock} ->
          {:error,
           Error.new(
             :invalid_options,
             "verification clock override requires explicit " <>
               "config :ash_onetime, allow_clock_override: true (set BEFORE compiling ash_onetime; " <>
               "the gate is read via Application.compile_env at build time)"
           )}

        :error ->
          trusted_now(Clock, :invalid_evaluated_at)
      end
    end
  end

  defp trusted_now(clock, error_code) when is_atom(clock) do
    clock.now()
    |> validate_datetime(error_code)
  rescue
    _exception -> {:error, Error.new(error_code, "trusted clock did not return a DateTime")}
  catch
    _kind, _reason -> {:error, Error.new(error_code, "trusted clock did not return a DateTime")}
  end

  defp trusted_now(_clock, error_code),
    do: {:error, Error.new(error_code, "trusted clock module is invalid")}

  defp fetch_algorithm(options) do
    case Keyword.fetch(options, :algorithm) do
      {:ok, algorithm} -> validate_algorithm(algorithm)
      :error -> {:error, missing_option(:algorithm)}
    end
  end

  defp validate_algorithm(algorithm) when algorithm in [:hmac_sha256, :ed25519],
    do: {:ok, algorithm}

  defp validate_algorithm(_algorithm),
    do: {:error, Error.new(:unsupported_algorithm, "token algorithm is unsupported")}

  defp encode_algorithm(:hmac_sha256), do: "hmac-sha256"
  defp encode_algorithm(:ed25519), do: "ed25519"

  defp decode_algorithm("hmac-sha256"), do: {:ok, :hmac_sha256}
  defp decode_algorithm("ed25519"), do: {:ok, :ed25519}

  defp decode_algorithm(_algorithm),
    do: {:error, Error.new(:unsupported_algorithm, "token algorithm is unsupported")}

  defp fetch_identifier(options, name, error_code) do
    case Keyword.fetch(options, name) do
      {:ok, value} ->
        case validate_identifier(value, error_code, name) do
          :ok -> {:ok, value}
          {:error, %Error{} = error} -> {:error, error}
        end

      :error ->
        {:error, missing_option(name)}
    end
  end

  defp validate_identifier(value, _error_code, _name)
       when is_binary(value) and byte_size(value) in 1..@max_identifier_bytes,
       do: :ok

  defp validate_identifier(_value, error_code, name),
    do:
      {:error,
       Error.new(error_code, "token identifier is invalid", %{
         field: name,
         maximum: @max_identifier_bytes
       })}

  defp validate_key(key) when is_binary(key) and byte_size(key) in 1..@max_key_bytes, do: :ok

  defp validate_key(key) when is_binary(key) and byte_size(key) > @max_key_bytes,
    do: {:error, Error.new(:key_too_large, "token key exceeds its byte limit")}

  defp validate_key(_key),
    do: {:error, Error.new(:invalid_key, "token key must be bounded non-empty bytes")}

  defp validate_datetime(%DateTime{} = datetime, error_code) do
    case datetime_to_unix(datetime, error_code) do
      {:ok, _unix} -> {:ok, datetime}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_datetime(_datetime, error_code),
    do: {:error, Error.new(error_code, "token timestamp must be a DateTime")}

  defp validate_expiry(nil, _issued_at), do: {:ok, nil}

  defp validate_expiry(%DateTime{} = expires_at, %DateTime{} = issued_at) do
    with {:ok, _issued_at} <- validate_datetime(issued_at, :invalid_issued_at),
         {:ok, _expires_at} <- validate_datetime(expires_at, :invalid_expires_at) do
      if DateTime.compare(expires_at, issued_at) in [:eq, :gt] do
        {:ok, expires_at}
      else
        {:error, Error.new(:invalid_expires_at, "token expiry precedes issuance")}
      end
    end
  end

  defp validate_expiry(_expires_at, _issued_at),
    do: {:error, Error.new(:invalid_expires_at, "token expiry must be a DateTime or nil")}

  defp datetime_to_unix(%DateTime{} = datetime, error_code) do
    {:ok, DateTime.to_unix(datetime, :microsecond)}
  rescue
    _exception -> {:error, Error.new(error_code, "token timestamp is invalid")}
  catch
    _kind, _reason -> {:error, Error.new(error_code, "token timestamp is invalid")}
  end

  defp datetime_to_unix(_datetime, error_code),
    do: {:error, Error.new(error_code, "token timestamp must be a DateTime")}

  defp optional_datetime_to_unix(nil), do: {:ok, nil}
  defp optional_datetime_to_unix(datetime), do: datetime_to_unix(datetime, :invalid_expires_at)

  defp unix_to_datetime(unix, error_code) when is_integer(unix) do
    case DateTime.from_unix(unix, :microsecond) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, Error.new(error_code, "token timestamp is out of range")}
    end
  end

  defp unix_to_datetime(_unix, error_code),
    do: {:error, Error.new(error_code, "token timestamp must be an integer")}

  defp optional_unix_to_datetime(nil), do: {:ok, nil}
  defp optional_unix_to_datetime(unix), do: unix_to_datetime(unix, :invalid_expires_at)

  defp fetch_non_negative_integer(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, Error.new(:invalid_option, "option must be non-negative", %{option: name})}

      :error ->
        {:error, missing_option(name)}
    end
  end

  defp optional_non_negative_integer(options, name, default) do
    case Keyword.get(options, name, default) do
      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      _value ->
        {:error, Error.new(:invalid_option, "option must be non-negative", %{option: name})}
    end
  end

  defp custody_sign(custody, token, bytes, context) do
    case custody_call(custody, :sign, token.algorithm, [
           token.algorithm,
           token.key_id,
           bytes,
           context
         ]) do
      {:ok, {:ok, signature}} ->
        with :ok <- signature_length(token.algorithm, signature, :custody_contract_violation),
             do: {:ok, signature}

      result ->
        custody_error(result, :sign)
    end
  end

  defp custody_verify(custody, token, bytes, signature, context) do
    case custody_call(custody, :verify, token.algorithm, [
           token.algorithm,
           token.key_id,
           bytes,
           signature,
           context
         ]) do
      {:ok, :ok} -> :ok
      result -> custody_error(result, :verify)
    end
  end

  defp custody_call(custody, purpose, algorithm, arguments) do
    Callback.run(fn ->
      algorithms = custody.algorithms()

      cond do
        not is_list(algorithms) -> :invalid_contract
        algorithm in algorithms -> apply(custody, purpose, arguments)
        true -> {:error, :key_unusable}
      end
    end)
  end

  defp custody_error({:ok, {:error, :invalid_signature}}, :verify),
    do: {:error, Callback.error(:invalid_signature)}

  defp custody_error({:ok, {:error, :key_unusable}}, _),
    do: {:error, Callback.error(:key_unusable)}

  defp custody_error({:ok, {:error, :unavailable}}, _),
    do: {:error, Callback.error(:custody_unavailable)}

  defp custody_error({:ok, {:error, :timeout}}, _),
    do: {:error, Callback.error(:custody_timeout)}

  defp custody_error({:error, :deadline}, _),
    do: {:error, Callback.error(:custody_timeout)}

  defp custody_error(_, _), do: {:error, Callback.error(:custody_contract_violation)}

  defp signature_length(algorithm, signature, code) do
    size = if algorithm == :hmac_sha256, do: 32, else: 64

    if is_binary(signature) and byte_size(signature) == size,
      do: :ok,
      else: {:error, Callback.error(code)}
  end

  defp exact_fields?(map, fields), do: map |> Map.keys() |> Enum.sort() |> Kernel.==(fields)

  defp check_token_size(encoded) when byte_size(encoded) <= @max_token_bytes, do: :ok

  defp check_token_size(_encoded),
    do:
      {:error,
       Error.new(:token_too_large, "token exceeds its byte limit", %{maximum: @max_token_bytes})}

  defp missing_option(name),
    do: Error.new(:missing_option, "required option is missing", %{option: name})
end
