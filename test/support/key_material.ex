defmodule AshOnetime.Test.KeyMaterial do
  @moduledoc false

  @behaviour AshOnetime.KeyCustody.Local.Material

  @impl true
  def fetch(purpose, key_id, %{keys: keys}) when is_map(keys) do
    case Map.fetch(keys, {purpose, key_id}) do
      {:ok, material} -> {:ok, material}
      :error -> {:error, :not_found}
    end
  end

  def fetch(_purpose, _key_id, _context), do: {:error, :not_found}
end
