defmodule AshOnetime.Delivery.AshFactsTest do
  # The Ash facts of §2.7.7 that deliver/2 relies on, observed at Ash 3.37.4 from inside
  # real `deliver/2` calls against the real store:
  #
  #   * F1: a prepended around-action encloses before-action, the data layer and
  #     after-action, all in the calling process.
  #   * F7: the generic order, from around_transaction to the return-type load, with the
  #     input in the transaction reason.
  #   * F8: tracer success callbacks receive neither result nor subject; `set_error/2`
  #     receives the raw exception and a stacktrace with arguments.
  #   * F9: `to_error_class/2` keeps the subject, context included, in the error.
  #   * F11: the return shapes deliver/2 normalizes.
  #
  # Every probe also reports the state of the armed entry when it ran, so the order shows
  # where the package's claim, seal and completion fall. The canary the producer returns
  # is searched for on every surface the facts name; it must appear only in the
  # `%AshOnetime.Delivery{}` deliver/2 returns.
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias Ash.Error.Invalid
  alias AshOnetime.Delivery
  alias AshOnetime.Test.DeliveryExamples.{Producer, Resource}
  alias AshOnetime.Test.DeliveryFacts.{Issuer, Observer, Receipt, Tracer}

  @crud_routes [create: "INSERT", update: "UPDATE", destroy: "DELETE", soft_destroy: "UPDATE"]

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    install!(prefix)

    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS "#{prefix}"."ash_onetime_facts_receipts" (
        id uuid PRIMARY KEY,
        token text NOT NULL
      )
      """,
      []
    )

    canary = :crypto.strong_rand_bytes(32)
    Producer.plant(canary)
    Observer.watch()
    {:ok, canary: canary}
  end

  describe "F1: the package's around-action encloses the action, in the calling process" do
    for {route, verb} <- @crud_routes do
      @route route
      @verb verb

      @tag ash_fact: :f1
      test "on #{route}", %{prefix: prefix, canary: canary} do
        subject =
          prefix
          |> builder(@route, unique_key("f1-#{@route}"))
          |> apply([])
          |> hook(:around_action, &around/2, prepend?: true)
          |> Ash.Changeset.before_action(fn changeset ->
            Observer.note(:before_action)
            changeset
          end)
          |> hook(:after_action, &note_after_action/2, [])

        {result, events} =
          with_writes(prefix, "ash_onetime_delivery_examples", fn ->
            AshOnetime.deliver(subject)
          end)

        assert %Delivery{outcome: :executed, values: %{secret: ^canary}} = delivery(result)

        # The data layer's transaction begins before any around-action; the order below
        # is inside it.
        events = Enum.reject(events, &match?({{:transaction_begin, _reason}, _pid, _state}, &1))

        assert Enum.map(events, &Tuple.delete_at(&1, 1)) == [
                 {:around_in, :armed},
                 {:produced, :claimed},
                 {:before_action, :sealed},
                 {{:write, @verb}, :sealed},
                 {:after_action, :sealed},
                 {:around_out, :done}
               ]

        assert Enum.all?(events, fn {_event, pid, _state} -> pid == self() end)
        assert Observer.entry_state() == :none
      end
    end
  end

  describe "F7: the generic order" do
    @tag ash_fact: :f7
    test "around_transaction to the return-type load, with the input in the reason", %{
      prefix: prefix,
      canary: canary
    } do
      input =
        Issuer
        |> Ash.ActionInput.for_action(
          :issue,
          %{token: unique_key("f7"), request_key: unique_key("f7")},
          tenant: prefix
        )
        |> Ash.ActionInput.load([:noted])
        |> Ash.ActionInput.around_transaction(fn input, callback ->
          Observer.note(:around_transaction_in)
          result = callback.(input)
          Observer.note(:around_transaction_out)
          result
        end)
        |> hook(:before_transaction, &note_before_transaction/1, [])
        |> Ash.ActionInput.before_action(fn input ->
          Observer.note(:before_action)
          input
        end)
        |> hook(:after_action, &note_after_action/2, [])
        |> hook(:after_transaction, &note_after_transaction/2, [])

      assert {:ok, %Receipt{noted: "noted"}, %Delivery{outcome: :executed, values: values}} =
               AshOnetime.deliver(input)

      assert values == %{secret: canary}

      events = Observer.events()
      assert Enum.all?(events, fn {_event, pid, _state} -> pid == self() end)

      # The receipt's own create inside the implementation joins the open transaction
      # inline (data_layer.ex:640-641), so the repo notes no second begin
      # (ash_postgres data_layer.ex:5267); the order below is the generic action's alone.
      {generic, nested} =
        events
        |> Enum.map(&Tuple.delete_at(&1, 1))
        |> Enum.split_with(fn
          {{:transaction_begin, %{type: type}}, _state} -> type == :generic
          _event -> true
        end)

      assert nested == []

      assert [
               {:around_transaction_in, :armed},
               {:before_transaction, :armed},
               {{:transaction_begin, reason}, :armed},
               {:authorize, :armed},
               {:produced, :claimed},
               {:before_action, :sealed},
               {:run, :sealed},
               {:after_action, :done},
               {:notification, :done},
               {:after_transaction, :done},
               {:around_transaction_out, :done},
               {:load, :done}
             ] = generic

      # The reason carries the input, and the input carries the reference only.
      assert %{type: :generic, metadata: %{input: %Ash.ActionInput{} = carried}} = reason
      assert_reference_only(carried)
      assert absent?(reason, canary)
      assert Observer.entry_state() == :none
    end
  end

  describe "F8: what a tracer receives" do
    for route <- [:create, :update, :destroy, :soft_destroy, :generic] do
      @route route

      @tag ash_fact: :f8
      test "success callbacks receive neither result nor subject on #{route}", %{
        prefix: prefix,
        canary: canary
      } do
        subject = builder(prefix, @route, unique_key("f8-#{@route}")).()

        Tracer.record()
        result = AshOnetime.deliver(subject, tracer: Tracer)
        records = Tracer.records()

        assert %Delivery{outcome: :executed, values: %{secret: ^canary}} = delivery(result)
        assert Enum.any?(records, &match?({:start_span, [:action, _name]}, &1))
        assert Enum.any?(records, &match?({:set_metadata, [:action, %{}]}, &1))
        assert Enum.any?(records, &match?({:stop_span, []}, &1))

        refute Enum.any?(records, fn {callback, _args} ->
                 callback in [:set_error, :set_handled_error]
               end)

        assert subjects(records) == []
        refute contains?(records, &match?(%Resource{}, &1))
        assert absent?(records, canary)

        # The control: the same search finds the canary where it belongs.
        refute absent?({records, result}, canary)
      end
    end

    @tag ash_fact: :f8
    test "set_error/2 receives the raw exception and a stacktrace with arguments", %{
      prefix: prefix,
      canary: canary
    } do
      for route <- [:create, :generic] do
        subject =
          prefix
          |> builder(route, unique_key("f8-raise-#{route}"))
          |> apply([])
          |> hook(:after_action, fn _subject, result -> refuse(result) end, [])

        Tracer.record()

        raised =
          try do
            AshOnetime.deliver(subject, tracer: Tracer)
          rescue
            exception -> exception
          end

        records = Tracer.records()

        # Each enclosing span (the hook's, then the action's) reports the same raw
        # exception, not an Ash error class, with the raising frame's arguments.
        errors = for {:set_error, args} <- records, do: args
        assert errors != [], inspect(route)

        for [error, opts] <- errors do
          assert %FunctionClauseError{function: :refuse} = error, inspect(route)
          assert [{__MODULE__, :refuse, [_result], _location} | _frames] = opts[:stacktrace]
        end

        # The raised class keeps the subject (F9), which carries the reference only.
        assert is_exception(raised)
        if route == :create, do: assert([_ | _] = subjects(raised))
        Enum.each(subjects(raised), &assert_reference_only/1)
        assert absent?({records, raised}, canary)
        assert Observer.entry_state() == :none
      end
    end
  end

  describe "F9: an error keeps the subject, context included" do
    @tag ash_fact: :f9
    test "to_error_class/2 keeps the changeset and its private context" do
      changeset =
        Resource
        |> Ash.Changeset.new()
        |> Ash.Changeset.put_context(:private, %{probe: :kept})
        |> Ash.Changeset.add_error(Invalid.exception(errors: []))

      assert %{changeset: %Ash.Changeset{context: %{private: %{probe: :kept}}}} =
               Ash.Error.to_error_class(changeset)
    end

    @tag ash_fact: :f9
    test "a failure after the seal returns an error whose subject holds the reference only",
         %{prefix: prefix, canary: canary} do
      for route <- [:create, :update, :destroy, :soft_destroy, :generic] do
        flag = {__MODULE__, :fail, route}
        Process.put(flag, true)

        subject =
          prefix
          |> builder(route, unique_key("f9-#{route}"))
          |> apply([])
          |> fail_after_completion(flag)

        Tracer.record()
        assert {:error, error} = AshOnetime.deliver(subject, tracer: Tracer)
        records = Tracer.records()

        assert [[handled, _opts]] = for({:set_handled_error, args} <- records, do: args),
               inspect(route)

        if route != :generic do
          assert %Ash.Changeset{} = error.changeset, inspect(route)
          assert %Ash.Changeset{} = handled.changeset, inspect(route)
        end

        Enum.each(subjects({error, records}), &assert_reference_only/1)
        assert absent?({error, records}, canary), inspect(route)
        assert Observer.entry_state() == :none
      end
    end
  end

  describe "F11: return shapes" do
    @tag ash_fact: :f11
    test "Ash's generic shapes: no return type gives :ok, a list stays a list", %{prefix: prefix} do
      assert :ok =
               Issuer
               |> Ash.ActionInput.for_action(:plain_nothing, %{}, tenant: prefix)
               |> Ash.run_action()

      assert {:ok, [1, 2, 3]} =
               Issuer
               |> Ash.ActionInput.for_action(:plain_numbers, %{}, tenant: prefix)
               |> Ash.run_action()

      assert {:ok, %Receipt{}} =
               Issuer
               |> Ash.ActionInput.for_action(:plain_issue, %{token: "plain"}, tenant: prefix)
               |> Ash.run_action()
    end

    @tag ash_fact: :f11
    test "deliver/2 normalizes the generic shapes and replays them with no value", %{
      prefix: prefix,
      canary: canary
    } do
      for {action, args, expected} <- [
            {:nothing, %{}, &is_nil/1},
            {:numbers, %{}, &(&1 == [1, 2, 3])},
            {:issue, %{token: "f11-issue"}, &match?(%Receipt{token: "f11-issue"}, &1)}
          ] do
        args = Map.put(args, :request_key, unique_key("f11-#{action}"))
        build = fn -> Ash.ActionInput.for_action(Issuer, action, args, tenant: prefix) end

        assert {:ok, result, %Delivery{outcome: :executed, values: %{secret: ^canary}}} =
                 AshOnetime.deliver(build.())

        assert expected.(result), inspect(action)

        assert {:ok, replayed, %Delivery{outcome: :replayed, values: values}} =
                 AshOnetime.deliver(build.())

        assert values == %{}
        assert expected.(replayed), inspect(action)
      end
    end

    @tag ash_fact: :f11
    test "Ash's destroy shapes: return_destroyed? x return_notifications?", %{prefix: prefix} do
      for {opts, shape} <- destroy_shapes() do
        receipt =
          Receipt
          |> Ash.Changeset.for_create(:create, %{token: "f11-destroy"}, tenant: prefix)
          |> Ash.create!()

        result =
          receipt
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: prefix)
          |> Ash.destroy(opts)

        assert shape(result, Receipt) == shape, inspect(opts)
      end
    end

    @tag ash_fact: :f11
    test "deliver/2 returns each destroy shape with the delivery last", %{
      prefix: prefix,
      canary: canary
    } do
      for route <- [:destroy, :soft_destroy], {opts, shape} <- destroy_shapes() do
        subject = builder(prefix, route, unique_key("f11-#{route}")).()
        result = AshOnetime.deliver(subject, opts)

        assert %Delivery{outcome: :executed, values: %{secret: ^canary}} = delivery(result)
        normalized = Tuple.delete_at(result, tuple_size(result) - 1)

        expected =
          case shape do
            :ok -> {:ok, nil}
            {:ok, :notifications} -> {:ok, nil, :notifications}
            other -> other
          end

        assert shape(normalized, Resource) == expected, inspect({route, opts})
      end
    end

    @tag ash_fact: :f11
    test "create and update return their notifications before the delivery", %{
      prefix: prefix,
      canary: canary
    } do
      for route <- [:create, :update] do
        subject = builder(prefix, route, unique_key("f11-#{route}")).()

        assert {:ok, %Resource{}, notifications, %Delivery{values: %{secret: ^canary}}} =
                 AshOnetime.deliver(subject, return_notifications?: true)

        assert is_list(notifications)
      end
    end

    @tag ash_fact: :f11
    test "a soft destroy runs through update: the row stays, retired", %{prefix: prefix} do
      build = builder(prefix, :soft_destroy, unique_key("f11-soft"))
      subject = build.()

      {result, events} =
        with_writes(prefix, "ash_onetime_delivery_examples", fn ->
          AshOnetime.deliver(subject, return_destroyed?: true)
        end)

      # The executed call returns the stored projection, as a replay would: the action's
      # `fields` only, in the destroy's `:deleted` state (response.ex:269), so `retired`
      # is not in it. The row below shows the soft destroy kept it, retired.
      assert {:ok, %Resource{id: id, amount: 1} = record, %Delivery{outcome: :executed}} =
               result

      assert record.__meta__.state == :deleted
      assert %Ash.NotLoaded{field: :retired} = record.retired

      assert for({{:write, verb}, _pid, _state} <- events, do: verb) == ["UPDATE"]

      %{rows: [[count]]} =
        SQL.query!(
          Repo,
          ~s[SELECT count(*) FROM "#{prefix}"."ash_onetime_delivery_examples" WHERE id = $1 AND retired],
          [Ecto.UUID.dump!(id)]
        )

      assert count == 1
    end
  end

  # Probes.

  defp around(changeset, callback) do
    Observer.note(:around_in)
    result = callback.(changeset)
    Observer.note(:around_out)
    result
  end

  defp note_after_action(_subject, result) do
    Observer.note(:after_action)
    {:ok, result}
  end

  defp note_before_transaction(subject) do
    Observer.note(:before_transaction)
    subject
  end

  defp note_after_transaction(_subject, result) do
    Observer.note(:after_transaction)
    result
  end

  @doc false
  def refuse(:never), do: :ok

  # The data-layer writes to `table` in this installation while `fun` runs, noted with the
  # pid that ran them and the entry state in that pid, merged with the observer's events
  # in the order they happened.
  defp with_writes(prefix, table, fun) do
    event = Repo.config()[:telemetry_prefix] ++ [:query]
    handler = "ash-facts-#{System.unique_integer([:positive])}"
    parent = self()
    target = ~s("#{prefix}"."#{table}")

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, _config ->
          query = metadata.query

          with true <- String.contains?(query, target),
               [verb | _rest] <- String.split(query, " ", parts: 2),
               true <- verb in ["INSERT", "UPDATE", "DELETE"] do
            send(parent, {:fact, {:write, verb}, self(), Observer.entry_state()})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, Observer.events()}
    after
      :telemetry.detach(handler)
    end
  end

  defp destroy_shapes do
    [
      {[], :ok},
      {[return_destroyed?: true], {:ok, :record}},
      {[return_notifications?: true], {:ok, :notifications}},
      {[return_destroyed?: true, return_notifications?: true], {:ok, :record, :notifications}}
    ]
  end

  defp shape(:ok, _resource), do: :ok
  defp shape({:ok, nil}, _resource), do: {:ok, nil}
  defp shape({:ok, %resource{}}, resource), do: {:ok, :record}
  defp shape({:ok, list}, _resource) when is_list(list), do: {:ok, :notifications}
  defp shape({:ok, nil, list}, _resource) when is_list(list), do: {:ok, nil, :notifications}

  defp shape({:ok, %resource{}, list}, resource) when is_list(list),
    do: {:ok, :record, :notifications}

  defp shape(other, _resource), do: {:unexpected, other}

  defp delivery(result) when is_tuple(result), do: elem(result, tuple_size(result) - 1)

  defp assert_reference_only(subject) do
    assert %{ref: ref} = reference = subject.context.private.ash_onetime_delivery
    assert map_size(reference) == 1
    assert byte_size(ref) == 16
  end

  # Search.

  defp absent?(term, canary), do: :binary.match(:erlang.term_to_binary(term), canary) == :nomatch

  defp subjects(term) do
    term
    |> collect(&match?(%struct{} when struct in [Ash.Changeset, Ash.ActionInput], &1))
    |> Enum.filter(&Map.has_key?(&1.context[:private] || %{}, :ash_onetime_delivery))
  end

  defp contains?(term, predicate), do: collect(term, predicate) != []

  defp collect(term, predicate), do: term |> walk(predicate, []) |> Enum.reverse()

  defp walk(term, predicate, acc) do
    acc = if predicate.(term), do: [term | acc], else: acc

    case term do
      %_{} = struct -> struct |> Map.from_struct() |> Map.values() |> walk_all(predicate, acc)
      %{} = map -> map |> Enum.flat_map(&Tuple.to_list/1) |> walk_all(predicate, acc)
      list when is_list(list) -> walk_list(list, predicate, acc)
      tuple when is_tuple(tuple) -> tuple |> Tuple.to_list() |> walk_all(predicate, acc)
      _other -> acc
    end
  end

  defp walk_all(terms, predicate, acc), do: Enum.reduce(terms, acc, &walk(&1, predicate, &2))

  defp walk_list([head | tail], predicate, acc) when is_list(tail),
    do: walk_list(tail, predicate, walk(head, predicate, acc))

  defp walk_list([head | tail], predicate, acc),
    do: walk(tail, predicate, walk(head, predicate, acc))

  defp walk_list([], _predicate, acc), do: acc
end
