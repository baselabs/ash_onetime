defmodule AshOnetime.Delivery.ExitBoundaryTest do
  use AshOnetime.Test.StoreCase, async: false

  # §2.7.8: the observable boundary of an executing-only run is the boundary of the same
  # run with the values returned instead, plus the package's declared events. Each path
  # runs once through `deliver/2` on the withheld resource and once through Ash on its
  # twin, in separate installations, under the collector; the checks are X1 to X4, the
  # unclaimed events and the canary and envelope searches. A path with no twin (a
  # producer failure, a direct Ash call) is checked for containment.

  import AshOnetime.Test.DeliveryCase, only: [error_code: 1]

  alias AshOnetime.Test.ExitBoundary.{Faults, Normalization, Pair}
  alias AshOnetime.Test.ExitBoundary.Pair.Path
  alias AshOnetime.Test.ExternalPeer

  @moduletag unboxed: true
  @moduletag exit_boundary: true
  @moduletag timeout: 300_000

  # Every route, by its local action; the external action is the same name prefixed.
  @routes [
    create: %Path{action: :issue, type: :create, input: %{amount: 7}},
    update: %Path{action: :rotate, type: :update, input: %{amount: 7}, record: true},
    destroy: %Path{action: :revoke, type: :destroy, record: true},
    soft_destroy: %Path{action: :retire, type: :destroy, record: true},
    generic: %Path{action: :mint, type: :action, input: %{value: 7}}
  ]

  setup_all do
    # The completed-response cache is on for every path, so a value written to it (M2)
    # crosses the boundary where the checks see it; both sides use the same cache.
    start_supervised!({AshOnetime.Cache.Ets, max_entries: 10_000})
    previous = Application.fetch_env(:ash_onetime, :cache)
    Application.put_env(:ash_onetime, :cache, AshOnetime.Cache.Ets)

    on_exit(fn ->
      case previous do
        {:ok, cache} -> Application.put_env(:ash_onetime, :cache, cache)
        :error -> Application.delete_env(:ash_onetime, :cache)
      end
    end)

    run = install_store!()
    twin = install_store!()
    {:ok, prefix: run.schema, run_prefix: run.schema, twin_prefix: twin.schema}
  end

  setup %{run_prefix: run_prefix, twin_prefix: twin_prefix} do
    for prefix <- [run_prefix, twin_prefix] do
      ExternalPeer.install!(prefix)
      create_records_table!(prefix)
    end

    peer =
      start_supervised!(
        {Postgrex, Keyword.put(ExternalPeer.database_options(), :idle_interval, 3_600_000)}
      )

    # Unnamed statements: a named statement is prepared once per pooled connection, so the
    # round trips of a query would depend on which connection served it, not on the action.
    # No idle ping can replace a pre-observation checkin clock during the trace.
    repo = start_unboxed_repo!(prepare: :unnamed, idle_interval: 3_600_000)
    Normalization.prepare(repo)
    {:ok, repo: repo, peer: peer}
  end

  for {route, path} <- @routes, producer <- [:local, :external] do
    @path path
    @producer producer
    @label "#{route}, #{producer}"

    # The class mutations' owned test (scripts/check_mutations.exs, `exit-boundary`).
    if route == :create and producer == :local, do: @tag(exit_boundary_core: true)

    test "#{@label}: an execute delivers once", context do
      context |> pair(path(@path, @producer, "executes")) |> Pair.assert_boundary!(:executed)
    end

    test "#{@label}: a replay delivers nothing", context do
      path = path(@path, @producer, "replays")
      context |> pair(path, &first_call/1) |> Pair.assert_boundary!(:replayed)
    end

    test "#{@label}: classifier reject and rollback deliver nothing", context do
      for fault <- [:classify_reject, :classify_rollback] do
        path = %{path(@path, @producer, "#{fault}") | fault: fault}
        context |> pair(path) |> Pair.assert_boundary!(:none)
      end
    end

    test "#{@label}: codec and hold failures deliver nothing", context do
      for fault <- [:codec_encode, :hold_invalid] do
        path = %{path(@path, @producer, "#{fault}") | fault: fault}
        context |> pair(path) |> Pair.assert_boundary!(:none)
      end

      path = %{path(@path, @producer, "codec-decode") | fault: :codec_decode}
      context |> pair(path, &first_call/1) |> Pair.assert_boundary!(:none)
    end

    test "#{@label}: a store failure at completion delivers nothing", context do
      prefixes = [context.run_prefix, context.twin_prefix]
      Enum.each(prefixes, &move_payloads!/1)

      try do
        context |> pair(path(@path, @producer, "store-failure")) |> Pair.assert_boundary!(:none)
      after
        Enum.each(prefixes, &restore_payloads!/1)
      end
    end

    test "#{@label}: a caller transaction, committed or rolled back, delivers nothing",
         context do
      for ending <- [:commit, :rollback] do
        path = %{path(@path, @producer, "transaction-#{ending}") | transaction: ending}
        observed = pair(context, path)

        Pair.assert_boundary!(observed, :none)
        assert error_code(Pair.returned(observed.run)) == :executing_only_in_transaction
      end
    end

    test "#{@label}: a consumer after-hook that raises, exits or throws delivers nothing",
         context do
      for fault <- [:after_raise, :after_exit, :after_throw] do
        path = %{path(@path, @producer, "#{fault}") | fault: fault}
        context |> pair(path) |> Pair.assert_boundary!(:none)
      end
    end

    test "#{@label}: a direct Ash call is refused and contained", context do
      path = %{path(@path, @producer, "direct") | call: :direct}
      run = Pair.observe_alone(path, boundary(context), nil)

      Pair.assert_contained!(run, :none, :searched)
      assert error_code(run.run.result) == :executing_only_requires_call
    end
  end

  for {route, path} <- @routes do
    @path path

    test "#{route}, external: a recovery whose peer holds the effect delivers nothing",
         context do
      path = path(@path, :external, "recovers")
      context |> pair(path, &interrupted(&1, :after_execute)) |> Pair.assert_boundary!(:recovered)
    end

    test "#{route}, external: a recovery that proves absence executes and delivers once",
         context do
      path = path(@path, :external, "absent")
      context |> pair(path, &interrupted(&1, :before_execute)) |> Pair.assert_boundary!(:executed)
    end

    test "#{route}, external: an unknown execute that recovery finds delivers nothing",
         context do
      path = %{path(@path, :external, "unknown") | fault: :execute_unknown}
      context |> pair(path) |> Pair.assert_boundary!(:recovered)
    end

    # M9's owned test (scripts/check_mutations.exs, `m-table`).
    if route == :create, do: @tag(exit_boundary_failures: true)

    test "#{route}, local: producer failures are contained", context do
      for fault <- [:producer_raise, :producer_error, :producer_contract] do
        path = %{path(@path, :local, "#{fault}") | fault: fault}
        run = Pair.observe_alone(path, boundary(context), nil)

        Pair.assert_contained!(run, :none, :searched)
        assert error_code(run.run.result) == :executing_only_invalid
      end
    end
  end

  defp path(%Path{} = path, :local, label), do: %{path | key: key(path, label)}

  defp path(%Path{} = path, :external, label) do
    action = String.to_existing_atom("external_#{path.action}")
    %{path | action: action, external?: true, key: key(path, label)}
  end

  defp key(path, label), do: "#{path.action}-#{label}-#{System.unique_integer([:positive])}"

  defp pair(context, path, prior \\ nil), do: Pair.observe(path, boundary(context), prior)

  defp boundary(context), do: Map.take(context, [:run_prefix, :twin_prefix, :repo, :peer])

  # A replay's first call: the same call on the same side, unobserved, in a worker on the
  # unboxed repository, as the observed call runs. Its failure is reported by error code.
  defp first_call(%{resource: resource, prefix: prefix, record: record, repo: repo} = prior) do
    path = %{prior.path | fault: nil}

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        Faults.put_peer(prior.peer)
        Pair.run_call(resource, path, Pair.subject(path, resource, prefix, record))
      end)

    case Task.await(task, 60_000) do
      {:ok, _result, _delivery} -> :ok
      {:ok, _result} -> :ok
      :ok -> :ok
      {:error, _error} = failed -> flunk("the first call failed: #{inspect(error_code(failed))}")
    end
  end

  # A recovery's first call, in an unobserved worker on the unboxed repository, stopped at
  # `point` inside the external effect and killed there: the claim stays processing, with
  # the peer holding the effect (after execute) or nothing (before it).
  defp interrupted(
         %{resource: resource, prefix: prefix, record: record, repo: repo, path: path} = prior,
         point
       ) do
    test = self()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        Repo.put_dynamic_repo(repo)
        Faults.put_peer(prior.peer)
        Faults.put({:pause, point, test, reference})
        Pair.run_call(resource, path, Pair.subject(path, resource, prefix, record))
      end)

    receive do
      {:boundary_pause, ^reference, ^worker} -> :ok
    after
      30_000 -> flunk("the first call never reached #{point}")
    end

    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, :killed} -> :ok
    after
      5_000 -> flunk("the first call did not stop")
    end
  end

  # A store failure at completion: the payload relation is moved away for the run, so the
  # completing insert fails in the action's transaction.
  defp move_payloads!(prefix) do
    SQL.query!(
      Repo,
      ~s(ALTER TABLE "#{prefix}"."ash_onetime_response_payloads" RENAME TO "ash_onetime_response_payloads_moved"),
      []
    )
  end

  defp restore_payloads!(prefix) do
    SQL.query!(
      Repo,
      ~s(ALTER TABLE IF EXISTS "#{prefix}"."ash_onetime_response_payloads_moved" RENAME TO "ash_onetime_response_payloads"),
      []
    )
  end

  defp create_records_table!(prefix) do
    table = ~s("#{prefix}"."ash_onetime_boundary_records")
    SQL.query!(Repo, "DROP TABLE IF EXISTS #{table}", [])

    SQL.query!(
      Repo,
      "CREATE TABLE #{table} (id uuid PRIMARY KEY, amount bigint NOT NULL, retired boolean NOT NULL DEFAULT false)",
      []
    )
  end
end
