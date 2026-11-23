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
    assert @parsed_version.pre in [[], ["dev"]] and is_nil(@parsed_version.build),
           "mix.exs version must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-dev; got #{@version}"
  end

  test "the changelog follows the declared development or release version" do
    unreleased = Regex.scan(~r/^## Unreleased — (.+)$/m, @changelog, capture: :all_but_first)
    dates = for [release, date] <- @dated_releases, release == @release, do: date

    if @parsed_version.pre == ["dev"] do
      assert unreleased == [[@release]],
             "development requires exactly one Unreleased heading naming #{@release}"

      assert dates == [], "development cannot have a dated v#{@release} release heading"
    else
      assert [date] = dates, "release requires exactly one dated v#{@release} heading"
      assert valid_date?(date), "v#{@release} requires a valid release date; got #{date}"
      refute [@release] in unreleased, "released v#{@release} cannot still be Unreleased"
    end
  end

  test "dated release history names real repository tags" do
    url = Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:source_url)
    url = url <> ".git"
    arguments = ["ls-remote", "--tags", "--refs", url]
    {output, status} = System.cmd("git", arguments, stderr_to_stdout: true)

    assert status == 0,
           "git #{Enum.join(arguments, " ")} failed (exit #{status}): #{output}"

    tags = Regex.scan(~r/\trefs\/tags\/(v[^\s]+)$/m, output, capture: :all_but_first)
    tags = MapSet.new(tags, &hd/1)

    for [release, date] <- @dated_releases do
      assert valid_date?(date), "v#{release} requires a valid release date; got #{date}"

      if @parsed_version.pre == [] and release == @release do
        # The current release qualifies before publication creates its tag.
        refute MapSet.member?(tags, "v#{release}"),
               "current release v#{release} is already tagged; choose the next version"
      else
        assert MapSet.member?(tags, "v#{release}"),
               "dated CHANGELOG release v#{release} has no release tag at #{url}"
      end
    end
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

  test "targeted development guides point to published HexDocs and released guides do not", context do
    for {path, source} <- context.documents do
      if @parsed_version.pre == ["dev"] do
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
    if @parsed_version.pre == ["dev"] do
      source = Map.fetch!(context.documents, "README.md")
      {notice_offset, _length} = :binary.match(source, @development_notice)
      [{content_offset, _length}] = Regex.run(~r/^## /m, source, return: :index)

      assert notice_offset < content_offset,
             "README development notice must appear in the introduction before its first section"
    end
  end

  test "docs source links use the release tag or the development branch" do
    docs = Mix.Project.config() |> Keyword.fetch!(:docs)
    expected = if @parsed_version.pre == [], do: "v#{@version}", else: "main"
    assert Keyword.fetch!(docs, :source_ref) == expected
  end

  defp claims(documents, pattern) do
    for {path, source} <- documents,
        [claim] <- Regex.scan(pattern, source, capture: :all_but_first),
        do: {path, claim}
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
