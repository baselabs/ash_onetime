defmodule AshOnetime.Test.RealConnection do
  @moduledoc false
  alias Ecto.Adapters.SQL.Sandbox

  @spec with_connection(module(), (-> result)) :: result when result: var
  def with_connection(repo \\ AshOnetime.Test.Repo, callback) do
    :ok = Sandbox.checkout(repo, sandbox: false)

    try do
      callback.()
    after
      Sandbox.checkin(repo)
    end
  end
end
