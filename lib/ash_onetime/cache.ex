defmodule AshOnetime.Cache.Entry do
  @moduledoc """
  A completed-response cache entry bound to an authoritative PostgreSQL claim.

  Callers must treat every entry as untrusted. `AshOnetime` validates every field against
  the authoritative claim before using the payload.
  """

  defstruct [:claim_id, :fingerprint, :codec, :digest, :payload]

  @type t :: %__MODULE__{
          claim_id: Ecto.UUID.t() | nil,
          fingerprint: binary() | nil,
          codec: binary() | nil,
          digest: binary() | nil,
          payload: binary() | nil
        }
end

defmodule AshOnetime.Cache do
  @moduledoc """
  Optional cache behaviour for completed idempotency responses.

  Cache data is never admission authority. PostgreSQL is consulted first on every request,
  and a hit is usable only after its claim id, fingerprint, codec, digest, size, and payload
  digest match the authoritative claim.
  """

  alias AshOnetime.Cache.Entry
  alias AshOnetime.Store.{Claim, Result}

  @default_timeout 50
  @default_max_entry_bytes 16_777_216
  @maximum_timeout 30_000

  defmodule Config do
    @moduledoc false
    @enforce_keys [:module, :timeout, :max_entry_bytes]
    defstruct [:module, :timeout, :max_entry_bytes]

    @type t :: %__MODULE__{
            module: module(),
            timeout: pos_integer(),
            max_entry_bytes: pos_integer()
          }
  end

  @callback get(cache_key :: binary()) :: :miss | {:ok, Entry.t()} | {:error, term()}
  @callback put(cache_key :: binary(), Entry.t(), ttl_seconds :: pos_integer()) ::
              :ok | {:error, term()}
  @callback delete(cache_key :: binary()) :: :ok | {:error, term()}

  @doc false
  @spec config(Keyword.t()) :: Config.t()
  def config(limits) when is_list(limits) do
    module = Application.get_env(:ash_onetime, :cache, AshOnetime.Cache.None)
    timeout = Application.get_env(:ash_onetime, :cache_timeout, @default_timeout)
    maximum = Keyword.get(limits, :max_cache_entry_bytes, @default_max_entry_bytes)

    %Config{
      module: valid_module(module),
      timeout: bounded_timeout(timeout),
      max_entry_bytes: bounded_maximum(maximum)
    }
  end

  def config(_limits), do: config([])

  @doc false
  @spec authoritative_payload(Result.t(), Config.t()) :: {Result.t(), atom()}
  def authoritative_payload(
        %Result{status: :complete, claim: %Claim{strategy: :idempotency} = claim} = result,
        %Config{} = config
      ) do
    key = key(claim)

    case invoke(config, :get, [key]) do
      {:ok, {:ok, %Entry{} = entry}} ->
        if valid_entry?(entry, claim, config.max_entry_bytes) do
          {%{result | payload: entry.payload}, :hit}
        else
          _ = invoke(config, :delete, [key])
          {result, :stale}
        end

      {:ok, :miss} ->
        {result, :miss}

      {:ok, {:error, _reason}} ->
        {result, :failure}

      {:error, :timeout} ->
        {result, :timeout}

      _other ->
        {result, :corrupt}
    end
  end

  def authoritative_payload(%Result{} = result, %Config{}), do: {result, :disabled}

  @doc false
  @spec store(Config.t(), Claim.t(), binary()) :: atom()
  def store(%Config{module: AshOnetime.Cache.None}, _claim, _payload), do: :disabled

  def store(
        %Config{} = config,
        %Claim{strategy: :idempotency, state: :complete} = claim,
        payload
      )
      when is_binary(payload) do
    if byte_size(payload) <= config.max_entry_bytes do
      entry = %Entry{
        claim_id: claim.id,
        fingerprint: claim.fingerprint,
        codec: claim.response_codec,
        digest: claim.response_digest,
        payload: payload
      }

      case ttl_seconds(claim) do
        ttl when is_integer(ttl) and ttl > 0 ->
          persist(config, key(claim), entry, ttl)

        _other ->
          :expired
      end
    else
      :oversized
    end
  end

  def store(%Config{}, _claim, _payload), do: :disabled

  defp persist(config, key, entry, ttl) do
    case invoke(config, :put, [key, entry, ttl]) do
      {:ok, :ok} -> :stored
      {:error, :timeout} -> :timeout
      _other -> :failure
    end
  end

  defp valid_entry?(entry, claim, maximum) do
    valid_uuid?(entry.claim_id) and entry.claim_id == claim.id and
      fixed_equal?(entry.fingerprint, claim.fingerprint) and entry.codec == claim.response_codec and
      fixed_equal?(entry.digest, claim.response_digest) and is_binary(entry.payload) and
      byte_size(entry.payload) <= maximum and
      fixed_equal?(:crypto.hash(:sha256, entry.payload), claim.response_digest)
  end

  # Length-prefixed framing for the cache key. The components are 32-byte SHA-256 outputs
  # today (enforced by CHECK octet_length=32 on the claims table), so there is no
  # concatenation ambiguity in the current shape — this is defense-in-depth: if a future
  # change makes a component variable-length (a key-hash algorithm change, an unhashed
  # scope component), the length prefixes keep the framing unambiguous. A collision still
  # fails valid_entry?/2 (which re-checks fingerprint/digest/payload before any cache hit is
  # used), so this hardens a non-load-bearing surface. The cache key is an internal hash
  # input, not a wire format, so a direct length-prefix is lighter than Canonical.encode
  # (which allocates a response codec).
  defp key(%Claim{} = claim) do
    components = ["ash_onetime-cache", claim.operation_hash, claim.scope_hash, claim.key_hash]

    framed = for component <- components, into: "", do: <<byte_size(component)::32, component::binary>>
    :crypto.hash(:sha256, framed)
  end

  defp ttl_seconds(%Claim{retain_until: %DateTime{} = retain_until}) do
    DateTime.diff(retain_until, DateTime.utc_now(), :second)
  end

  defp ttl_seconds(_claim), do: 0

  defp invoke(%Config{module: AshOnetime.Cache.None}, function, arguments),
    do: {:ok, apply(AshOnetime.Cache.None, function, arguments)}

  defp invoke(%Config{module: module, timeout: timeout}, function, arguments) do
    task = Task.async(fn -> safe_apply(module, function, arguments) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
      {:exit, _reason} -> {:error, :failure}
    end
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _exception -> {:error, :failure}
  catch
    _kind, _reason -> {:error, :failure}
  end

  defp valid_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and
         Enum.all?([{:get, 1}, {:put, 3}, {:delete, 1}], fn {function, arity} ->
           function_exported?(module, function, arity)
         end) do
      module
    else
      AshOnetime.Cache.None
    end
  end

  defp valid_module(_module), do: AshOnetime.Cache.None

  defp bounded_timeout(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @maximum_timeout,
       do: timeout

  defp bounded_timeout(_timeout), do: @default_timeout

  defp bounded_maximum(maximum)
       when is_integer(maximum) and maximum > 0 and maximum <= @default_max_entry_bytes,
       do: maximum

  defp bounded_maximum(_maximum), do: @default_max_entry_bytes

  defp fixed_equal?(left, right)
       when is_binary(left) and byte_size(left) == 32 and is_binary(right) and
              byte_size(right) == 32,
       do: :crypto.hash_equals(left, right)

  defp fixed_equal?(_left, _right), do: false

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
end
