defmodule AshOnetime.Delivery.TaskRouteTest do
  # F12: the Task route. Ash runs a CRUD action's hooks in a Task, away from the caller's
  # process dictionary, exactly when the action runs outside a transaction with a finite
  # timeout, async enabled and no open transaction (changeset.ex:4778-4800, :4864-4869;
  # process_helpers.ex:66-74). The package's entry would then run where the entry is
  # absent, so `deliver/2` refuses that route before arming.
  #
  # Each cell first observes where Ash itself runs the package's entry: a plain Ash call
  # whose around-action, prepended outside the package's, reports its process (on the
  # Task route the whole chain runs in the Task, F1). The cell then calls `deliver/2` with
  # the same settings and asserts the outcome the observation dictates. The Task cells
  # must be exactly the ones the predicate names, on every CRUD route.
  #
  # The axes:
  #   * the action's `transaction?`: declared true, or false on the action struct Ash runs
  #     (helpers.ex:277-287 uses the changeset's own struct). `Ash.create/2`, `update/2`
  #     and `destroy/2` accept no `transaction?` option; the last test shows Ash rejects it;
  #   * the timeout: none, `:infinity` or finite from the call's options, or finite from
  #     the changeset (changeset.ex:3268; create.ex:301, update.ex:461, destroy.ex:514);
  #   * the caller's transaction: none, or open;
  #   * `:disable_async?`: true (this suite's configuration) or false.
  #
  # Generic actions have no Task route: `Ash.Actions.Action.run/3` runs inline, and
  # `Ash.run_action/2` accepts neither `timeout` nor `transaction?` (ash.ex:946-1000), so
  # only the transaction and async axes apply.
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias AshOnetime.Delivery
  alias AshOnetime.Test.DeliveryExamples.Resource

  @marker :ash_onetime_task_route_marker

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    async = Application.get_env(:ash, :disable_async?)
    on_exit(fn -> Application.put_env(:ash, :disable_async?, async) end)
    install!(prefix)
  end

  @timeouts [:none, {:opt, :infinity}, {:opt, 5_000}, {:changeset, 5_000}]

  for route <- [:create, :update, :destroy, :soft_destroy] do
    @route route

    @tag executing_only_route: :task
    test "deliver/2 refuses exactly the cells where Ash runs #{route} in a Task", %{
      prefix: prefix
    } do
      cells =
        for transaction? <- [true, false],
            timeout <- @timeouts,
            caller <- [:none, :open],
            disable_async? <- [true, false],
            do: %{
              transaction?: transaction?,
              timeout: timeout,
              caller: caller,
              disable_async?: disable_async?
            }

      observed =
        for cell <- cells do
          Application.put_env(:ash, :disable_async?, cell.disable_async?)
          task? = probe(prefix, @route, cell)
          assert_delivery(prefix, @route, cell, task?)
          {cell, task?}
        end

      task_cells = for {cell, true} <- observed, do: cell

      assert task_cells ==
               for(
                 cell <- cells,
                 not cell.transaction?,
                 cell.timeout in [{:opt, 5_000}, {:changeset, 5_000}],
                 cell.caller == :none,
                 not cell.disable_async?,
                 do: cell
               )
    end
  end

  @tag executing_only_route: :task
  test "a generic action runs in the caller's process on every cell", %{prefix: prefix} do
    for transaction? <- [true, false],
        caller <- [:none, :open],
        disable_async? <- [true, false] do
      cell = %{
        transaction?: transaction?,
        timeout: :none,
        caller: caller,
        disable_async?: disable_async?
      }

      Application.put_env(:ash, :disable_async?, disable_async?)
      refute probe(prefix, :generic, cell)
      assert_delivery(prefix, :generic, cell, false)
    end

    input = builder(prefix, :generic, unique_key("generic-options")).()

    for option <- [timeout: 5_000, transaction?: false] do
      assert {:error, error} = Ash.run_action(input, [option])
      assert Exception.message(error) =~ to_string(elem(option, 0))
    end
  end

  @tag executing_only_route: :task
  test "Ash rejects a caller's transaction? option on every CRUD route", %{prefix: prefix} do
    for route <- [:create, :update, :destroy, :soft_destroy] do
      subject = builder(prefix, route, unique_key("option-#{route}")).()

      assert {:error, error} =
               dispatch(subject, route, transaction?: false)

      assert Exception.message(error) =~ "transaction?"

      before = claim_count(prefix)
      result = AshOnetime.deliver(subject, transaction?: false)
      assert {:error, delivered} = result
      assert Exception.message(delivered) =~ "transaction?"
      assert delivered(result) == []
      assert claim_count(prefix) == before
    end
  end

  # Where Ash runs the hooks of a plain call on this cell. Returns whether that was
  # another process, and asserts what crossed: a Task receives the tracer context only
  # (process_helpers.ex:13-30), so this process's dictionary marker is absent there.
  defp probe(prefix, route, cell) do
    test = self()
    Process.put(@marker, :caller)

    report = fn -> send(test, {:probe, self(), Process.get(@marker)}) end

    reported = fn subject ->
      report.()
      subject
    end

    subject =
      case builder(prefix, route, unique_key("probe-#{route}"), cell).() do
        %Ash.Changeset{} = changeset ->
          Ash.Changeset.around_action(
            changeset,
            fn changeset, callback ->
              report.()
              callback.(changeset)
            end,
            prepend?: true
          )

        %Ash.ActionInput{} = input ->
          Ash.ActionInput.before_action(input, reported, prepend?: true)
      end

    # A failure inside an open transaction can roll that transaction back, so each call
    # gets its own; the probe's own result is not the observation.
    in_caller(cell, fn -> dispatch(subject, route, options(cell)) end)
    Process.delete(@marker)

    assert_received {:probe, pid, marker}

    if pid == test do
      assert marker == :caller
      false
    else
      assert marker == nil
      true
    end
  end

  defp assert_delivery(prefix, route, cell, task?) do
    test = self()

    subject =
      builder(prefix, route, unique_key("deliver-#{route}"), cell).()
      |> hook(:before_transaction, &ran(test, &1), [])

    before = claim_count(prefix)
    result = in_caller(cell, fn -> AshOnetime.deliver(subject, options(cell)) end)
    label = inspect({route, cell})

    cond do
      cell.caller == :open ->
        assert error_code(result) == :executing_only_in_transaction, label
        refute_received :ran, label
        assert claim_count(prefix) == before, label

      task? ->
        assert error_code(result) == :executing_only_refused, label
        refute_received :ran, label
        assert claim_count(prefix) == before, label

      not cell.transaction? ->
        assert error_code(result) == :not_in_transaction, label
        assert_received :ran, label
        assert claim_count(prefix) == before, label

      true ->
        assert %Delivery{outcome: :executed} = elem(result, tuple_size(result) - 1), label
        assert_received :ran, label
        assert claim_count(prefix) == before + 1, label
    end

    assert length(delivered(result)) <= 1, label
  end

  defp in_caller(%{caller: :none}, fun), do: fun.()

  defp in_caller(%{caller: :open}, fun) do
    case Ash.DataLayer.transaction(Resource, fun) do
      {:ok, result} -> result
      {:error, _error} = error -> error
    end
  end

  defp options(%{timeout: {:opt, timeout}}), do: [timeout: timeout]
  defp options(_cell), do: []

  # The cell's subject: the builder's subject with the action struct Ash runs set to the
  # cell's `transaction?`, and the timeout carried by the changeset when the cell says so.
  defp builder(prefix, route, key, cell) do
    build = builder(prefix, route, key)

    fn ->
      subject = build.()
      subject = %{subject | action: %{subject.action | transaction?: cell.transaction?}}

      case cell.timeout do
        {:changeset, timeout} -> Ash.Changeset.timeout(subject, timeout)
        _other -> subject
      end
    end
  end

  defp dispatch(subject, :create, opts), do: Ash.create(subject, opts)
  defp dispatch(subject, :update, opts), do: Ash.update(subject, [atomic_upgrade?: false] ++ opts)
  defp dispatch(subject, :generic, opts), do: Ash.run_action(subject, opts)
  defp dispatch(subject, _destroy, opts), do: Ash.destroy(subject, opts)

  # A consumer hook body: notes that it ran and returns the subject unchanged.
  defp ran(test, subject) do
    send(test, :ran)
    subject
  end
end
