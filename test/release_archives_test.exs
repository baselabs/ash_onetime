defmodule AshOnetime.ReleaseArchivesTest do
  use ExUnit.Case, async: true

  @script Path.expand("../scripts/release_archives.py", __DIR__)
  @version "1.0.0"
  @pages ["index.html", "readme.html", "changelog.html", "AshOnetime.Resource.html"]

  setup do
    directory =
      Path.join(System.tmp_dir!(), "ash_onetime_archives_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    git(directory, ["init", "--initial-branch=main"])
    File.write!(Path.join(directory, "mix.exs"), "@version \"#{@version}\"\n")
    git(directory, ["add", "mix.exs"])
    ancestor = commit(directory, "Initial version")
    File.write!(Path.join(directory, "history.txt"), "next commit\n")
    git(directory, ["add", "history.txt"])
    head = commit(directory, "Next version")
    git(directory, ["checkout", "--orphan", "unrelated"])
    unrelated = commit(directory, "Unrelated history")
    git(directory, ["checkout", "main"])

    root = Path.join(directory, "doc")
    assets = Path.join(directory, "assets")
    File.mkdir_p!(root)
    File.mkdir_p!(assets)

    for page <- @pages do
      File.write!(Path.join(root, page), "<html>v#{@version}</html>\n")
    end

    context = %{
      directory: directory,
      root: root,
      assets: assets,
      docs: Path.join(assets, "ash_onetime-#{@version}-docs.tar.gz"),
      head: head,
      ancestor: ancestor,
      unrelated: unrelated
    }

    assert {"", 0} = write_release(context, head)
    context
  end

  test "writes the local HEAD outside Actions and inspects its archived provenance", context do
    assert {"", 0} = write_release(context, nil)
    pack(context)
    assert {"", 0} = inspect_docs(context)

    assert manifest(context) == %{
             "package" => "ash_onetime",
             "version" => @version,
             "commit" => context.head
           }

    assert {output, 0} = verify_docs(context)
    assert String.trim(output) == context.head
  end

  test "writes GITHUB_SHA rather than the checkout HEAD", context do
    assert {"", 0} = write_release(context, context.ancestor)
    pack(context)
    assert {"", 0} = inspect_docs(context)
    assert manifest(context)["commit"] == context.ancestor
  end

  test "refuses an invalid build commit instead of falling back to HEAD", context do
    for commit <- ["", "not-a-commit", String.duplicate("g", 40)] do
      {output, status} = write_release(context, commit)
      assert status != 0
      assert output =~ "40-hex git commit"
    end
  end

  test "build inspection and served verification refuse incorrect provenance", context do
    original = manifest(context)

    for {key, value, error} <- [
          {"package", "another_package", "does not name package ash_onetime"},
          {"version", "9.9.9", "does not name version #{@version}"},
          {"commit", "bad", "40-hex git commit"},
          {"commit", nil, "40-hex git commit"}
        ] do
      File.write!(
        Path.join(context.root, "release.json"),
        Jason.encode!(Map.put(original, key, value))
      )

      pack(context)

      for {output, status} <- [inspect_docs(context), verify_docs(context)] do
        assert status != 0
        assert output =~ error
      end
    end
  end

  test "refuses missing or unreadable release.json", context do
    for contents <- [nil, "{", "[]"] do
      path = Path.join(context.root, "release.json")

      if contents do
        File.write!(path, contents)
      else
        File.rm!(path)
      end

      pack(context)

      for {output, status} <- [inspect_docs(context), verify_docs(context)] do
        assert status != 0
        assert output =~ "release.json"
      end
    end
  end

  test "served docs may name the dispatched commit or its ancestor", context do
    for published <- [context.head, context.ancestor] do
      assert {"", 0} = write_release(context, published)
      pack(context)
      assert {output, 0} = verify_docs(context)
      assert String.trim(output) == published
    end
  end

  test "refuses unrelated, descendant and unavailable commits", context do
    for {published, dispatched} <- [
          {context.unrelated, context.head},
          {context.head, context.ancestor},
          {String.duplicate("0", 40), context.head}
        ] do
      assert {"", 0} = write_release(context, published)
      pack(context)
      {output, status} = verify_docs(context, dispatched)
      assert status != 0
      assert output =~ "not the dispatched commit or an ancestor"
    end
  end

  test "refuses an archive without index.html", context do
    File.rm!(Path.join(context.root, "index.html"))
    pack(context)

    for {output, status} <- [inspect_docs(context), verify_docs(context)] do
      assert status != 0
      assert output =~ "index.html"
    end
  end

  test "build inspection still requires versioned pages", context do
    File.write!(Path.join(context.root, "readme.html"), "<html>v0.0.0</html>")
    pack(context)
    {output, status} = inspect_docs(context)
    assert status != 0
    assert output =~ "does not name v#{@version}"

    File.rm!(Path.join(context.root, "readme.html"))
    pack(context)
    {output, status} = inspect_docs(context)
    assert status != 0
    assert output =~ "readme.html"
  end

  test "served docs must be a readable gzip tar", context do
    assert {"", 0} =
             python(
               context.directory,
               """
               import tarfile
               with tarfile.open(sys.argv[2], "w") as archive:
                   archive.add(sys.argv[3], arcname="release.json")
               """,
               [context.docs, Path.join(context.root, "release.json")]
             )

    {_output, status} = verify_docs(context)
    assert status != 0

    pack(context)
    archive = File.read!(context.docs)
    File.write!(context.docs, binary_part(archive, 0, div(byte_size(archive), 2)))
    {_output, status} = verify_docs(context)
    assert status != 0
  end

  test "checksums use the current served archive after it replaces local docs", context do
    package = Path.join(context.assets, "ash_onetime-#{@version}.tar")

    assert {"", 0} =
             python(
               context.directory,
               """
               import tarfile
               with tarfile.open(sys.argv[2], "w") as archive:
                   archive.add("mix.exs", arcname="mix.exs")
               """,
               [package]
             )

    pack(context)
    assert {"", 0} = run(context.directory, ["checksums", context.assets])
    assert_checksums(context, package)

    # A served archive can have different page content. No equality with local docs is required.
    File.write!(Path.join(context.root, "index.html"), "<html>served documentation</html>")
    assert {"", 0} = write_release(context, context.ancestor)
    pack(context)
    assert {_published, 0} = verify_docs(context)
    assert {"", 0} = run(context.directory, ["checksums", context.assets])
    assert_checksums(context, package)
  end

  defp assert_checksums(context, package) do
    expected =
      [package, context.docs]
      |> Enum.sort_by(&Path.basename/1)
      |> Enum.map_join(fn path ->
        digest = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
        "#{digest}  #{Path.basename(path)}\n"
      end)

    assert File.read!(Path.join(context.assets, "SHA256SUMS")) == expected
  end

  defp write_release(context, commit) do
    python(
      context.directory,
      "module['write_release'](Path(sys.argv[2]), sys.argv[3])",
      [context.root, @version],
      [{"GITHUB_SHA", commit}]
    )
  end

  defp manifest(context) do
    context.root |> Path.join("release.json") |> File.read!() |> Jason.decode!()
  end

  defp pack(context) do
    assert {"", 0} =
             python(
               context.directory,
               "module['docs_archive'](Path(sys.argv[2]), Path(sys.argv[3]))",
               [context.root, context.docs]
             )
  end

  defp inspect_docs(context) do
    python(
      context.directory,
      "module['inspect_docs'](Path(sys.argv[2]), sys.argv[3])",
      [context.docs, @version]
    )
  end

  defp verify_docs(context, dispatched \\ nil) do
    # Publication runs outside the repository with git access passed explicitly.
    run(context.assets, [
      "verify-docs",
      context.docs,
      @version,
      "--repository",
      context.directory,
      "--commit",
      dispatched || context.head
    ])
  end

  defp python(directory, code, arguments, environment \\ []) do
    prelude =
      "import runpy, sys\nfrom pathlib import Path\nmodule = runpy.run_path(sys.argv[1])\n"

    System.cmd("python3", ["-I", "-B", "-c", prelude <> code, @script | arguments],
      cd: directory,
      env: environment,
      stderr_to_stdout: true
    )
  end

  defp run(directory, arguments) do
    System.cmd("python3", ["-I", "-B", @script | arguments],
      cd: directory,
      stderr_to_stdout: true
    )
  end

  defp commit(directory, message) do
    git(directory, [
      "-c",
      "user.name=Archive Tests",
      "-c",
      "user.email=archive-tests@example.invalid",
      "commit",
      "--no-gpg-sign",
      "-m",
      message
    ])

    git(directory, ["rev-parse", "HEAD"])
  end

  defp git(directory, arguments) do
    {output, status} = System.cmd("git", arguments, cd: directory, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
