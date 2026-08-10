defmodule AshOnetime.Scope do
  @moduledoc """
  Closed, explicit scope algebra for collision isolation.

  The `context` map passed to the `resolve/2` callback is the BOUNDED callback context:
  `%{resource:, action:}` — the trusted local facts the admission path derives itself
  (AGENTS.md: "verification callbacks return trusted local facts"). Caller-supplied context
  (actor, tenant, etc.) is NOT forwarded; see `AshOnetime.Verifier` for the same contract.
  """

  @max_components 16

  @type component ::
          {:tenant, module()}
          | {:argument, atom()}
          | {:attribute, atom()}
          | {:static, binary()}

  @callback resolve(Ash.Changeset.t() | Ash.ActionInput.t(), map()) ::
              {:ok, AshOnetime.Canonical.value()} | {:error, term()}

  @spec normalize(term()) :: {:ok, [component()]} | {:error, String.t()}
  def normalize(components) when is_list(components) do
    cond do
      components == [] ->
        {:error, "scope must contain at least one component"}

      length(components) > @max_components ->
        {:error, "scope exceeds the #{@max_components}-component limit"}

      Enum.uniq(components) != components ->
        {:error, "scope components must be unique"}

      Enum.all?(components, &valid_component?/1) ->
        {:ok, components}

      true ->
        {:error, "scope contains an unsupported component"}
    end
  end

  def normalize(_components), do: {:error, "scope must be a nonempty list"}

  @spec references([component()]) :: %{arguments: [atom()], attributes: [atom()]}
  def references(components) do
    Enum.reduce(components, %{arguments: [], attributes: []}, fn
      {:argument, name}, refs -> update_in(refs.arguments, &[name | &1])
      {:attribute, name}, refs -> update_in(refs.attributes, &[name | &1])
      _component, refs -> refs
    end)
  end

  defp valid_component?({:tenant, module}) when is_atom(module), do: true
  defp valid_component?({:argument, name}) when is_atom(name), do: true
  defp valid_component?({:attribute, name}) when is_atom(name), do: true
  defp valid_component?({:static, bytes}) when is_binary(bytes), do: byte_size(bytes) > 0
  defp valid_component?(_component), do: false
end
