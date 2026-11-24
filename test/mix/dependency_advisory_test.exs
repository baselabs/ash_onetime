defmodule AshOnetime.DependencyAdvisoryTest do
  use ExUnit.Case, async: true

  @osv_url "https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip"

  test "declared Hex requirements exclude releases affected by OSV advisories" do
    assert {:ok, _applications} = Application.ensure_all_started(:inets)
    assert {:ok, _applications} = Application.ensure_all_started(:ssl)

    requirements =
      Map.new(Mix.Project.config()[:deps], &{Atom.to_string(elem(&1, 0)), elem(&1, 1)})
      |> Map.replace!("ash", AshOnetime.MixProject.consumer_ash_requirement())

    advisories = advisories_by_package(requirements)
    assert map_size(advisories) > 0, "#{@osv_url} yielded no advisories for declared dependencies"

    violations =
      advisories
      |> Enum.sort()
      |> Enum.flat_map(fn {package, advisories} ->
        requirement = Map.fetch!(requirements, package)
        versions = admitted_releases(package, requirement)

        for {id, affected} <- advisories,
            vulnerable = vulnerable_releases(versions, affected, package, id),
            vulnerable != [] do
          "#{package} #{requirement} admits releases affected by #{id}: " <>
            Enum.join(vulnerable, ", ")
        end
      end)

    assert violations == [], Enum.join(violations, "\n")
  end

  defp advisories_by_package(requirements) do
    assert {:ok, entries} = :zip.extract(fetch!(@osv_url), [:memory]),
           "could not extract advisory archive from #{@osv_url}"

    for {filename, json} <- entries,
        :filename.extension(filename) == ~c".json",
        advisory = Jason.decode!(json),
        not Map.has_key?(advisory, "withdrawn"),
        affected <- Map.get(advisory, "affected", []),
        %{"ecosystem" => "Hex", "name" => package} <- [affected["package"]],
        Map.has_key?(requirements, package),
        reduce: %{} do
      packages ->
        entry = {Map.fetch!(advisory, "id"), affected}
        Map.update(packages, package, [entry], &[entry | &1])
    end
  end

  defp admitted_releases(package, requirement) do
    url = "https://hex.pm/api/packages/#{package}"
    assert %{"releases" => releases} = url |> fetch!() |> Jason.decode!()
    assert is_list(releases) and releases != [], "#{url} returned no release list"

    requirement = Version.parse_requirement!(requirement)

    releases
    |> Enum.map(fn release -> Map.fetch!(release, "version") end)
    |> Enum.filter(&Version.match?(&1, requirement, allow_pre: false))
  end

  defp vulnerable_releases(releases, affected, package, id) do
    versions = Map.get(affected, "versions", [])

    ranges =
      for %{"type" => type, "events" => events} <- Map.get(affected, "ranges", []),
          type in ["SEMVER", "ECOSYSTEM"] do
        {limits, ordered} = Enum.split_with(events, &Map.has_key?(&1, "limit"))

        ordered =
          ordered
          |> Enum.map(&parse_event/1)
          |> Enum.sort_by(&elem(&1, 1), Version)

        {limits, ordered}
      end

    assert versions != [] or ranges != [], "#{package} advisory #{id} has no release version data"

    Enum.filter(releases, fn release ->
      release in versions or Enum.any?(ranges, &in_range?(release, &1))
    end)
  end

  # OSV treats 0 as the beginning of the version history, including pre-releases.
  defp parse_event(%{"introduced" => "0"}), do: {"introduced", Version.parse!("0.0.0-0")}

  defp parse_event(event) do
    [{kind, version}] = Map.to_list(event)
    {kind, Version.parse!(version)}
  end

  defp in_range?(release, {limits, events}) do
    before_limit? = limits == [] or Enum.any?(limits, &before_limit?(release, &1))

    before_limit? and
      Enum.reduce(events, false, fn
        {"introduced", version}, affected ->
          affected or Version.compare(release, version) != :lt

        {"fixed", version}, affected ->
          affected and Version.compare(release, version) == :lt

        {"last_affected", version}, affected ->
          affected and Version.compare(release, version) != :gt
      end)
  end

  defp before_limit?(release, %{"limit" => limit}) do
    limit == "*" or Version.compare(release, limit) == :lt
  end

  defp fetch!(url) do
    options = [
      ssl: :httpc.ssl_verify_host_options(true),
      connect_timeout: 10_000,
      timeout: 30_000,
      autoredirect: false
    ]

    request = {String.to_charlist(url), [{~c"user-agent", ~c"ash_onetime-dependency-advisories"}]}

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_protocol, 200, _reason}, _headers, body}} ->
        body

      {:ok, {{_protocol, status, _reason}, _headers, _body}} ->
        flunk("GET #{url} failed: HTTP #{status}")

      {:error, reason} ->
        flunk("GET #{url} failed: #{inspect(reason)}")
    end
  end
end
