defmodule AshOnetime.Change do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    if match?(%AshOnetime.Resource.Protection{}, opts[:protection]) do
      {:ok, opts}
    else
      {:error, "missing normalized protection"}
    end
  end

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset, unavailable_error())
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: {:error, unavailable_error()}

  defp unavailable_error do
    AshOnetime.Error.new(:admission_unavailable, "keyed-effect admission is unavailable")
  end
end
