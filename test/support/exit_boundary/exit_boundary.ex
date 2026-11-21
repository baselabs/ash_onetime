defmodule AshOnetime.Test.ExitBoundary do
  @moduledoc false

  # §2.7.8, one observed run. `observe/3` spawns the caller (the root), has it prepare
  # everything the run must not observe (its repository, the planted canaries, the
  # subject), arms the collector on it, releases it, and returns the result the root saw,
  # its residue count and the drained snapshot, annotated.
  #
  # Every module of every loaded application is loaded before the collector starts, so a
  # module loaded during the run is one the run itself caused (E18), not one a dependency
  # happened to load lazily (a query builder's first use, a protocol's implementation).

  alias AshOnetime.Test.ExitBoundary.{Capture, Collector, Diagnostics, Root}

  @deadline 10_000

  defmodule Run do
    @moduledoc false
    # `result` is what the boundary function returned to the root; `residue` the count of
    # delivery entries left in the root's dictionary; `events` the annotated snapshot;
    # `snapshot` the raw drained snapshot (its ledger and its process set).
    defstruct [:result, :residue, :events, :snapshot, :fixture, :backtrace_depth, :pattern_probe]
  end

  @doc """
  Observes one run. `setup` runs in the root before arming and returns the state
  `invoke` receives; `invoke` is the run. `spec` names the host modules (`:host`, the
  producer or the external effect) and the package callback modules (`:callbacks`).
  """
  def observe(setup, invoke, spec) when is_function(setup, 0) and is_function(invoke, 1) do
    preload!(spec)
    test = self()
    control = make_ref()
    depth = :erlang.system_flag(:backtrace_depth, 64)
    {root, monitor} = spawn_monitor(fn -> Root.start(test) end)

    try do
      send(root, {:setup, test, setup, invoke, control})
      await_ready(root, monitor)

      frames = Capture.frames(spec.host, spec.callbacks) ++ Map.get(spec, :frames, [])

      # U10 attaches both native patterns before releasing the same root. The
      # passive session drains its own fences after the controlling session has
      # stopped the root; it never participates in the application's execution.
      probe =
        if Map.get(spec, :compare_pure?, false) do
          probe = Collector.start(frames, @deadline, include_pure?: true, passive?: true)
          :ok = Collector.arm(probe, root)
          probe
        end

      collector =
        Collector.start(frames, @deadline, include_pure?: Map.get(spec, :include_pure?, false))

      :ok = Collector.arm(collector, root)
      {result, :post_drain} = await_result(root, monitor)

      case Collector.snapshot(collector, @deadline) do
        {:ok, snapshot} ->
          pattern_probe =
            if probe do
              case Collector.snapshot(probe, @deadline) do
                {:ok, captured} ->
                  Capture.annotate(captured, spec)

                {:error, reason} ->
                  raise "U10 pattern probe did not drain: #{Diagnostics.render(reason)}"
              end
            end

          %Run{
            result: result,
            residue: snapshot.residue,
            backtrace_depth: 64,
            events: Capture.annotate(snapshot, spec),
            snapshot: snapshot,
            pattern_probe: pattern_probe,
            fixture: %{control: control, observer: test, collector: collector}
          }

        {:error, reason} ->
          raise ExUnit.AssertionError,
            message: "the run did not reach the terminal boundary: #{Diagnostics.render(reason)}"
      end
    after
      Process.demonitor(monitor, [:flush])
      Process.exit(root, :kill)
      :erlang.system_flag(:backtrace_depth, depth)
    end
  end

  defp await_ready(root, monitor) do
    receive do
      {:root_ready, ^root} ->
        :ok

      {:DOWN, ^monitor, :process, ^root, reason} ->
        IO.puts("ROOT_SETUP_EXIT: " <> Diagnostics.render(Diagnostics.exit_summary(reason)))
        raise "the root stopped in setup: #{class(reason)}"
    after
      @deadline -> raise "the root did not finish its setup"
    end
  end

  defp await_result(root, monitor) do
    receive do
      {:result, ^root, result, residue} ->
        {result, residue}

      {:DOWN, ^monitor, :process, ^root, reason} ->
        raise "the root stopped in the run: #{class(reason)}"
    after
      @deadline -> raise "the run did not return"
    end
  end

  # An exit reason names its class, never its terms.
  defp class({%{__struct__: struct}, _stack}), do: inspect(struct)
  defp class(reason) when is_atom(reason), do: inspect(reason)
  defp class(reason) when is_tuple(reason), do: "tuple/#{tuple_size(reason)}"
  defp class(_reason), do: "term"

  # Every module the run may call is loaded before tracing starts: the package, Ash and
  # its data layer, the test's support modules, and the host modules.
  defp preload!(spec) do
    applications = Application.loaded_applications()
    key = {__MODULE__, :preloaded, applications}

    unless Process.get(key) do
      for {app, _description, _version} <- applications,
          {:ok, modules} <- [:application.get_key(app, :modules)],
          module <- modules do
        Code.ensure_loaded(module)
      end

      Process.put(key, true)
    end

    for module <- spec.host ++ spec.callbacks, do: Code.ensure_loaded!(module)
    :ok
  end
end
