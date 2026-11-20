defmodule AshOnetime.DocumentationCurrencyTest do
  use ExUnit.Case, async: true

  @changelog File.read!("CHANGELOG.md")
  @unreleased Regex.run(~r/^## Unreleased — (\d+\.\d+\.\d+)$/m, @changelog)
  @version if(@unreleased,
             do: List.last(@unreleased),
             else: Mix.Project.config() |> Keyword.fetch!(:version)
           )
  @parsed_version Version.parse!(@version)
  @minor_requirement "~> #{@parsed_version.major}.#{@parsed_version.minor}.0"

  @installation_surfaces [
    "documentation/getting-started.md",
    "documentation/upgrading.md",
    "documentation/livebooks/idempotency.livemd",
    "documentation/livebooks/nonces.livemd",
    "documentation/livebooks/external-recovery.livemd",
    "documentation/livebooks/context-boundary.livemd"
  ]

  test "public installation surfaces select the documented release minor" do
    expected = ~s({:ash_onetime, "#{@minor_requirement}"})

    for path <- @installation_surfaces do
      source = File.read!(path)

      assert source =~ expected,
             "#{path} must install the documented release minor with #{expected}"
    end
  end

  test "README, upgrading guide, and changelog name the documented release version" do
    assert File.read!("README.md") =~ "guide targets [v#{@version}"
    assert File.read!("documentation/upgrading.md") =~ "guide targets v#{@version}"

    assert @changelog =~
             if(@unreleased, do: "## Unreleased — #{@version}", else: "## v#{@version} —")
  end
end
