defmodule AshOnetime.Test.MutationFormatter do
  @moduledoc false
  use GenServer

  @impl true
  def init(_options), do: {:ok, nil}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, state) do
    for {_kind, error, stacktrace} <- failures do
      record = AshOnetime.Test.TestFormatter.failure(test, error, stacktrace)

      IO.puts("\nASH_ONETIME_TEST_FAILURE=" <> Jason.encode!(record))
    end

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: AshOnetime.Test.ExitBoundary.Diagnostics.status(status)
end
