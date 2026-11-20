defmodule AshOnetime.Test.ExitBoundary.ComparatorCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias AshOnetime.Test.{ExternalPeer, Repo}
  alias AshOnetime.Test.ExitBoundary.{References, Returned, Scenarios, Withheld}
  alias Ecto.Adapters.SQL
  import AshOnetime.Test.StoreCase

  using do
    quote do
      @moduletag unboxed: true
      @moduletag exit_boundary: true
      @moduletag timeout: 1_800_000
      import AshOnetime.Test.ExitBoundary.ComparatorCase
    end
  end

  setup_all do
    start_supervised!({AshOnetime.Cache.Ets, max_entries: 10_000})
    previous = Application.fetch_env(:ash_onetime, :cache)
    Application.put_env(:ash_onetime, :cache, AshOnetime.Cache.Ets)

    on_exit(fn ->
      case previous do
        {:ok, cache} -> Application.put_env(:ash_onetime, :cache, cache)
        :error -> Application.delete_env(:ash_onetime, :cache)
      end
    end)

    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup context do
    size = Map.get(context, :pool_size, 2)
    repo = start_unboxed_repo!(prepare: :unnamed, idle_interval: 3_600_000, pool_size: size)
    Repo.put_dynamic_repo(repo)
    ExternalPeer.install!(context.prefix)

    SQL.query!(
      repo,
      ~s[CREATE TABLE IF NOT EXISTS "#{context.prefix}".ash_onetime_boundary_records (id uuid PRIMARY KEY, amount bigint NOT NULL, retired boolean NOT NULL DEFAULT false)],
      []
    )

    peer =
      start_supervised!(
        {Postgrex,
         Keyword.merge(ExternalPeer.database_options(),
           idle_interval: 3_600_000,
           prepare: :unnamed
         )}
      )

    warm_pool!(repo, size)
    {:ok, repo: repo, peer: peer, pool_size: size}
  end

  def warm_pool!(repo, size) do
    parent = self()
    tag = make_ref()

    tasks =
      for _ <- 1..size do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          Repo.checkout(fn ->
            SQL.query!(repo, "SELECT 1", [])
            send(parent, {tag, self()})
            receive do: ({^tag, :release} -> :ok)
          end)
        end)
      end

    for _ <- tasks do
      receive do
        {^tag, _} -> :ok
      after
        30_000 -> raise "pool warmup did not finish"
      end
    end

    for task <- tasks, do: send(task.pid, {tag, :release})
    for task <- tasks, do: Task.await(task)
    :ok
  end

  def with_references(context, rows \\ Scenarios.rows()) do
    actions = rows |> Enum.map(& &1.action) |> Enum.uniq()

    references =
      for resource <- [Withheld, Returned],
          action <- actions,
          into: %{},
          do: {{resource, action}, References.operation(resource, action)}

    Map.put(context, :operation_references, references)
  end

  def observe(context, row, values) do
    Repo.put_dynamic_repo(context.repo)
    Scenarios.observe(row, values, with_references(context, [row]))
  end

  def row!(action, branch, fault \\ nil) do
    Enum.find(
      Scenarios.rows(),
      &(&1.action == action and &1.branch == branch and &1.fault == fault)
    ) ||
      raise "no comparator path for #{inspect({action, branch, fault})}"
  end
end
