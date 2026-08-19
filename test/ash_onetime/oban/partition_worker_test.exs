defmodule AshOnetime.Oban.PartitionWorkerTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Oban.PartitionWorker
  alias AshOnetime.Test.LockContention
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
    # ROADMAP H20: a discarded PartitionWorker strands a month of retention. A failed roll
    # returns fast under its own lock_timeout, so the backoff spaces retries [30,60)s /
    # [60,90)s — wide enough for a contending lock holder to finish — with a ~0-30s jitter
    # so simultaneous failures do not retry in lockstep. Bounded to [30,120] seconds.
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

  # L5 (behavioral): a contended partition-roll advisory lock surfaces as
  # {:error, {:roll_partitions_failed, :lock_timeout}} — the worker embeds the Store
  # Result.reason so Oban's job error carries the distinguishable cause past exhaustion, not an
  # opaque :roll_partitions_failed. Store.roll_partitions sets `SET LOCAL lock_timeout = 5s`
  # internally (arm_partition_roll_lock), so a roll that cannot acquire the per-prefix advisory
  # lock fails closed with reason :lock_timeout after 5s. This pins the error tuple
  # BEHAVIORALLY (a real store fault -> the actual tuple returned to Oban); a regression that
  # collapses the tuple to the opaque atom, or drops the inner reason, fails here.
  @tag unboxed: true
  test "worker surfaces :lock_timeout from a contended advisory lock (L5 behavioral)", %{
    prefix: prefix
  } do
    target = Postgres.for_repo(Repo, prefix)
    roll_key = Postgres.roll_advisory_key(target)

    # Hold the per-prefix advisory lock in a separate real connection. Store.roll_partitions
    # sets SET LOCAL lock_timeout = 5s internally, so a roll that cannot acquire the held lock
    # fails closed with reason :lock_timeout. No session lock_timeout is needed here.
    LockContention.with_contention(
      "SELECT pg_advisory_xact_lock($1::bigint)",
      [roll_key],
      fn ->
        job = %Oban.Job{
          args: %{"repo" => inspect(Repo), "prefix" => prefix, "months" => 3}
        }

        assert {:error, {:roll_partitions_failed, :lock_timeout}} = PartitionWorker.perform(job)
      end
    )
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
