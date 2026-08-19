defmodule AshOnetime.PackageCheck do
  @moduledoc false

  @outer_entries ["CHECKSUM", "VERSION", "contents.tar.gz", "metadata.config"]
  @required_entries [
    "LICENSE",
    "README.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "usage-rules.md",
    "documentation/dsl.md",
    "documentation/idempotency.md",
    "documentation/one-time-nonces.md",
    "documentation/external-effects.md",
    "documentation/operations.md",
    "documentation/security.md",
    "documentation/dsls/DSL-AshOnetime.Resource.md"
  ]
  @forbidden_prefixes [".forge/", ".git/", "_build/", "config/", "deps/", "scripts/", "test/"]
  @reference_projects ~r/\b(?:ash_age|ash_webhook_it|bounded_authority(?:_protocol)?|core_os|qorpay)\b/i
  @secret_literal ~r/\b(?:api[_-]?key|password|private[_-]?key|secret)\s*[:=]\s*["'][^"']+["']/i
  @provider_crypto ~r/defmodule\s+\S*(?:Stripe|GitHub|Slack|Twilio)\S*(?:Signature|Verifier)/i
  @versioned_identifier ~r/(?:^|[\/_])[^\/]*_v\d+(?:\.|_|\/|$)|\b(?:defmodule|def|defp)\s+\S*(?:_v\d+|V\d+)\b/i

  def main do
    archive = archive!()
    before_digest = digest_file(archive)
    temporary = Path.join(System.tmp_dir!(), "ash_onetime_package_#{unique()}")
    outer = Path.join(temporary, "outer")
    package = Path.join(temporary, "package")

    try do
      File.mkdir_p!(outer)
      File.mkdir_p!(package)
      assert_outer!(archive)
      extract!(archive, outer, false)
      assert_floating_ash_requirement!(Path.join(outer, "metadata.config"))
      contents = Path.join(outer, "contents.tar.gz")
      entries = table!(contents, true) |> file_entries()
      expected = source_entries()

      assert_equal!(
        entries,
        expected,
        "archive entries differ from the reviewed package manifest"
      )

      extract!(contents, package, true)
      assert_bytes!(package, expected)
      inspect_entries!(package, expected)
      smoke_consumer!(package, temporary)

      after_digest = digest_file(archive)
      assert_equal!(after_digest, before_digest, "archive changed while it was being verified")

      IO.puts("package archive SHA-256: #{Base.encode16(before_digest, case: :lower)}")
      IO.puts("package entries verified: #{length(entries)} exact files")
      IO.puts("package consumer: zero-config compile and test passed")
    after
      File.rm_rf!(temporary)
    end
  end

  defp archive! do
    case Path.wildcard("ash_onetime-*.tar") do
      [archive] -> archive
      archives -> raise "expected exactly one ash_onetime archive, found #{length(archives)}"
    end
  end

  defp assert_outer!(archive) do
    archive
    |> table!(false)
    |> file_entries()
    |> assert_equal!(@outer_entries, "outer Hex archive entries are inexact")
  end

  defp source_entries do
    Mix.Project.config()
    |> Keyword.fetch!(:package)
    |> Keyword.fetch!(:files)
    |> Enum.flat_map(fn path ->
      cond do
        File.regular?(path) -> [path]
        File.dir?(path) -> Path.wildcard(Path.join(path, "**/*"), match_dot: true)
        true -> raise "package input does not exist: #{path}"
      end
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp assert_bytes!(package, entries) do
    for entry <- entries do
      source_digest = digest_file(entry)
      package_digest = digest_file(Path.join(package, entry))
      assert_equal!(package_digest, source_digest, "archive byte mismatch for #{entry}")
    end
  end

  defp inspect_entries!(package, entries) do
    for required <- @required_entries do
      unless required in entries, do: raise("required package entry is absent: #{required}")
    end

    for entry <- entries do
      if Enum.any?(@forbidden_prefixes, &String.starts_with?(entry, &1)) do
        raise "forbidden dev/test entry in package: #{entry}"
      end

      source = File.read!(Path.join(package, entry))

      if String.valid?(source) do
        reject_match!(@secret_literal, source, "secret literal", entry)
        reject_match!(@reference_projects, source, "reference-project string", entry)
        reject_match!(@provider_crypto, source, "provider-specific crypto", entry)

        if String.starts_with?(entry, "lib/") or String.starts_with?(entry, "priv/") do
          reject_match!(
            @versioned_identifier,
            entry <> "\n" <> source,
            "versioned identifier",
            entry
          )
        end
      end
    end

    license = File.read!(Path.join(package, "LICENSE"))
    unless license =~ "MIT License", do: raise("LICENSE is not the MIT license")
  end

  defp smoke_consumer!(package, temporary) do
    consumer = Path.join(temporary, "consumer")
    File.mkdir_p!(Path.join(consumer, "test"))

    File.write!(
      Path.join(consumer, "mix.exs"),
      """
      defmodule PackageConsumer.MixProject do
        use Mix.Project

        def project do
          [app: :package_consumer, version: "0.1.0", elixir: "~> 1.20", deps: deps()]
        end

        def application, do: [extra_applications: [:logger]]
        defp deps, do: [{:ash_onetime, path: #{inspect(package)}}]
      end
      """
    )

    File.write!(Path.join(consumer, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(consumer, "test/zero_config_test.exs"),
      """
      defmodule PackageConsumer.ZeroConfigTest do
        use ExUnit.Case, async: true

        test "core package works with no optional dependencies or application config" do
          assert {:ok, <<2, _::binary>>} = AshOnetime.Canonical.encode(1)
          assert :miss = AshOnetime.Cache.None.get(:crypto.strong_rand_bytes(32))
          refute Code.ensure_loaded?(AshOnetime.Plug)
          refute Code.ensure_loaded?(AshOnetime.Oban.CleanupWorker)
          refute function_exported?(Mix.Tasks.AshOnetime.Install, :igniter, 1)
        end
      end
      """
    )

    environment = [
      {"MIX_BUILD_PATH", Path.join(consumer, "_build")},
      {"MIX_DEPS_PATH", Path.join(consumer, "deps")},
      {"MIX_ENV", "test"}
    ]

    command!(consumer, environment, ["deps.get"])
    command!(consumer, environment, ["test"])
  end

  defp command!(directory, environment, arguments) do
    {output, status} =
      System.cmd("mix", arguments, cd: directory, env: environment, stderr_to_stdout: true)

    IO.puts(output)
    if status != 0, do: raise("consumer command failed: mix #{Enum.join(arguments, " ")}")
  end

  defp table!(archive, compressed?) do
    options = if compressed?, do: [:compressed], else: []

    case :erl_tar.table(String.to_charlist(archive), options) do
      {:ok, entries} -> Enum.map(entries, &List.to_string/1)
      {:error, reason} -> raise "cannot inspect #{archive}: #{inspect(reason)}"
    end
  end

  defp extract!(archive, directory, compressed?) do
    options = [{:cwd, String.to_charlist(directory)}]
    options = if compressed?, do: [:compressed | options], else: options

    case :erl_tar.extract(String.to_charlist(archive), options) do
      :ok -> :ok
      {:error, reason} -> raise "cannot extract #{archive}: #{inspect(reason)}"
    end
  end

  defp file_entries(entries),
    do: entries |> Enum.reject(&String.ends_with?(&1, "/")) |> Enum.sort()

  defp reject_match!(pattern, source, description, entry) do
    if Regex.match?(pattern, source), do: raise("#{description} found in #{entry}")
  end

  defp assert_equal!(value, value, _message), do: :ok
  defp assert_equal!(_actual, _expected, message), do: raise(message)

  # The published ash requirement is security surface (D2): a release built with an exact
  # ASH_ONETIME_ASH_VERSION pin exported freezes "== x.y.z" into the hex metadata in place
  # of the floating range. mix.exs rejects out-of-range pins at config evaluation; this
  # asserts the FROZEN METADATA of the archive the battery is about to approve actually
  # carries the floating requirement, whatever the current shell holds.
  @floating_ash_requirement ">= 3.31.3 and < 4.0.0"

  defp assert_floating_ash_requirement!(metadata_path) do
    metadata = File.read!(metadata_path)

    unless metadata =~ "<<\"#{@floating_ash_requirement}\">>" do
      raise "archive ash requirement is not the floating #{@floating_ash_requirement} — the " <>
              "release was built with ASH_ONETIME_ASH_VERSION exported (frozen exact pin); " <>
              "rebuild with the variable unset"
    end
  end

  defp digest_file(path), do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1))
  defp unique, do: System.unique_integer([:positive, :monotonic])
end

AshOnetime.PackageCheck.main()
