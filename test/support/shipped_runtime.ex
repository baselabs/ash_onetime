defmodule AshOnetime.Test.ShippedRuntime do
  @moduledoc false
  @directory Path.expand("fixtures/shipped/runtime_v1_9_2", __DIR__)
  @namespace AshOnetimeV1_9_2

  def load! do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> compile!()
      binaries -> binaries
    end
  end

  defp compile! do
    manifest = @directory |> Path.join("sources.json") |> File.read!() |> Jason.decode!()
    directory = Path.join(System.tmp_dir!(), "ao_runtime_#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(directory, "beam"))

    try do
      files =
        for source <- manifest["sources"] do
          bytes = File.read!(Path.join(@directory, source["path"] <> ".eex"))
          digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

          if digest != source["sha256"],
            do: raise("historical runtime digest mismatch: #{source["path"]}")

          quoted =
            bytes
            |> Code.string_to_quoted!()
            |> Macro.prewalk(fn
              {:__aliases__, metadata, [:AshOnetime | rest]} ->
                {:__aliases__, metadata,
                 Module.split(@namespace) |> Enum.map(&String.to_atom/1) |> Kernel.++(rest)}

              node ->
                node
            end)

          path = Path.join(directory, Path.basename(source["path"]))
          File.write!(path, Macro.to_string(quoted))
          path
        end

      {:ok, modules, %{runtime_warnings: [], compile_warnings: []}} =
        Kernel.ParallelCompiler.compile_to_path(files, Path.join(directory, "beam"),
          return_diagnostics: true
        )

      binaries =
        Map.new(modules, fn module ->
          path = Path.join([directory, "beam", Atom.to_string(module) <> ".beam"])
          binary = File.read!(path)
          {:module, ^module} = :code.load_binary(module, String.to_charlist(path), binary)
          {module, binary}
        end)

      :persistent_term.put(__MODULE__, binaries)
      binaries
    after
      File.rm_rf!(directory)
      false = File.exists?(directory)
    end
  end
end
