defmodule AshOnetime.DocumentationCurrencyTest do
  use ExUnit.Case, async: true

  @version Mix.Project.config() |> Keyword.fetch!(:version)
  @parsed_version Version.parse!(@version)
  @minor_requirement "~> #{@parsed_version.major}.#{@parsed_version.minor}"

  @installation_surfaces [
    "documentation/getting-started.md",
    "documentation/upgrading.md",
    "documentation/livebooks/idempotency.livemd",
    "documentation/livebooks/nonces.livemd",
    "documentation/livebooks/external-recovery.livemd"
  ]

  test "public installation surfaces select the current package minor" do
    expected = ~s({:ash_onetime, "#{@minor_requirement}"})

    for path <- @installation_surfaces do
      source = File.read!(path)

      assert source =~ expected,
             "#{path} must install the current package minor with #{expected}"
    end
  end

  test "README, upgrading guide, and changelog name the current package version" do
    assert File.read!("README.md") =~ "current package release is [v#{@version}"
    assert File.read!("documentation/upgrading.md") =~ "current package release is v#{@version}"
    assert File.read!("CHANGELOG.md") =~ "## v#{@version} —"
  end
end
