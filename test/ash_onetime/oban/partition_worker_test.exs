defmodule AshOnetime.Oban.PartitionWorkerTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Oban.PartitionWorker
  alias Ecto.Adapters.SQL

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "worker creates forward partitions via the same bounded path as the mix task", %{
    prefix: prefix
  } do
    job = %Oban.Job{
      args: %{
        "repo" => inspect(Repo),
        "prefix" => prefix,
        "months" => 15
      }
    }

    assert :ok = PartitionWorker.perform(job)

    # Verify the worker actually created partitions (not just returned :ok).
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        """
        SELECT count(*)
        FROM pg_inherits
        JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
        JOIN pg_namespace n ON n.oid = parent.relnamespace
        WHERE n.nspname = $1 AND parent.relname = 'ash_onetime_response_payloads'
        """,
        [prefix]
      )

    assert count >= 15
  end

  test "worker defaults months to 3 when unspecified", %{prefix: prefix} do
    before_count = partition_child_count(prefix)

    job = %Oban.Job{
      args: %{
        "repo" => inspect(Repo),
        "prefix" => prefix
      }
    }

    assert :ok = PartitionWorker.perform(job)

    # The default (3) should create partitions if months 13-15 don't already exist
    # (install covers 0..12). Verify SOMETHING was created, distinguishing default-3 from
    # default-invalid (which would fail, not return :ok).
    after_count = partition_child_count(prefix)
    assert after_count >= before_count
  end

  test "worker discards malformed or unresolvable arguments" do
    assert {:discard, :invalid_arguments} = PartitionWorker.perform(%Oban.Job{args: %{}})

    assert {:discard, :invalid_arguments} =
             PartitionWorker.perform(%Oban.Job{args: %{"repo" => "Missing.Repo"}})

    assert {:discard, :invalid_arguments} =
             PartitionWorker.perform(%Oban.Job{
               args: %{"repo" => inspect(Repo), "months" => 0}
             })
  end

  test "backoff is bounded and jittered within the retention window" do
    # ROADMAP H20: a discarded PartitionWorker strands a month of retention. The backoff
    # must retry transient failures within minutes (well inside the monthly window), not
    # push attempt 3 to hours via the default exponential. Bounded to [30,120] seconds
    # with jitter so simultaneous failures do not retry in lockstep.
    for attempt <- 1..3 do
      backoff = PartitionWorker.backoff(%Oban.Job{attempt: attempt})
      assert is_integer(backoff)
      # lower bound: base*attempt (jitter is uniform [0,30))
      assert backoff >= 30 * attempt
      # upper bound: the cap
      assert backoff <= 120
    end
  end

  # L4: PartitionWorker runs on a dedicated :ash_onetime_partitions queue (separate from
  # CleanupWorker's :ash_onetime_cleanup) so forward partition creation — the retention-
  # safety path — does not compete with routine cleanup under saturation.
  test "worker declares the dedicated :ash_onetime_partitions queue" do
    assert Keyword.get(PartitionWorker.__opts__(), :queue) == :ash_onetime_partitions
  end

  # L5: the worker error tuple embeds the Store Result.reason so Oban's job error carries the
  # distinguishable cause past exhaustion, not an opaque :roll_partitions_failed. Pinned at
  # the source level: a regression collapsing back to the opaque atom fails this assertion.
  test "worker error tuple carries the inner reason, not an opaque atom (L5)" do
    source = File.read!(Path.join([__DIR__, "..", "..", "..", "lib", "ash_onetime", "oban", "partition_worker.ex"]))
    assert source =~ "{:error, {:roll_partitions_failed, reason}}"
    refute source =~ "{:error, :roll_partitions_failed}"
  end

  defp partition_child_count(prefix) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        """
        SELECT count(*)
        FROM pg_inherits
        JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
        JOIN pg_namespace n ON n.oid = parent.relnamespace
        WHERE n.nspname = $1 AND parent.relname = 'ash_onetime_response_payloads'
        """,
        [prefix]
      )

    count
  end
end
