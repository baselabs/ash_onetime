defmodule Mix.Tasks.AshOnetime.DoctorTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.AshOnetime.Doctor

  describe "input validation" do
    test "raises on missing --repo" do
      Mix.Task.reenable("ash_onetime.doctor")
      assert_raise Mix.Error, ~r/--repo is required/, fn -> Doctor.run([]) end
    end

    test "raises on invalid --prefix (too long)" do
      Mix.Task.reenable("ash_onetime.doctor")
      long = String.duplicate("a", 64)

      assert_raise Mix.Error, ~r/invalid --prefix/, fn ->
        Doctor.run(["--repo", "AshOnetime.Test.Repo", "--prefix", long])
      end
    end

    test "raises on positional args" do
      Mix.Task.reenable("ash_onetime.doctor")

      assert_raise Mix.Error, ~r/invalid ash_onetime doctor arguments/, fn ->
        Doctor.run(["bogus", "--repo", "AshOnetime.Test.Repo"])
      end
    end
  end

  describe "ash floor check" do
    test "passes when Ash is at or above the floor" do
      Mix.Task.reenable("ash_onetime.doctor")

      assert capture_io(fn ->
               Doctor.run(["--repo", "AshOnetime.Test.Repo"])
             end) =~ "[OK]  Ash"
    end
  end

  describe "prefix check" do
    test "passes with a valid prefix" do
      Mix.Task.reenable("ash_onetime.doctor")

      assert capture_io(fn ->
               Doctor.run(["--repo", "AshOnetime.Test.Repo", "--prefix", "tenant_1"])
             end) =~ "[OK]  Prefix"
    end

    test "skips when --prefix not given" do
      Mix.Task.reenable("ash_onetime.doctor")

      output = capture_io(fn -> Doctor.run(["--repo", "AshOnetime.Test.Repo"]) end)
      refute output =~ "[OK]  Prefix"
    end
  end

  describe "oban queue advisory" do
    test "names the three required queues in the output" do
      Mix.Task.reenable("ash_onetime.doctor")

      output =
        capture_io(fn ->
          Doctor.run(["--repo", "AshOnetime.Test.Repo"])
        end)

      # Oban is loaded in the test env; the advisory names the three queues regardless of
      # whether they're configured (found → OK; missing → WARN; no config → WARN naming them).
      assert output =~ "ash_onetime_cleanup"
      assert output =~ "ash_onetime_reap"
      assert output =~ "ash_onetime_partitions"
    end
  end

  describe "summary" do
    test "prints all-checks-passed when no failures" do
      Mix.Task.reenable("ash_onetime.doctor")

      assert capture_io(fn ->
               Doctor.run(["--repo", "AshOnetime.Test.Repo"])
             end) =~ "all checks passed"
    end
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
