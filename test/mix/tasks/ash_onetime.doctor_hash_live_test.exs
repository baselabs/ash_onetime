defmodule Mix.Tasks.AshOnetime.DoctorHashLiveTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.Migration
  alias Mix.Tasks.AshOnetime.Doctor

  setup_all do
    installation = Migration.install_generated!(claims: :hash, partitions: 4)
    on_exit(fn -> Migration.uninstall_generated!(installation) end)
    {:ok, schema: installation.schema}
  end

  test "--live passes every schema verdict on a hash-partitioned install", %{schema: schema} do
    Mix.Task.reenable("ash_onetime.doctor")

    output =
      capture_io(fn ->
        Migration.with_runtime_connection(schema, fn ->
          assert :ok =
                   Doctor.run(["--repo", "AshOnetime.Test.Repo", "--live", "--prefix", schema])
        end)
      end)

    assert output =~ "[OK]  logical_partition column present on all three authority tables"
    assert output =~ "[OK]  delete-guard triggers present"
    assert output =~ "all checks passed"
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
