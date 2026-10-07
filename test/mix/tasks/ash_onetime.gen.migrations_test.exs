defmodule Mix.Tasks.AshOnetime.Gen.MigrationsTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.Repo
  alias Mix.Tasks.AshOnetime.Gen.LogicalPartitions
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations

  setup do
    temporary =
      Path.join(System.tmp_dir!(), "ash_onetime_generator_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(temporary) end)
    {:ok, temporary: temporary}
  end

  test "generates the reversible unpartitioned migration from the shipped template", %{
    temporary: temporary
  } do
    path = run_generator(temporary, [])
    source = File.read!(path)

    assert source =~ "id uuid PRIMARY KEY"
    refute source =~ "PARTITION BY HASH (operation_hash)"

    assert source =~
             ~S|encoded_response bytea NOT NULL CHECK (octet_length(encoded_response) <= #{@payload_ceiling})|

    assert source =~ "ash_onetime_response_payloads_default"
    assert source =~ "def down do"
  end

  test "generates native hash claim partitions only with a valid paired option", %{
    temporary: temporary
  } do
    path = run_generator(temporary, ["--claims", "hash", "--claim-partitions", "4"])
    source = File.read!(path)

    assert source =~ "PRIMARY KEY (operation_hash, logical_partition, id)"
    assert source =~ "PARTITION BY HASH (operation_hash)"
    assert source =~ "count = 4"
    assert source =~ ~S|FOR VALUES WITH (MODULUS #{count}, REMAINDER #{remainder})|

    second_path = Path.join(temporary, "missing-pair")

    assert_raise Mix.Error, ~r/requires --claim-partitions/, fn ->
      run_generator(second_path, ["--claims", "hash"])
    end

    assert File.ls!(second_path) == []
  end

  test "refuses duplicate install generation", %{temporary: temporary} do
    _path = run_generator(temporary, [])

    assert_raise Mix.Error, ~r/already exists/, fn ->
      run_generator(temporary, [])
    end
  end

  test "generates the existing-install logical partition upgrade", %{temporary: temporary} do
    Mix.Task.reenable("ash_onetime.gen.logical_partitions")

    path =
      LogicalPartitions.run([
        "--repo",
        inspect(Repo),
        "--migrations-path",
        temporary,
        "--timestamp",
        "20260820143000"
      ])

    assert Path.basename(path) == "20260820143000_add_ash_onetime_logical_partitions.exs"
    assert File.read!(path) == GenerateMigrations.render_logical_partition_upgrade(Repo, [])
  end

  test "Hex package unpack contains exactly all migration templates", %{temporary: temporary} do
    package = Path.join(temporary, "package")

    {output, status} =
      System.cmd("mix", ["hex.build", "--unpack", "--output", package],
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

    assert status == 0, output

    templates =
      package
      |> Path.join("priv/templates/**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, package))
      |> Enum.sort()

    assert templates == [
             "priv/templates/migrations/hash_partitioned.exs",
             "priv/templates/migrations/install.exs",
             "priv/templates/migrations/logical_partitions.exs",
             "priv/templates/migrations/roll_forward.exs"
           ]
  end

  defp run_generator(path, extra_arguments) do
    File.mkdir_p!(path)
    Mix.Task.reenable("ash_onetime.gen.migrations")

    GenerateMigrations.run(
      ["--repo", inspect(Repo), "--migrations-path", path] ++ extra_arguments
    )

    [generated] = Path.wildcard(Path.join(path, "*_install_ash_onetime.exs"))
    generated
  end
end
