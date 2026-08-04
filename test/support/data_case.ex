defmodule AshOnetime.Test.DataCase do
  @moduledoc false

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL.Sandbox

  use ExUnit.CaseTemplate

  using do
    quote do
      alias AshOnetime.Test.Repo
    end
  end

  setup tags do
    owner = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end
end
