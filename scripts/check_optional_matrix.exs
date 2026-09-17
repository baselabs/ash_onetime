Code.require_file("#{__DIR__}/portable.exs")

defmodule AshOnetime.OptionalMatrix do
  @moduledoc false

  # The expected map is the module-presence contract (which optional integrations
  # compile); the resolved-version assertions below additionally observe that the
  # resolved versions are at or above the security floors. Version resolution alone
  # cannot prove ash_onetime's requirements CAUSE that — the newest release in each
  # range is already patched — so the conflict cases below pin advised versions
  # exactly and assert resolution FAILS: that failure can only come from
  # ash_onetime's own requirements intersecting the pin to nothing (ADR 0004).
  @cases [
    {"none", [], %{plug: false, oban: false, igniter: false}},
    {"plug", [{:plug, "~> 1.20"}], %{plug: true, oban: false, igniter: false}},
    {"oban", [{:oban, "~> 2.23"}], %{plug: false, oban: true, igniter: false}},
    {"igniter", [{:igniter, "~> 0.8"}], %{plug: false, oban: false, igniter: true}},
    {"all", [{:plug, "~> 1.20"}, {:oban, "~> 2.23"}, {:igniter, "~> 0.8"}],
     %{plug: true, oban: true, igniter: true}},
    {"mint-pin", [{:mint, "~> 1.9"}], %{plug: false, oban: false, igniter: false}}
  ]

  # Exact advised pins that must CONFLICT with ash_onetime's published floors: a
  # consumer cannot hold these versions alongside this package. deps.get failing is
  # the non-vacuous proof the floors bind in a real resolution.
  @conflict_cases [
    {"igniter-conflict", {:igniter, "== 0.8.3"}},
    {"mint-conflict", {:mint, "== 1.9.3"}}
  ]

  # The generated .app's runtime applications: the runtime:true deps plus the
  # :crypto/:logger extra applications and the always-present VM applications.
  @owned_applications [
    :ash,
    :ash_postgres,
    :crypto,
    :ecto_sql,
    :elixir,
    :jason,
    :kernel,
    :logger,
    :postgrex,
    :spark,
    :stdlib,
    :telemetry
  ]

  def main do
    package = File.cwd!()

    temporary =
      Path.join(System.tmp_dir!(), "ash_onetime_optional_#{System.unique_integer([:positive])}")

    try do
      Enum.each(@cases, &run_case!(&1, package, temporary))
      Enum.each(@conflict_cases, &run_conflict_case!(&1, package, temporary))

      IO.puts(
        "optional dependency matrix passed: none, plug, oban, igniter, all, mint-pin" <>
          " (+ conflict proofs: igniter-conflict, mint-conflict)"
      )
    after
      File.rm_rf!(temporary)
    end
  end

  defp run_conflict_case!({name, pinned}, package, temporary) do
    project = Path.join(temporary, name)
    File.mkdir_p!(Path.join(project, "lib"))
    File.write!(Path.join(project, "mix.exs"), mixfile(package, [pinned]))
    File.write!(Path.join(project, "lib/consumer.ex"), "defmodule OptionalConsumer do\nend\n")

    environment = [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", Path.join(project, "_build")},
      {"MIX_DEPS_PATH", Path.join(project, "deps")}
    ]

    {output, status} =
      AshOnetime.Portable.cmd("mix", ["deps.get"],
        cd: project,
        env: environment,
        stderr_to_stdout: true
      )

    IO.puts(output)

    if status == 0 do
      raise "conflict case #{name} resolved an advised pin (#{inspect(pinned)}) — " <>
              "ash_onetime's security floor did not participate in resolution"
    end

    unless output =~ "version solving failed" do
      raise "conflict case #{name} failed deps.get for an unexpected reason (expected " <>
              "a version-resolution conflict, got the output above)"
    end

    IO.puts("conflict case #{name}: advised pin correctly refused by the security floor")
  end

  defp run_case!({name, dependencies, expected}, package, temporary) do
    project = Path.join(temporary, name)
    File.mkdir_p!(Path.join(project, "lib"))
    File.write!(Path.join(project, "mix.exs"), mixfile(package, dependencies))
    File.write!(Path.join(project, "lib/consumer.ex"), "defmodule OptionalConsumer do\nend\n")

    environment = [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", Path.join(project, "_build")},
      {"MIX_DEPS_PATH", Path.join(project, "deps")}
    ]

    command!(name, project, environment, ["deps.get"])
    command!(name, project, environment, ["compile", "--warnings-as-errors"])

    expression = """
    actual = %{
      cache: Code.ensure_loaded?(AshOnetime.Cache.None),
      plug: Code.ensure_loaded?(AshOnetime.Plug),
      oban: Code.ensure_loaded?(AshOnetime.Oban.CleanupWorker),
      igniter:
        Code.ensure_loaded?(Mix.Tasks.AshOnetime.Install) and
          function_exported?(Mix.Tasks.AshOnetime.Install, :igniter, 1)
    }
    expected = #{inspect(Map.put(expected, :cache, true))}
    if actual != expected, do: raise("optional module mismatch: \#{inspect(actual)}")

    # Exact allowlist: proves the instrument sees the list (kernel et al. are always
    # present) and catches any new dependency leaking into the runtime closure.
    applications = Application.spec(:ash_onetime, :applications) |> Enum.sort()
    if applications != #{inspect(@owned_applications)} do
      raise("ash_onetime runtime applications drifted: \#{inspect(applications)}")
    end

    # Security floors bind in a REAL consumer resolution (ADR 0004): the consumer
    # pins the pre-floor ranges on purpose, so a green run proves ash_onetime's own
    # requirements force the patched versions.
    resolved = fn app -> app |> Application.spec(:vsn) |> List.to_string() end

    if actual.igniter do
      unless Version.match?(resolved.(:igniter), ">= 0.8.4") do
        raise("igniter resolved to \#{resolved.(:igniter)} — the security floor did not bind")
      end
    end

    if Code.ensure_loaded?(Mint.HTTP) do
      unless Version.match?(resolved.(:mint), ">= 1.10.0") do
        raise("mint resolved to \#{resolved.(:mint)} — the security floor did not bind")
      end
    end

    if #{name == "mint-pin"} do
      unless Code.ensure_loaded?(Mint.HTTP) and Version.match?(resolved.(:mint), ">= 1.10.0") do
        raise("mint-pin case: mint must resolve to >= 1.10.0 over the consumer's ~> 1.9 pin")
      end
    end

    IO.puts("optional case #{name}: \#{inspect(actual)} mint resolution checked")
    """

    command!(name, project, environment, ["run", "--no-compile", "-e", expression])
  end

  defp command!(name, project, environment, arguments) do
    {output, status} =
      AshOnetime.Portable.cmd("mix", arguments,
        cd: project,
        env: environment,
        stderr_to_stdout: true
      )

    IO.puts(output)
    if status != 0, do: raise("optional case #{name} failed: mix #{Enum.join(arguments, " ")}")
  end

  defp mixfile(package, dependencies) do
    dependencies = [{:ash_onetime, [path: package]} | dependencies]

    rendered =
      Enum.map_join(dependencies, ",\n      ", fn
        {name, options} when is_list(options) -> inspect({name, options})
        dependency -> inspect(dependency)
      end)

    """
    defmodule OptionalConsumer.MixProject do
      use Mix.Project

      def project do
        [app: :optional_consumer, version: "0.1.0", elixir: "~> 1.20", deps: deps()]
      end

      def application, do: [extra_applications: [:logger]]

      defp deps do
        [
          #{rendered}
        ]
      end
    end
    """
  end
end

AshOnetime.OptionalMatrix.main()
