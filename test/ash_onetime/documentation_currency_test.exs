defmodule AshOnetime.DocumentationCurrencyTest do
  use ExUnit.Case, async: true

  @version Mix.Project.config() |> Keyword.fetch!(:version)
  @parsed_version Version.parse!(@version)
  @release "#{@parsed_version.major}.#{@parsed_version.minor}.#{@parsed_version.patch}"
  @minor_requirement "~> #{@parsed_version.major}.#{@parsed_version.minor}.0"
  @development_notice "This version is in development and is not yet on Hex; use the [published release documentation on HexDocs](https://hexdocs.pm/ash_onetime/)."
  @target_claim ~r/\btargets\s+\[?(v[0-9][0-9A-Za-z+-]*(?:\.[0-9A-Za-z+-]+)*)/i
  @install_claim ~r/\{\s*:ash_onetime\s*,\s*"([^"]*)"/
  @changelog File.read!("CHANGELOG.md")
  @dated_releases Regex.scan(~r/^## v(\d+\.\d+\.\d+) — (.+)$/m, @changelog,
                    capture: :all_but_first
                  )
  @months ~w(January February March April May June July August September October November December)
  @hex_url "https://hex.pm/api/packages/ash_onetime"

  setup_all do
    arguments = ["ls-files", "-z", "--", "*.md", "*.livemd"]
    {output, status} = System.cmd("git", arguments, stderr_to_stdout: true)
    assert status == 0, "git ls-files failed: #{output}"

    documents =
      output
      |> String.split(<<0>>, trim: true)
      |> Enum.reject(&String.starts_with?(&1, ["deps/", "_build/"]))
      |> Map.new(fn path ->
        source = File.read!(path)

        # Only the first changelog section describes this checkout; later sections are history.
        source =
          if path == "CHANGELOG.md" do
            source |> String.split(~r/(?=^## )/m, parts: 3) |> Enum.take(2) |> Enum.join()
          else
            source
          end

        {path, source}
      end)

    %{documents: documents}
  end

  test "mix.exs declares a plain release or exactly the dev pre-release" do
    parsed = Mix.Project.config() |> Keyword.fetch!(:version) |> Version.parse!()

    assert parsed.pre in [[], ["dev"]] and is_nil(parsed.build),
           "mix.exs version must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-dev; got #{@version}"
  end

  test "the changelog follows the declared development or release version" do
    unreleased = Regex.scan(~r/^## Unreleased — (.+)$/m, @changelog, capture: :all_but_first)
    dates = for [release, date] <- @dated_releases, release == @release, do: date

    if development?() do
      assert unreleased == [[@release]],
             "development requires exactly one Unreleased heading naming #{@release}"

      assert dates == [], "development cannot have a dated v#{@release} release heading"
    else
      assert [date] = dates, "release requires exactly one dated v#{@release} heading"
      assert valid_date?(date), "v#{@release} requires a valid release date; got #{date}"
      refute [@release] in unreleased, "released v#{@release} cannot still be Unreleased"
    end
  end

  test "dated release history and repository tags equal the published Hex releases" do
    published = published_versions()
    versions = Enum.map(@dated_releases, &hd/1)
    dated = MapSet.new(versions)

    assert length(versions) == MapSet.size(dated), "CHANGELOG has duplicate dated releases"

    for [release, date] <- @dated_releases do
      assert valid_date?(date), "v#{release} requires a valid release date; got #{date}"
    end

    url = Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:source_url)
    url = url <> ".git"
    arguments = ["ls-remote", "--tags", "--refs", url]
    {output, status} = System.cmd("git", arguments, stderr_to_stdout: true)

    assert status == 0,
           "git #{Enum.join(arguments, " ")} failed (exit #{status}): #{output}"

    tags = Regex.scan(~r/\trefs\/tags\/v(\d[^\s]+)$/m, output, capture: :all_but_first)
    tags = MapSet.new(tags, &hd/1)

    history =
      if development?() do
        dated
      else
        # The current release qualifies before publication creates its Hex release and tag.
        refute MapSet.member?(published, @release),
               "current release v#{@release} is already on Hex"

        refute MapSet.member?(tags, @release), "current release v#{@release} is already tagged"
        MapSet.delete(dated, @release)
      end

    assert history == published,
           "dated CHANGELOG releases differ from #{@hex_url}: " <>
             "missing headings #{difference(published, history)}; " <>
             "unpublished headings #{difference(history, published)}"

    assert tags == published,
           "release tags at #{url} differ from #{@hex_url}: " <>
             "missing tags #{difference(published, tags)}; " <>
             "unpublished tags #{difference(tags, published)}"
  end

  test "every tracked target claim names the release declared in mix.exs", context do
    claims = claims(context.documents, @target_claim)
    assert claims != [], "no public target claims were discovered"

    for {path, claimed} <- claims do
      assert claimed == "v#{@release}",
             "#{path} targets #{claimed}; mix.exs declares #{@version} (release v#{@release})"
    end
  end

  test "every tracked installation snippet selects the declared release minor", context do
    claims = claims(context.documents, @install_claim)
    assert claims != [], "no public installation snippets were discovered"

    for {path, requirement} <- claims do
      assert requirement == @minor_requirement,
             "#{path} installs #{inspect(requirement)}; expected #{inspect(@minor_requirement)} from mix.exs"
    end
  end

  test "targeted development guides point to published HexDocs and released guides do not",
       context do
    for {path, source} <- context.documents do
      if development?() do
        if Regex.match?(@target_claim, source) do
          assert source =~ @development_notice,
                 "#{path} must carry the exact development notice: #{@development_notice}"
        end
      else
        refute source =~ @development_notice,
               "#{path} still carries the development notice for a released version"
      end
    end
  end

  test "README identifies development before its first usage or install content", context do
    if development?() do
      source = Map.fetch!(context.documents, "README.md")
      {notice_offset, _length} = :binary.match(source, @development_notice)
      [{content_offset, _length}] = Regex.run(~r/^## /m, source, return: :index)

      assert notice_offset < content_offset,
             "README development notice must appear in the introduction before its first section"
    end
  end

  test "docs source links use the release tag or the development branch" do
    docs = Mix.Project.config() |> Keyword.fetch!(:docs)
    expected = if development?(), do: "main", else: "v#{@version}"
    assert Keyword.fetch!(docs, :source_ref) == expected
  end

  defp claims(documents, pattern) do
    for {path, source} <- documents,
        [claim] <- Regex.scan(pattern, source, capture: :all_but_first),
        do: {path, claim}
  end

  defp published_versions do
    assert {:ok, _applications} = Application.ensure_all_started(:inets)
    assert {:ok, _applications} = Application.ensure_all_started(:ssl)

    options = [
      ssl: :httpc.ssl_verify_host_options(true),
      connect_timeout: 10_000,
      timeout: 30_000,
      autoredirect: false
    ]

    headers = [
      {~c"accept", ~c"application/json"},
      {~c"user-agent", ~c"ash_onetime-release-records"}
    ]

    request = {String.to_charlist(@hex_url), headers}

    body =
      case :httpc.request(:get, request, options, body_format: :binary) do
        {:ok, {{_protocol, 200, _reason}, _headers, body}} ->
          body

        {:ok, {{_protocol, status, _reason}, _headers, body}} ->
          flunk("GET #{@hex_url} failed: HTTP #{status}: #{inspect(String.slice(body, 0, 500))}")

        {:error, reason} ->
          flunk("GET #{@hex_url} failed: #{inspect(reason)}")
      end

    assert {:ok, %{"releases" => releases}} = Jason.decode(body),
           "GET #{@hex_url} did not return package release JSON"

    assert is_list(releases) and releases != [], "GET #{@hex_url} returned no release list"

    MapSet.new(releases, fn release ->
      assert %{"version" => version} = release,
             "GET #{@hex_url} returned a release without a version"

      assert {:ok, _version} = Version.parse(version),
             "GET #{@hex_url} returned an invalid version"

      version
    end)
  end

  defp development? do
    parsed = Mix.Project.config() |> Keyword.fetch!(:version) |> Version.parse!()
    parsed.pre == ["dev"]
  end

  defp difference(left, right) do
    left |> MapSet.difference(right) |> Enum.sort() |> inspect()
  end

  defp valid_date?(date) do
    with [_, month, day, year] <- Regex.run(~r/^([A-Za-z]+) (\d{1,2}), (\d{4})$/, date),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, _date} <- Date.new(String.to_integer(year), index + 1, String.to_integer(day)) do
      true
    else
      _ -> match?({:ok, _date}, Date.from_iso8601(date))
    end
  end
end
