for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.DoctorTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    alias Mix.Tasks.AshOnetime.Doctor
    import ExUnit.CaptureIO

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
