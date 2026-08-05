defmodule Mix.Tasks.AshOnetime.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations
  alias Mix.Tasks.AshOnetime.Install

  @timestamp "20260804000000"
  @partition_start ~D[2026-08-01]

  test "installer requires an explicit repository" do
    assert Install.info([], nil).required == [:repo]
  end

  test "installer imports formatting, wires selected optional dependencies, and reuses generator source" do
    igniter =
      test_project(
        files: %{
          "lib/test/repo.ex" => """
          defmodule Test.Repo do
            use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
          end
          """
        }
      )
      |> Igniter.compose_task("ash_onetime.install", [
        "--repo",
        "Test.Repo",
        "--timestamp",
        @timestamp,
        "--partition-start",
        Date.to_iso8601(@partition_start),
        "--with-plug",
        "--with-oban"
      ])

    assert igniter.issues == []

    formatter = source!(igniter, ".formatter.exs")
    mix = source!(igniter, "mix.exs")
    migration_path = "priv/repo/migrations/#{@timestamp}_install_ash_onetime.exs"
    migration = source!(igniter, migration_path)

    assert formatter =~ "import_deps: [:ash_onetime]"
    assert mix =~ ~s({:plug, "~> 1.20"})
    assert mix =~ ~s({:oban, "~> 2.23"})

    rendered =
      GenerateMigrations.render(Test.Repo,
        partition_start: @partition_start,
        hash_partitions: nil
      )

    assert Code.string_to_quoted!(migration) == Code.string_to_quoted!(rendered)

    refute migration =~ "SECRET"
    refute migration =~ "provider"

    rerun =
      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("ash_onetime.install", [
        "--repo",
        "Test.Repo",
        "--timestamp",
        @timestamp,
        "--partition-start",
        Date.to_iso8601(@partition_start),
        "--with-plug",
        "--with-oban"
      ])

    assert diff(rerun) == ""
  end

  test "migration rendering is byte-deterministic for identical inputs" do
    options = [partition_start: @partition_start, hash_partitions: 4]

    assert GenerateMigrations.render(Test.Repo, options) ==
             GenerateMigrations.render(Test.Repo, options)
  end

  test "installer rejects invalid partition boundaries and calendar timestamps" do
    invalid_partition =
      test_project()
      |> Igniter.compose_task("ash_onetime.install", [
        "--repo",
        "Test.Repo",
        "--timestamp",
        @timestamp,
        "--partition-start",
        "2026-08-02"
      ])

    assert Enum.any?(invalid_partition.issues, &(&1 =~ "first day of a month"))

    invalid_timestamp =
      test_project()
      |> Igniter.compose_task("ash_onetime.install", [
        "--repo",
        "Test.Repo",
        "--timestamp",
        "20260230000000",
        "--partition-start",
        Date.to_iso8601(@partition_start)
      ])

    assert Enum.any?(invalid_timestamp.issues, &(&1 =~ "valid UTC YYYYMMDDHHMMSS"))
  end

  defp source!(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end
end
