defmodule AshOnetime.Test.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([AshOnetime.Test.Repo],
      strategy: :one_for_one,
      name: AshOnetime.Test.Supervisor
    )
  end
end
