defmodule AshOnetime.CallbackOwnerTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Callback

  test "a killed caller leaves no supervised callback or owner monitor behind" do
    owner = self()
    initial = Task.Supervisor.children(AshOnetime.TaskSupervisor)

    {caller, caller_ref} =
      spawn_monitor(fn ->
        Callback.run(fn ->
          send(owner, {:worker, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:worker, worker}
    children = Task.Supervisor.children(AshOnetime.TaskSupervisor) -- initial
    monitors = Enum.map(children, &{&1, Process.monitor(&1)})

    on_exit(fn ->
      Enum.each(children, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      refute Process.alive?(pid)
    end

    refute Process.alive?(worker)
    assert Task.Supervisor.children(AshOnetime.TaskSupervisor) == initial
  end
end
