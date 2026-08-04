defmodule AshOnetime.Test.KeyResolver do
  @moduledoc false

  @behaviour AshOnetime.KeyResolver

  @impl AshOnetime.KeyResolver
  def resolve(purpose, key_id, algorithm, %{keys: keys}) when is_map(keys) do
    case Map.fetch(keys, {purpose, key_id, algorithm}) do
      {:ok, material} -> {:ok, material}
      :error -> {:error, :key_not_found}
    end
  end

  def resolve(_purpose, _key_id, _algorithm, _context), do: {:error, :invalid_context}
end
