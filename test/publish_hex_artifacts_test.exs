defmodule AshOnetime.PublishHexArtifactsTest do
  use ExUnit.Case, async: false

  @script Path.expand("../scripts/publish_hex_artifacts.exs", __DIR__)
  @arguments ["upload", "1.0.0", "package.tar", "docs.tar.gz", "missing", "missing"]

  setup do
    directory =
      Path.join(System.tmp_dir!(), "ash_onetime_upload_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "refuses a Mix project before files, a key, or Hex", %{directory: directory} do
    File.write!(Path.join(directory, "mix.exs"), """
    defmodule UploadRefusal.MixProject do
      use Mix.Project
      def project, do: [app: :upload_refusal, version: "0.1.0"]
    end
    """)

    {output, status} = run(directory, @arguments)
    assert status != 0
    assert output =~ "publication must run without a Mix project"
  end

  test "refuses a missing key before files or Hex", %{directory: directory} do
    {output, status} = run(directory, @arguments)
    assert status != 0
    assert output =~ "HEX_API_KEY is required; publication stopped"
  end

  test "refuses an empty key before files or Hex", %{directory: directory} do
    {output, status} = run(directory, @arguments, "")
    assert status != 0
    assert output =~ "HEX_API_KEY is required; publication stopped"
  end

  test "bad arguments print usage without contacting Hex", %{directory: directory} do
    for arguments <- [[], ["upload"], List.replace_at(@arguments, 4, "replace")] do
      {output, status} = run(directory, arguments)
      assert status != 0
      assert output =~ "usage: publish_hex_artifacts.exs"
    end
  end

  defp run(directory, arguments, key \\ nil) do
    System.cmd("mix", ["run", "--no-mix-exs", @script | arguments],
      cd: directory,
      env: [
        {"HEX_API_KEY", key},
        {"MIX_BUILD_PATH", Path.join(directory, "_build")},
        {"MIX_DEPS_PATH", Path.join(directory, "deps")}
      ],
      stderr_to_stdout: true
    )
  end
end
