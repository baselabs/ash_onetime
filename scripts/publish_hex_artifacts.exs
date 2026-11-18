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

    run(arguments)
  end

  defp run(["plan", version, archive, docs]) do
    {package_bytes, docs_bytes} = archives!(version, archive, docs)
    Hex.start()
    {package_state, docs_state} = states!(version, package_bytes, docs_bytes)
    output("package", package_state)
    output("docs", docs_state)
  end

  defp run(["upload", version, archive, docs, package_plan, docs_plan])
       when package_plan in ["missing", "served", "staged"] and
              docs_plan in ["missing", "served"] do
    key = System.get_env("HEX_API_KEY")
    if key in [nil, ""], do: raise("HEX_API_KEY is required; publication stopped")

    # Read both inspected files before any upload, then recheck the keyless plan.
    {package_bytes, docs_bytes} = archives!(version, archive, docs)
    Hex.start()
    auth = [key: key]
    {package_state, docs_state} = states!(version, package_bytes, docs_bytes)
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
    # workflow concurrency serializes dispatches, and matching served docs are skipped.
    {latest_package_state, has_docs} = release_state!(version, package_bytes)

    if latest_package_state == :missing && package_state != :staged do
      raise "Hex release disappeared before the docs upload; publication stopped"
    end

    docs_state = docs_state!(version, docs_bytes)
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

  defp run(["read-back", version, archive, docs, staged]) when staged in ["true", "false"] do
    {package_bytes, docs_bytes} = archives!(version, archive, docs)
    Hex.start()
    ready = read_back!(version, package_bytes, docs_bytes, 12)
    output("ready", ready)

    cond do
      ready ->
        IO.puts("Hex package and docs read back with the inspected SHA-256 digests")

      staged == "true" ->
        IO.puts("::notice::Hex approval pending; #{@notice}")

      true ->
        raise "Hex package or docs are not served after bounded read-back; publication incomplete"
    end
  end

  defp run(_arguments) do
    raise "usage: publish_hex_artifacts.exs plan VERSION PACKAGE DOCS | " <>
            "upload VERSION PACKAGE DOCS PACKAGE_PLAN DOCS_PLAN | " <>
            "read-back VERSION PACKAGE DOCS STAGED"
  end

  defp archives!(version, archive, docs) do
    case Version.parse(version) do
      {:ok, _version} -> :ok
      :error -> raise "invalid release version"
    end

    {File.read!(archive), File.read!(docs)}
  end

  defp states!(version, package_bytes, docs_bytes) do
    exists!()
    {package_state, has_docs} = release_state!(version, package_bytes)
    docs_state = docs_state!(version, docs_bytes)

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

  defp docs_state!(version, docs_bytes) do
    served_state!("https://repo.hex.pm/docs/#{@package}-#{version}.tar.gz", docs_bytes, "docs")
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

  defp read_back!(version, package_bytes, docs_bytes, attempts) do
    {release_state, _has_docs} = release_state!(version, package_bytes)

    package_state =
      served_state!(
        "https://repo.hex.pm/tarballs/#{@package}-#{version}.tar",
        package_bytes,
        "package"
      )

    docs_state = docs_state!(version, docs_bytes)
    ready = release_state == :served && package_state == :served && docs_state == :served

    if ready || attempts == 1 do
      ready
    else
      Process.sleep(5_000)
      read_back!(version, package_bytes, docs_bytes, attempts - 1)
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
