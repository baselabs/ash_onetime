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

  describe "ash floor verdict (pure seam)" do
    test "fails closed when Ash is not loaded" do
      assert {:fail, message} = Doctor.floor_status(nil)
      assert message =~ "Ash is not loaded"
    end

    test "rejects an Ash version below the floor" do
      assert {:fail, message} = Doctor.floor_status(Version.parse!("3.29.3"))
      assert message =~ "below the security floor"
      assert message =~ "3.29.3"
    end

    @tag :doctor_ash_floor_mutation
    test "rejects the retired and advised Ash releases inside the 0.6.0 published range" do
      # 3.31.1: retired by Hex ("breaking change") and inside EEF-CVE-2026-67579's affected
      # range — it was the OLD floor (where 70395/-69659 were fixed), but 67579 (fixed only
      # in 3.31.3) puts it below the floor. 3.31.2: also inside 67579's range. The doctor
      # must fail closed on both.
      assert {:fail, message_3311} = Doctor.floor_status(Version.parse!("3.31.1"))
      assert message_3311 =~ "below the security floor"

      assert {:fail, message_3312} = Doctor.floor_status(Version.parse!("3.31.2"))
      assert message_3312 =~ "below the security floor"
    end

    test "accepts the 3.31.3 security floor" do
      assert :ok = Doctor.floor_status(Version.parse!("3.31.3"))
    end
  end

  describe "oban queue advisory verdict (pure seam)" do
    test "needs no queue check when Oban is not loaded" do
      assert {:ok, :oban_not_loaded} = Doctor.oban_queue_status(false, MapSet.new())
    end

    test "warns toward programmatic verification when no queue config is found" do
      assert {:ok, :no_queue_config} = Doctor.oban_queue_status(true, MapSet.new())
    end

    test "reports all-clear when the three required queues are configured" do
      queues = MapSet.new([:ash_onetime_cleanup, :ash_onetime_reap, :ash_onetime_partitions])

      assert {:ok, :all_configured} = Doctor.oban_queue_status(true, queues)
    end

    test "names exactly the missing queues" do
      partial = MapSet.new([:ash_onetime_cleanup, :ash_onetime_reap])

      assert {:warn, {:missing, [:ash_onetime_partitions]}} =
               Doctor.oban_queue_status(true, partial)
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

  describe "schema currency verdict (pure seam)" do
    test "a complete current schema passes every verdict" do
      assert [{:ok, _}, {:ok, _}, {:ok, _}, {:ok, _}, {:ok, _}] =
               Doctor.schema_status(complete_facts())
    end

    test "an authority table missing the logical_partition column fails" do
      facts = %{
        complete_facts()
        | logical_partition_tables: [
            "ash_onetime_nonce_claims",
            "ash_onetime_idempotency_claims"
          ]
      }

      assert Enum.any?(Doctor.schema_status(facts), fn
               {:fail, message} -> message =~ "logical_partition"
               _ok -> false
             end)
    end

    test "a missing response payloads table fails" do
      facts = %{complete_facts() | payload_table: false}

      assert Enum.any?(Doctor.schema_status(facts), fn
               {:fail, message} -> message =~ "response_payloads table"
               _ok -> false
             end)
    end

    test "a missing default partition fails" do
      facts = %{complete_facts() | default_partition: false}

      assert Enum.any?(Doctor.schema_status(facts), fn
               {:fail, message} -> message =~ "_default partition"
               _ok -> false
             end)
    end

    test "a function with the wrong arity fails even when present" do
      facts = %{
        complete_facts()
        | functions: [
            {"ash_onetime_cleanup_idempotency", 1},
            {"ash_onetime_cleanup_nonce", 1},
            {"ash_onetime_reap_idempotency", 3}
          ]
      }

      assert Enum.any?(Doctor.schema_status(facts), fn
               {:fail, message} -> message =~ "exact arities"
               _ok -> false
             end)
    end

    test "a missing delete-guard trigger fails" do
      facts = %{complete_facts() | triggers: ["ash_onetime_idempotency_delete_guard"]}

      assert Enum.any?(Doctor.schema_status(facts), fn
               {:fail, message} -> message =~ "triggers"
               _ok -> false
             end)
    end

    test "trigger clones (hash-partitioned installs) do not fail the verdict" do
      # PostgreSQL clones parent triggers onto every hash/range partition under the same
      # name; the live query is DISTINCT-constrained, and the verdict additionally dedupes.
      facts = %{
        complete_facts()
        | triggers: [
            "ash_onetime_idempotency_delete_guard",
            "ash_onetime_idempotency_delete_guard",
            "ash_onetime_nonce_delete_guard"
          ]
      }

      refute Enum.any?(Doctor.schema_status(facts), fn
               {:fail, _message} -> true
               _ok -> false
             end)
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

  defp complete_facts do
    %{
      logical_partition_tables: [
        "ash_onetime_nonce_claims",
        "ash_onetime_idempotency_claims",
        "ash_onetime_response_payloads"
      ],
      payload_table: true,
      default_partition: true,
      functions: [
        {"ash_onetime_cleanup_idempotency", 1},
        {"ash_onetime_cleanup_nonce", 1},
        {"ash_onetime_reap_idempotency", 2}
      ],
      triggers: [
        "ash_onetime_idempotency_delete_guard",
        "ash_onetime_nonce_delete_guard"
      ]
    }
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
