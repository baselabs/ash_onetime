defmodule AshOnetime.ExternalState.MigrationOrderTest do
  use ExUnit.Case, async: false
  alias AshOnetime.Test.Repo
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  setup do
    path = Path.join(System.tmp_dir!(), "ao_migration_order_#{Ecto.UUID.generate()}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, path: path}
  end

  test "one request orders both mandatory upgrades before maintenance", c do
    Generator.run([
      "--repo",
      inspect(Repo),
      "--operation-hold",
      "--maintenance",
      "--maintenance-role",
      "maintainer",
      "--migrations-path",
      c.path,
      "--timestamp",
      "20261116000000"
    ])

    assert [
             "20261116000000_add_ash_onetime_operation_hold.exs",
             "20261116000001_add_ash_onetime_external_state.exs",
             "20261116000002_add_ash_onetime_maintenance.exs"
           ] = Path.wildcard(Path.join(c.path, "*.exs")) |> Enum.map(&Path.basename/1)
  end

  test "maintenance refuses prerequisites timestamped after it", c do
    File.write!(Path.join(c.path, "20261116000003_add_ash_onetime_operation_hold.exs"), "")
    File.write!(Path.join(c.path, "20261116000004_add_ash_onetime_external_state.exs"), "")

    assert_raise Mix.Error, ~r/before.*maintenance/, fn ->
      Generator.run([
        "--repo",
        inspect(Repo),
        "--maintenance",
        "--maintenance-role",
        "maintainer",
        "--migrations-path",
        c.path,
        "--timestamp",
        "20261116000002"
      ])
    end
  end
end
