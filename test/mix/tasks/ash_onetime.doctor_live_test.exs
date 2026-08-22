defmodule Mix.Tasks.AshOnetime.DoctorLiveTest do
  @moduledoc """
  Live schema-currency coverage for `mix ash_onetime.doctor --live`: the full check path
  (repo start tolerance, catalog queries, verdict rendering, exit behavior) against a real
  installed schema, plus the discriminating direction — a schema WITHOUT the install must
  FAIL, which is the upgrade-without-migrating failure mode the check exists to catch.
  """

  use ExUnit.Case, async: false

  alias AshOnetime.Test.{Migration, RealConnection}
  alias Mix.Tasks.AshOnetime.Doctor

  setup_all do
    installation = Migration.install_generated!()
    on_exit(fn -> Migration.uninstall_generated!(installation) end)
    {:ok, schema: installation.schema}
  end

  test "--live passes every schema verdict on a current install", %{schema: schema} do
    Mix.Task.reenable("ash_onetime.doctor")

    output =
      capture_io(fn ->
        RealConnection.with_connection(fn ->
          assert :ok =
                   Doctor.run(["--repo", "AshOnetime.Test.Repo", "--live", "--prefix", schema])
        end)
      end)

    assert output =~ "[OK]  logical_partition column present on both claim tables"
    assert output =~ "[OK]  ash_onetime_response_payloads table present"
    assert output =~ "[OK]  ash_onetime_response_payloads_default partition present"
    assert output =~ "[OK]  cleanup/reap functions present with exact arities"
    assert output =~ "[OK]  delete-guard triggers present"
    assert output =~ "all checks passed"
  end

  test "--live fails closed on a schema without the install (upgrade-without-migrating)" do
    Mix.Task.reenable("ash_onetime.doctor")

    # FAIL verdict lines render on stderr (Mix.shell().error, matching the floor check's
    # convention), which capture_io does not capture — the raise plus the schema header
    # prove the live path ran and returned at least one :fail verdict; WHICH facts fail is
    # pinned by the pure-seam describe in doctor_test.
    output =
      capture_io(fn ->
        RealConnection.with_connection(fn ->
          assert_raise Mix.Error, ~r/check\(s\) failed/, fn ->
            Doctor.run([
              "--repo",
              "AshOnetime.Test.Repo",
              "--live",
              "--prefix",
              "doctor_missing_schema"
            ])
          end
        end)
      end)

    assert output =~ ~s{Schema currency (schema "doctor_missing_schema")}
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
