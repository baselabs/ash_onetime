defmodule AshOnetime.GenericAction do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context) do
    {:error,
     AshOnetime.Error.new(:admission_unavailable, "keyed-effect admission is unavailable")}
  end
end
