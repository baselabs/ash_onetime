defmodule AshOnetime.Delivery.ExitBoundaryControlsTest do
  use ExUnit.Case, async: false

  # §2.7.8, the controls: one per class. With tracing on, the caller pushes its own
  # canary out through the class, and the observer must report it: a hit of that class
  # in the searches, every event claimed, and the run at its terminal boundary (each
  # control ends the process, port or timer it starts). A class whose control is not
  # seen is a class the boundary tests could not see either.
  #
  # Failures name classes and descriptors only, never the canary.

  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.Analysis

  @moduletag exit_boundary: true
  @moduletag exit_boundary_controls: true
  @moduletag timeout: 120_000

  for n <- 1..24 do
    @class :"e#{n}"

    test "E#{n}: a canary pushed through the class is seen" do
      class = @class
      canary = :crypto.strong_rand_bytes(8)

      path =
        Path.join(System.tmp_dir!(), "ash_onetime_control_#{System.unique_integer([:positive])}")

      run =
        ExitBoundary.observe(
          fn -> prepare(class, %{canary: canary, path: path}) end,
          fn state -> push(class, state) end,
          %{host: [], callbacks: []}
        )

      assert run.result == :ok
      assert Analysis.unclaimed(run.events) == []

      hits =
        Analysis.hits(
          run.events,
          Analysis.needles([canary]),
          &Analysis.canary_allowed?(&1, [])
        )

      assert Enum.any?(hits, &(elem(&1, 0) == class)),
             "no #{class} hit; the classes seen: #{inspect(hits |> Enum.map(&elem(&1, 0)) |> Enum.uniq())}"
    end
  end

  # What a control needs before the collector arms: E18's module, compiled here so the
  # control observes only its loading.
  defp prepare(:e18, %{canary: c} = state) do
    module = String.to_atom("ash_onetime_control_" <> Base.encode16(c))

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [init: 0]},
      {:attribute, 1, :on_load, {:init, 0}},
      {:function, 1, :init, 0, [{:clause, 1, [], [], [{:atom, 1, :ok}]}]}
    ]

    {:ok, ^module, beam} = :compile.forms(forms, [:binary])
    Map.merge(state, %{module: module, beam: beam})
  end

  defp prepare(_class, state), do: state

  defp push(:e1, %{canary: c}) do
    send(self(), {:control, c})
    receive do: ({:control, ^c} -> :ok)
  end

  defp push(:e2, %{canary: c}) do
    :erlang.send_after(1, self(), {:control, c})
    receive do: ({:control, ^c} -> :ok)
  end

  defp push(:e3, %{canary: c}) do
    Process.put(:ash_onetime_control, c)
    Process.delete(:ash_onetime_control)
    :ok
  end

  defp push(:e4, %{canary: c}) do
    {pid, monitor} = spawn_monitor(fn -> byte_size(c) end)
    receive do: ({:DOWN, ^monitor, :process, ^pid, :normal} -> :ok)
  end

  defp push(:e5, %{canary: c}) do
    table = :ets.new(:ash_onetime_control, [:private])
    :ets.insert(table, {:control, c})
    :ets.delete(table)
    :ok
  end

  defp push(:e6, %{canary: c}) do
    key = {__MODULE__, :control}
    :persistent_term.put(key, c)
    :persistent_term.erase(key)
    :ok
  end

  defp push(:e7, %{canary: c}) do
    counter = :atomics.new(1, signed: false)
    :atomics.put(counter, 1, :binary.decode_unsigned(c))
    :ok
  end

  defp push(:e8, %{canary: c}) do
    port = Port.open({:spawn, "cat"}, [:binary])
    :erlang.port_set_data(port, c)
    Port.close(port)
    :ok
  end

  defp push(:e9, %{canary: c}) do
    _digest = :crypto.hash(:sha256, c)
    :ok
  end

  defp push(:e10, %{canary: c, path: path}) do
    File.write!(path, c)
    File.rm!(path)
    :ok
  end

  defp push(:e11, %{canary: c}) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, c)
    :ok = :gen_udp.close(socket)
  end

  defp push(:e12, %{canary: c}) do
    _atom = String.to_existing_atom(Base.encode16(c))
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp push(:e13, %{canary: c}) do
    Application.put_env(:ash_onetime, :control, c)
    Application.delete_env(:ash_onetime, :control)
  end

  defp push(:e14, %{canary: c}) do
    :logger.update_process_metadata(%{control: c})
    :logger.unset_process_metadata()
  end

  defp push(:e15, %{canary: c}) do
    _text = :io_lib.format(~c"~p", [c])
    :ok
  end

  defp push(:e16, %{canary: c}) do
    _words = :erts_debug.size(c)
    :ok
  end

  defp push(:e17, %{canary: c}) do
    _where = :code.where_is_file(String.to_charlist(Base.encode16(c)))
    :ok
  end

  # A module with an `on_load` function, loaded as the code server loads one: the load
  # stops at the pending `on_load`, which runs where a NIF library is loaded, and the
  # load is finished after it. (`erlang:load_nif/2` and `erlang:call_on_load_function/1`
  # take no call trace; the finish does.) The module is removed again.
  defp push(:e18, %{module: module, beam: beam}) do
    {:error, :on_load} = :erlang.load_module(module, beam)
    :ok = :erlang.call_on_load_function(module)
    true = :erlang.finish_after_on_load(module, true)
    true = :code.delete(module)
    _purged = :code.purge(module)
    :ok
  end

  defp push(:e19, %{canary: c}) do
    :erlang.process_flag(:priority, c)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp push(:e20, %{canary: c}) do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor = :erlang.monitor(:process, pid, tag: c)
    send(pid, :stop)
    receive do: ({^c, ^monitor, :process, ^pid, :normal} -> :ok)
  end

  defp push(:e21, %{canary: c}) do
    throw(c)
  catch
    ^c -> :ok
  end

  defp push(:e22, %{canary: c}) do
    :erlang.system_info(c)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp push(:e23, %{canary: c}) do
    :erlang.trace_info(self(), c)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp push(:e24, %{canary: c}) do
    :telemetry.execute([:ash_onetime, :control], %{}, %{value: c})
  end
end
