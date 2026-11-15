defmodule AshOnetime.Test.ExitBoundary.Root do
  @moduledoc false

  # The caller of one observed run. It is spawned by the test, prepares everything that
  # must not be observed (the frozen clock, the planted canaries, the subject) before the
  # collector arms it, then calls the boundary function. `invoke/2` is traced with
  # `exception_trace`: its call and its return mark the run, and everything the root does
  # after the return is the caller's own.
  #
  # A raise, an exit or a throw out of the run is the run's result. After the return the
  # root starts the control timer, which the ledger must account
  # for, sends the result and its residue count to the test, and stays until the
  # collector has reached the terminal boundary.

  @delivery AshOnetime.Delivery

  def start(test) do
    receive do
      {:setup, ^test, setup, invoke, control} ->
        state = setup.()
        send(test, {:root_ready, self()})

        receive do
          {:go, collector} ->
            result = caught(invoke, state)
            residue = Enum.count(Process.get_keys(), &match?({@delivery, _}, &1))
            :erlang.send_after(1, self(), {:control_timer, control})
            send(test, {:result, self(), result, residue})

            receive do
              {:control_timer, ^control} -> :ok
            end

            receive do
              {:stop, ^collector} -> :ok
            end
        end
    end
  end

  def invoke(invoke, state), do: invoke.(state)

  # A run that raises, exits or throws (a consumer hook that does) returns what it raised
  # as its result, so both sides of a pair compare it like any other.
  defp caught(invoke, state) do
    __MODULE__.invoke(invoke, state)
  catch
    kind, reason -> {:caught, kind, reason}
  end
end
