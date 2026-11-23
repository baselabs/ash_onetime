defmodule AshOnetime.Test.Application do
  @moduledoc false

  use Application

  alias AshOnetime.Test.ExitBoundary.ConnectionHistory

  @impl Application
  def start(_type, _args) do
    children = [
      {ConnectionHistory, owner: self(), name: ConnectionHistory},
      AshOnetime.Test.Repo
    ]

    Supervisor.start_link(children,
      strategy: :rest_for_one,
      name: AshOnetime.Test.Supervisor
    )
  end
end
