for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.DoctorTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    alias Mix.Tasks.AshOnetime.Doctor
    import ExUnit.CaptureIO

    @tag :external_state_review_journal_doctor
    test "#{partitioning || "plain"}: doctor refuses a missing rollback journal", c do
      journal = rel(c, "ash_onetime_external_state_restore")
      present = scalar(c.owner_repo, "SELECT to_regclass($1) IS NOT NULL", [journal])
      if present, do: SQL.query!(c.owner_repo, "ALTER TABLE #{journal} RENAME TO displaced_restore", [])
      previous = Repo.put_dynamic_repo(c.runtime_repo)
      try do
        capture_io(fn ->
          assert_raise Mix.Error, ~r/check\(s\) failed/, fn ->
            Doctor.run(["--repo", inspect(Repo), "--live", "--prefix", c.schema])
          end
        end)
      after
        Repo.put_dynamic_repo(previous)
        if present, do: SQL.query!(c.owner_repo, "ALTER TABLE #{rel(c, "displaced_restore")} RENAME TO ash_onetime_external_state_restore", [])
      end
    end

    test "#{partitioning || "plain"}: doctor accepts current triggers and shows retained external states",
         c do
      for state <- [:unresolved, :held, :absent_proven, :unknown] do
        id = insert_claim(c, attempt: if(state == :unknown, do: 0, else: 1))
        if state in [:held, :absent_proven], do: record_outcome(c, id, state)
      end

      previous = Repo.put_dynamic_repo(c.runtime_repo)

      try do
        output =
          capture_io(fn ->
            Doctor.run(["--repo", inspect(Repo), "--live", "--prefix", c.schema])
          end)

        for state <- ~w(unresolved held absent_proven unknown) do
          assert output =~ "#{state}: 1"
        end
      after
        Repo.put_dynamic_repo(previous)
      end
    end

    test "#{partitioning || "plain"}: status excludes external claims from the reapable backlog",
         c do
      external = insert_claim(c)
      age_claim(c, external)
      {:ok, %{rows: [[status]]}} = step(c, "ash_onetime_maintenance_status", "")
      assert status["oldest_reapable_age_seconds"] == nil
      assert status["external_backlog"]["unresolved"] == 1
    end
  end
end
