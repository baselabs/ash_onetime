defmodule AshOnetime.Test.ShippedMigrations do
  @moduledoc false

  @directory Path.expand("fixtures/shipped", __DIR__)
  @fixtures %{
    "v0.1.0" => "initial",
    "v0.2.0" => "response_index",
    "v0.6.0" => "scoped_response_lookup",
    "v1.1.0" => "logical_partition",
    "v1.8.0" => "fact_tables",
    "v1.9.0" => "fact_generator",
    "v1.10.0" => "operation_hold"
  }

  # The files are unmodified git blobs. Only the generator's module identity
  # and template lookup move; its option validation and rendering run as shipped.
  def render(release, function, repo, options) do
    fixture_directory = Path.join(@directory, Map.fetch!(@fixtures, release))
    directory = Path.join(System.tmp_dir!(), "ao_shipped_#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    generator = Module.concat(__MODULE__, "Generator#{System.unique_integer([:positive])}")

    try do
      for file <- Path.wildcard(Path.join(fixture_directory, "*.eex")) do
        File.cp!(file, Path.join(directory, Path.basename(file, ".eex")))
      end

      source =
        directory
        |> Path.join("generator.ex")
        |> File.read!()
        |> String.replace(
          "defmodule Mix.Tasks.AshOnetime.Gen.Migrations do",
          "defmodule #{inspect(generator)} do"
        )

      quoted =
        source
        |> Code.string_to_quoted!()
        |> Macro.prewalk(fn
          {:defp, _, [{:template_path, _, [_]}, _]} ->
            quote do
              defp template_path(name), do: Path.join(unquote(directory), name)
            end

          node ->
            node
        end)

      Code.compile_quoted(quoted)

      apply(generator, function, [repo, options])
    after
      :code.purge(generator)
      :code.delete(generator)
      File.rm_rf!(directory)
      false = File.exists?(directory)
    end
  end
end
