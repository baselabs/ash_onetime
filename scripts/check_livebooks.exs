defmodule AshOnetime.LivebookCheck do
  @moduledoc false

  @notebooks ~w(idempotency nonces external-recovery)
  @persisted_outputs %{"idempotency" => 4, "nonces" => 4, "external-recovery" => 4}

  def main(arguments) do
    case arguments do
      [mode] when mode in ["--local", "--published"] ->
        Enum.with_index(@notebooks, fn name, index ->
          path = "documentation/livebooks/#{name}.livemd"

          {output, status} =
            System.cmd("elixir", [__ENV__.file, "--notebook", path, mode],
              env: [
                {"MIX_INSTALL_DIR", install_directory()},
                {"MIX_ENV", "dev"},
                {"MIX_BUILD_PATH", nil},
                {"MIX_DEPS_PATH", nil},
                {"ASH_ONETIME_LIVEBOOK_FORCE", if(index == 0, do: "true", else: "false")},
                {"ASH_ONETIME_ASH_VERSION", nil}
              ],
              stderr_to_stdout: true
            )

          IO.write(output)
          if status != 0, do: raise("Livebook #{name} failed (exit #{status})")
        end)

        IO.puts("livebook checks passed: idempotency, nonces, external-recovery (#{mode})")

      ["--notebook", path, mode] when mode in ["--local", "--published"] ->
        run_notebook!(path, mode)

      _ ->
        raise "usage: elixir scripts/check_livebooks.exs --local | --published"
    end
  end

  defp run_notebook!(path, mode) do
    System.fetch_env!("DATABASE_URL")
    System.put_env("MIX_INSTALL_DIR", install_directory())
    source = File.read!(path)
    digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    cells =
      Regex.scan(
        ~r/^```elixir\n(.*?)^```\n(?:\s*(?:<!-- livebook:\{"output":true\} -->\s*)?```\n(.*?)^```\n)?/ms,
        source,
        return: :index
      )

    if cells == [], do: raise("no Elixir cells found in #{path}")
    outputs = Enum.count(cells, &match?([_, _, {offset, _}] when offset >= 0, &1))
    markers = Regex.scan(~r/^<!-- livebook:\{"output":true\} -->$/m, source) |> length()

    expected_outputs = Map.fetch!(@persisted_outputs, Path.basename(path, ".livemd"))

    unless outputs == expected_outputs and markers == outputs do
      raise "#{path}: expected #{expected_outputs} persisted outputs, found #{outputs} outputs and #{markers} markers"
    end

    IO.puts("LIVEBOOK_OUTPUTS #{path} asserted=#{outputs}")
    IO.puts("LIVEBOOK_SOURCE #{path} sha256=#{digest} cells=#{length(cells)} mode=#{mode}")

    initial = {[], Code.env_for_eval(file: path)}

    try do
      Enum.with_index(cells, 1)
      |> Enum.reduce(initial, fn matches, {binding, environment} ->
        {indices, number} = matches
        [{_, _}, {offset, length} | output] = indices
        code = binary_part(source, offset, length)
        line = source |> binary_part(0, offset) |> String.split("\n") |> length()
        quoted = Code.string_to_quoted!(code, file: path, line: line)

        # Only bootstrap selection changes in candidate mode. The actual notebook
        # cells, bindings, modules, database calls and result assertions execute.
        quoted = if number == 1 and mode == "--local", do: local_package(quoted), else: quoted
        {value, binding, environment} = Code.eval_quoted_with_env(quoted, binding, environment)
        Process.put(:livebook_binding, binding)
        if number == 1, do: assert_package!(mode)
        assert_output!(value, output, source, path, number)
        IO.puts("LIVEBOOK_CELL_PASS #{path} cell=#{number} value=#{inspect(value, limit: 12)}")
        {binding, environment}
      end)

      IO.puts("LIVEBOOK_PASS #{path}")
    after
      cleanup!(Process.get(:livebook_binding, []))
    end
  end

  defp install_directory do
    System.get_env("MIX_INSTALL_DIR") || Path.expand("_build/livebook-install")
  end

  defp local_package(quoted) do
    Macro.prewalk(quoted, fn
      {{:., dot_meta, [{:__aliases__, alias_meta, [:Mix]}, :install]}, meta, [deps, options]} ->
        {{:., dot_meta, [{:__aliases__, alias_meta, [:Mix]}, :install]}, meta,
         [
           deps,
           Keyword.merge(options,
             lockfile: :ash_onetime,
             force: System.get_env("ASH_ONETIME_LIVEBOOK_FORCE", "true") == "true"
           )
         ]}

      {:ash_onetime, requirement} when is_binary(requirement) ->
        {:ash_onetime, [path: File.cwd!()]}

      node ->
        node
    end)
  end

  defp assert_package!(mode) do
    [_, expected] = Regex.run(~r/@version "([^"]+)"/, File.read!("mix.exs"))
    actual = Application.spec(:ash_onetime, :vsn) |> to_string()
    if actual != expected, do: raise("expected ash_onetime #{expected}, loaded #{actual}")
    IO.puts("LIVEBOOK_PACKAGE ash_onetime=#{actual} mode=#{mode}")
  end

  defp assert_output!(value, [{offset, length}], source, path, number) when offset >= 0 do
    output = binary_part(source, offset, length)
    {expected, []} = Code.eval_string(output)

    unless value == expected do
      raise "#{path} cell #{number}: persisted output differs: " <>
              "expected #{inspect(expected)}, got #{inspect(value)}"
    end
  end

  defp assert_output!(_value, _output, _source, _path, _number), do: :ok

  defp cleanup!(binding) do
    if schema = Keyword.get(binding, :schema) do
      unless Regex.match?(~r/^ash_onetime_demo_[a-z0-9_]+$/, schema),
        do: raise("unexpected Livebook schema #{inspect(schema)}")

      if Process.whereis(AshOnetimeDemo.Repo) do
        apply(Ecto.Adapters.SQL, :query!, [
          AshOnetimeDemo.Repo,
          ~s{DROP SCHEMA IF EXISTS "#{schema}" CASCADE},
          []
        ])

        %{rows: [[false]]} =
          apply(Ecto.Adapters.SQL, :query!, [
            AshOnetimeDemo.Repo,
            "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = $1)",
            [schema]
          ])

        IO.puts("LIVEBOOK_SCHEMA_REMOVED #{schema}")
      end
    end

    if temporary = Keyword.get(binding, :temp), do: File.rm_rf!(temporary)
  end
end

AshOnetime.LivebookCheck.main(System.argv())
