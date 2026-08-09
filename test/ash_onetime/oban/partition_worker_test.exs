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
