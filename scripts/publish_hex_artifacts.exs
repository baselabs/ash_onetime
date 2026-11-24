# Hex 2.7.0 only. Run from an empty directory with mix run --no-mix-exs.
# Planning and read-back are keyless; only upload reads HEX_API_KEY.
defmodule AshOnetime.PublishHexArtifacts do
  @moduledoc false

  @package "ash_onetime"
  @notice "dispatch again on this commit after approval to finish"

  def main(arguments) do
    if Mix.Project.get() || File.exists?("mix.exs") do
      raise "publication must run without a Mix project"
    end

    case arguments do
      [command, version | _] when command in ["plan", "upload", "read-back"] ->
        require_release!(version)

      _ ->
        :ok
    end

    run(arguments)
  end

  defp run(["plan", version, archive, docs]) do
    {package_bytes, _docs_bytes} = archives!(archive, docs)
    Hex.start()
    {package_state, docs_state} = states!(version, package_bytes)
    output("package", package_state)
    output("docs", docs_state)
  end

  defp run(["upload", version, archive, docs, package_plan, docs_plan])
       when package_plan in ["missing", "served", "staged"] and
              docs_plan in ["missing", "served"] do
    key = System.get_env("HEX_API_KEY")
    if key in [nil, ""], do: raise("HEX_API_KEY is required; publication stopped")

    # Read both inspected files before any upload, then recheck the keyless plan.
    {package_bytes, docs_bytes} = archives!(archive, docs)
    Hex.start()
    auth = [key: key]
    {package_state, docs_state} = states!(version, package_bytes)
    assert_plan!(package_plan, package_state, "package")
    assert_plan!(docs_plan, docs_state, "docs")

    package_state =
      if package_state == :missing do
        # Hex's default is replace=false. Never opt in to replacement.
        accepted!(Hex.API.Release.publish(nil, package_bytes, auth), "package")
      else
        package_state
      end

    # Docs have no replace=false API flag. Check again immediately before their upload;
    # workflow concurrency serializes dispatches, and readable served docs are kept.
    {latest_package_state, has_docs} = release_state!(version, package_bytes)

    if latest_package_state == :missing && package_state != :staged do
      raise "Hex release disappeared before the docs upload; publication stopped"
    end

    docs_state = docs_state!(version)
    assert_docs_available!(has_docs, docs_state)
    assert_plan!(docs_plan, docs_state, "docs")

    docs_state =
      if docs_state == :missing do
        accepted!(
          Hex.API.ReleaseDocs.publish(nil, @package, version, docs_bytes, auth),
          "docs"
        )
      else
        docs_state
      end

    staged = :staged in [package_state, docs_state]
    output("staged", staged)
    if staged, do: IO.puts("::notice::Hex approval pending; #{@notice}")
  end

  defp run(["read-back", version, archive, docs, staged, repository, commit])
       when staged in ["true", "false"] do
    {package_bytes, _docs_bytes} = archives!(archive, docs)
    Hex.start()

    case read_back!(version, package_bytes, 12) do
      {:ready, served_docs} ->
        # Keep exactly the downloaded archive for infra's release assets. No docs digest
        # comparison: ExDoc output can vary between builds of the same commit.
        File.write!(docs, served_docs)
        published_commit = verify_docs!(docs, version, repository, commit)
        output("published_commit", published_commit)
        output("ready", true)
        IO.puts("Hex package digest and served docs provenance verified")

      :pending when staged == "true" ->
        output("ready", false)
        IO.puts("::notice::Hex approval pending; #{@notice}")

      :pending ->
        raise "Hex package or docs are not served after bounded read-back; publication incomplete"
    end
  end

  defp run(_arguments) do
    raise "usage: publish_hex_artifacts.exs plan VERSION PACKAGE DOCS | " <>
            "upload VERSION PACKAGE DOCS PACKAGE_PLAN DOCS_PLAN | " <>
            "read-back VERSION PACKAGE DOCS STAGED REPOSITORY COMMIT"
  end

  defp archives!(archive, docs) do
    {File.read!(archive), File.read!(docs)}
  end

  defp require_release!(version) do
    case Version.parse(version) do
      {:ok, %Version{pre: [], build: nil}} ->
        :ok

      {:ok, %Version{pre: [_ | _]}} ->
        raise "pre-release version #{version} cannot be published; declare a plain release in mix.exs"

      _ ->
        raise "invalid release version; expected a plain release"
    end
  end

  defp states!(version, package_bytes) do
    exists!()
    {package_state, has_docs} = release_state!(version, package_bytes)
    docs_state = docs_state!(version)

    assert_docs_available!(has_docs, docs_state)

    if package_state == :missing && docs_state == :served do
      raise "Hex serves docs without a release; publication refused"
    end

    {package_state, docs_state}
  end

  defp exists! do
    case Hex.API.Package.get(nil, @package) do
      {:ok, {200, _headers, _body}} ->
        :ok

      {:ok, {404, _headers, _body}} ->
        raise "ash_onetime is absent from Hex; refusing to create a package"

      _result ->
        raise "could not confirm ash_onetime exists on Hex; publication refused"
    end
  end

  defp release_state!(version, package_bytes) do
    case Hex.API.Release.get(nil, @package, version) do
      {:ok, {404, _headers, _body}} ->
        {:missing, false}

      {:ok, {200, _headers, body}} when is_map(body) ->
        if body["retirement"], do: raise("Hex release is retired; publication refused")
        assert_digest!(body["checksum"], package_bytes, "Hex release")
        state = if body["status"] == "staged", do: :staged, else: :served
        {state, body["has_docs"] == true}

      _result ->
        raise "could not read the Hex release; publication refused"
    end
  end

  defp docs_state!(version) do
    case served_docs!(version) do
      {:served, _bytes} -> :served
      :missing -> :missing
    end
  end

  defp served_docs!(version) do
    url = "https://repo.hex.pm/docs/#{@package}-#{version}.tar.gz"

    case Hex.HTTP.request(:get, url, [], nil) do
      {:ok, {200, _headers, bytes}} when is_binary(bytes) ->
        readable_docs!(bytes)
        {:served, bytes}

      {:ok, {404, _headers, _body}} ->
        :missing

      _result ->
        raise "could not read served docs; publication refused"
    end
  end

  defp readable_docs!(bytes) do
    case :erl_tar.extract({:binary, :zlib.gunzip(bytes)}, [:memory]) do
      {:ok, _entries} -> :ok
      _result -> raise "served docs are not a readable gzip tar; publication refused"
    end
  rescue
    _error -> raise "served docs are not a readable gzip tar; publication refused"
  end

  defp verify_docs!(docs, version, repository, commit) do
    script = Path.join(repository, "scripts/release_archives.py")

    {result, status} =
      System.cmd(
        "python3",
        [
          script,
          "verify-docs",
          docs,
          version,
          "--repository",
          repository,
          "--dispatched",
          commit
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("served docs provenance refused: #{String.trim(result)}")
    published_commit = String.trim(result)

    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, published_commit) do
      raise "served docs verifier did not return a full commit"
    end

    published_commit
  end

  defp served_state!(url, expected_bytes, label) do
    case Hex.HTTP.request(:get, url, [], nil) do
      {:ok, {200, _headers, bytes}} when is_binary(bytes) ->
        assert_digest!(digest(bytes), expected_bytes, "served #{label}")
        :served

      {:ok, {404, _headers, _body}} ->
        :missing

      _result ->
        raise "could not read served #{label}; publication refused"
    end
  end

  defp read_back!(version, package_bytes, attempts) do
    {release_state, _has_docs} = release_state!(version, package_bytes)

    package_state =
      served_state!(
        "https://repo.hex.pm/tarballs/#{@package}-#{version}.tar",
        package_bytes,
        "package"
      )

    docs_state = served_docs!(version)

    ready =
      release_state == :served && package_state == :served && match?({:served, _}, docs_state)

    cond do
      ready ->
        {:served, bytes} = docs_state
        {:ready, bytes}

      attempts == 1 ->
        :pending

      true ->
        Process.sleep(5_000)
        read_back!(version, package_bytes, attempts - 1)
    end
  end

  defp assert_plan!("missing", _state, _label), do: :ok
  defp assert_plan!(_plan, state, _label) when state in [:served, :staged], do: :ok

  defp assert_plan!(_plan, :missing, label) do
    raise "#{label} disappeared after planning; refusing an unplanned upload"
  end

  defp assert_docs_available!(true, :missing) do
    raise "Hex records docs that the CDN does not yet serve; retry without replacing them"
  end

  defp assert_docs_available!(_has_docs, _state), do: :ok

  defp accepted!({:ok, {code, _headers, body}}, label) when code in 200..299 do
    IO.puts("Hex #{label}: inspected archive accepted")

    if is_map(body) && body["status"] == "staged" do
      IO.puts("::notice::Hex approval pending; #{@notice}")
      :staged
    else
      :served
    end
  end

  defp accepted!(_result, label) do
    # Never print response bodies or authentication data.
    raise "Hex #{label} upload failed; inspect its status before dispatching again"
  end

  defp assert_digest!(actual, expected_bytes, label) do
    unless actual == digest(expected_bytes) do
      raise "#{label} SHA-256 differs; refusing replacement"
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp output(name, value) do
    File.write!(System.fetch_env!("GITHUB_OUTPUT"), "#{name}=#{value}\n", [:append])
  end
end

AshOnetime.PublishHexArtifacts.main(System.argv())
