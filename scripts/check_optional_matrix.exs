defmodule AshOnetime.OptionalMatrix do
  @moduledoc false

  @cases [
    {"none", [], %{plug: false, oban: false, igniter: false}},
    {"plug", [{:plug, "~> 1.20"}], %{plug: true, oban: false, igniter: false}},
    {"oban", [{:oban, "~> 2.23"}], %{plug: false, oban: true, igniter: false}},
    {"igniter", [{:igniter, "~> 0.8"}], %{plug: false, oban: false, igniter: true}},
    {"all", [{:plug, "~> 1.20"}, {:oban, "~> 2.23"}, {:igniter, "~> 0.8"}],
     %{plug: true, oban: true, igniter: true}}
  ]

  def main do
    package = File.cwd!()

    temporary =
      Path.join(System.tmp_dir!(), "ash_onetime_optional_#{System.unique_integer([:positive])}")

    try do
      Enum.each(@cases, &run_case!(&1, package, temporary))
      IO.puts("optional dependency matrix passed: none, plug, oban, igniter, all")
    after
      File.rm_rf!(temporary)
    end
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
    IO.puts("optional case #{name}: \#{inspect(actual)}")
    """

    command!(name, project, environment, ["run", "--no-compile", "-e", expression])
  end

  defp command!(name, project, environment, arguments) do
    {output, status} =
      System.cmd("mix", arguments, cd: project, env: environment, stderr_to_stdout: true)

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
