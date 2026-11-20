defmodule AshOnetime.Verified do
  @moduledoc """
  Trusted local facts returned by a configured token verifier or minter.

  `t` is opaque: `new/1` is the sanctioned constructor, and consumer code that
  builds the struct literally violates the opacity contract Dialyzer enforces
  (`contract_with_opaque`). Opacity is a construction convention, not a
  runtime seal — the anti-forgery boundary is the admission path itself:
  verified facts enter only through DSL-configured verifier/minter callbacks
  under a bounded context, and reserved action-input names cannot pose as
  them (see `AshOnetime.Verifier` for the callback contract).
  """

  @enforce_keys [:key, :issued_at, :verifier_id]
  defstruct [:key, :issued_at, :expires_at, :verifier_id]

  # The verifier-id byte bound the store and admission hold a Verified to.
  # The literal appears at four sites (here, AshOnetime.Store.Claim's
  # @max_verifier_id_bytes, and two literals in AshOnetime.Admission); the
  # drift tripwire in verified_test.exs pins all four to one value. No key
  # byte cap exists because the key bound is per-action configuration in
  # admission, not a property of the type.
  @max_verifier_id_bytes 128
  @required_keys @enforce_keys
  @known_keys @enforce_keys ++ [:expires_at]

  @opaque t :: %__MODULE__{
            key: binary(),
            issued_at: DateTime.t(),
            expires_at: DateTime.t() | nil,
            verifier_id: binary()
          }

  @doc """
  Mints `Verified` facts — the sanctioned constructor for the opaque `t`.

  Accepts a keyword list with `key` (non-empty binary, no length cap — the
  key bound is per-action configuration), `issued_at` (DateTime), `verifier_id`
  (non-empty binary of at most #{@max_verifier_id_bytes} bytes), and the
  optional `expires_at` (DateTime at or after `issued_at`; defaults to nil).
  Unknown, duplicate, and missing keys are rejected, as are DateTimes whose
  calendar fields are forged — `new/1` never raises.

  Returns `{:ok, verified}` or `{:error, reason}` naming the violated
  invariant. The bar is the one every internal consumer already holds a
  `Verified` to (admission's bounded binaries, the store's verifier-id
  bound, the window's expiry ordering and datetime probing), checked at
  mint time so a host minter learns of a bad fact before it reaches
  admission.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(fields) when is_list(fields) do
    with :ok <- well_formed(fields),
         {:ok, key} <- mint_key(fields),
         {:ok, issued_at} <- mint_issued_at(fields),
         {:ok, verifier_id} <- mint_verifier_id(fields),
         {:ok, expires_at} <- mint_expires_at(fields, issued_at) do
      {:ok,
       %__MODULE__{
         key: key,
         issued_at: issued_at,
         expires_at: expires_at,
         verifier_id: verifier_id
       }}
    end
  end

  def new(_fields), do: {:error, "verified facts must be a keyword list"}

  defp well_formed(fields) do
    cond do
      not Keyword.keyword?(fields) ->
        {:error, "verified facts must be a keyword list"}

      map_size(Map.new(fields)) != length(fields) ->
        {:error, "verified facts must contain unique keys"}

      true ->
        check_keys(Keyword.keys(fields))
    end
  end

  defp check_keys(keys) do
    missing = Enum.uniq(@required_keys -- keys)
    unknown = Enum.uniq(keys -- @known_keys)

    cond do
      missing != [] ->
        {:error, "verified facts require #{inspect(missing)}"}

      unknown != [] ->
        {:error, "verified facts accept only #{inspect(@known_keys)}; got #{inspect(unknown)}"}

      true ->
        :ok
    end
  end

  defp mint_key(fields) do
    case Keyword.fetch!(fields, :key) do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _other -> {:error, "key must be a non-empty binary"}
    end
  end

  defp mint_issued_at(fields) do
    issued_at = Keyword.fetch!(fields, :issued_at)

    if representable_datetime?(issued_at) do
      {:ok, issued_at}
    else
      {:error, "issued_at must be a DateTime"}
    end
  end

  defp mint_verifier_id(fields) do
    case Keyword.fetch!(fields, :verifier_id) do
      verifier_id
      when is_binary(verifier_id) and byte_size(verifier_id) > 0 and
             byte_size(verifier_id) <= @max_verifier_id_bytes ->
        {:ok, verifier_id}

      _other ->
        {:error,
         "verifier_id must be a non-empty binary of at most #{@max_verifier_id_bytes} bytes"}
    end
  end

  defp mint_expires_at(fields, issued_at) do
    expires_at = Keyword.get(fields, :expires_at)

    cond do
      is_nil(expires_at) -> {:ok, nil}
      representable_datetime?(expires_at) -> mint_expiry_order(expires_at, issued_at)
      true -> {:error, "expires_at must be a DateTime or nil"}
    end
  end

  defp mint_expiry_order(expires_at, issued_at) do
    if DateTime.compare(expires_at, issued_at) in [:eq, :gt] do
      {:ok, expires_at}
    else
      {:error, "expires_at cannot be before issued_at"}
    end
  end

  # A %DateTime{} with forged calendar fields (e.g. month 13) is not a
  # representable instant: DateTime.compare/2 on one raises, and no window
  # would ever admit it. Window probes the same way (valid_datetime?/1);
  # the constructor rejects instead of raising so its tuple contract holds.
  defp representable_datetime?(%DateTime{} = datetime) do
    DateTime.to_unix(datetime, :microsecond)
    true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp representable_datetime?(_datetime), do: false
end
