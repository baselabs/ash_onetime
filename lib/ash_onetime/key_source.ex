defmodule AshOnetime.KeySource do
  @moduledoc "Closed key-source algebra used by protected actions."

  @max_sources 16

  @type source ::
          {:client, atom()}
          | {:argument, atom()}
          | {:attribute, atom()}
          | {:external, atom()}
          | {:verified, atom(), module()}
          | {:minted, module()}

  @callback mint(context :: map()) ::
              {:ok, AshOnetime.Verified.t()} | {:error, term()}
  @callback algorithm() :: :hmac_sha256 | :ed25519
  @callback trust_model() :: :same_service | :separated

  @doc """
  Normalizes a key source or list of sources into a validated list.

  Enforces five invariants: non-empty (at least one source), at most `16` sources, no nested
  composites (a source cannot itself be a list), all sources unique, and every source a valid
  tag (`:client`/`:argument`/`:attribute`/`:external`/`:verified`/`:minted`). A single source
  is wrapped in a one-element list. Returns `{:ok, list}` verbatim on success, or
  `{:error, message}` naming the violated invariant.
  """
  @spec normalize(source() | [source()]) :: {:ok, [source()]} | {:error, String.t()}
  def normalize(value) do
    sources = if is_list(value), do: value, else: [value]

    cond do
      sources == [] ->
        {:error, "key must contain at least one source"}

      length(sources) > @max_sources ->
        {:error, "key exceeds the #{@max_sources}-source limit"}

      Enum.any?(sources, &is_list/1) ->
        {:error, "key composites cannot be nested"}

      Enum.uniq(sources) != sources ->
        {:error, "key sources must be unique"}

      true ->
        normalize_sources(sources)
    end
  end

  @doc """
  Extracts the argument and attribute names a list of sources binds, for reference-checking
  against declared action inputs.

  `:client`, `:argument`, `:external`, and `:verified` sources bind argument names;
  `:attribute` sources bind attribute names; `:minted` binds neither (it is a freshly-minted
  trusted source, not an action input). Returns `%{arguments: [atom], attributes: [atom]}`.
  """
  @spec references([source()]) :: %{arguments: [atom()], attributes: [atom()]}
  def references(sources) do
    Enum.reduce(sources, %{arguments: [], attributes: []}, fn
      {:client, name}, refs -> update_in(refs.arguments, &[name | &1])
      {:argument, name}, refs -> update_in(refs.arguments, &[name | &1])
      {:external, name}, refs -> update_in(refs.arguments, &[name | &1])
      {:verified, name, _module}, refs -> update_in(refs.arguments, &[name | &1])
      {:attribute, name}, refs -> update_in(refs.attributes, &[name | &1])
      _source, refs -> refs
    end)
  end

  defp normalize_sources(sources) do
    if Enum.all?(sources, &valid_source?/1) do
      {:ok, sources}
    else
      {:error, "key contains an unsupported source"}
    end
  end

  defp valid_source?({tag, name})
       when tag in [:client, :argument, :attribute, :external] and is_atom(name),
       do: true

  defp valid_source?({:verified, name, module}) when is_atom(name) and is_atom(module), do: true
  defp valid_source?({:minted, module}) when is_atom(module), do: true
  defp valid_source?(_source), do: false
end
