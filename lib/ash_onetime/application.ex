defmodule AshOnetime.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Task.Supervisor, name: AshOnetime.TaskSupervisor}],
      strategy: :one_for_one,
      name: AshOnetime.Supervisor
    )
  end
end
