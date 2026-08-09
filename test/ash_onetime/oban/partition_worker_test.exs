defmodule AshOnetime.Oban.PartitionWorkerTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Oban.PartitionWorker

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
  end

  test "worker defaults months to 3 when unspecified", %{prefix: prefix} do
    job = %Oban.Job{
      args: %{
        "repo" => inspect(Repo),
        "prefix" => prefix
      }
    }

    assert :ok = PartitionWorker.perform(job)
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
end
