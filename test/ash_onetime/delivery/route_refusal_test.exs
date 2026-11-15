defmodule AshOnetime.Delivery.RouteRefusalTest do
  # Route refusals before arming (§2.7.4, decision 1). Each refused call returns its code
  # before anything runs: no key pair is generated, no entry is written, no consumer hook
  # runs and no claim is reserved. The bulk rows refuse the subject Ash's own bulk call
  # built, so the context key names `deliver/2` refuses are Ash's (F5).
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias Ash.Resource.Info
  alias AshOnetime.Delivery
  alias AshOnetime.Test.DeliveryExamples.Resource
  alias AshOnetime.Test.DeliveryGuarded.Hooks
  alias AshOnetime.Test.DeliveryGuarded.Resource, as: Guarded

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    install!(prefix)
  end

  for route <- [:create, :update, :destroy, :soft_destroy, :generic] do
    @route route

    @tag executing_only_route: :in_transaction
    test "an open transaction on #{route} is refused before anything runs", %{prefix: prefix} do
      test = self()
      build = builder(prefix, @route, unique_key("open-transaction"))

      subject =
        hook(build.(), :before_transaction, &ran(test, &1), [])

      {:ok, {result, touched}} =
        Ash.DataLayer.transaction(Resource, fn ->
          untouched(fn -> AshOnetime.deliver(subject) end)
        end)

      assert error_code(result) == :executing_only_in_transaction
      assert error_class(result) == Ash.Error.Invalid
      assert touched == []
      refute_received :ran
      assert claim_count(prefix) == 0
    end
  end

  @bulk_keys %{
    create: :bulk_create,
    update: :bulk_update,
    destroy: :bulk_destroy,
    soft_destroy: :bulk_destroy
  }

  for {route, bulk_key} <- @bulk_keys do
    @route route
    @bulk_key bulk_key

    @tag executing_only_route: :bulk
    test "the subject Ash's bulk call built on #{route} is refused, in and out of a transaction",
         %{prefix: prefix} do
      subject = bulk_subject(prefix, @route)

      # F5: Ash marks the subject with exactly this key (actions/create/bulk.ex,
      # actions/update/bulk.ex:574-580; a soft destroy runs through the update bulk path
      # with the destroy key, actions/destroy/bulk.ex:56-57).
      assert [@bulk_key] ==
               Enum.filter(
                 [:bulk_create, :bulk_update, :bulk_destroy],
                 &Map.has_key?(subject.context, &1)
               )

      {outside, touched_outside} = untouched(fn -> AshOnetime.deliver(subject) end)
      assert error_code(outside) == :executing_only_refused
      assert touched_outside == []

      {:ok, {inside, touched_inside}} =
        Ash.DataLayer.transaction(Guarded, fn ->
          untouched(fn -> AshOnetime.deliver(subject) end)
        end)

      assert error_code(inside) == :executing_only_in_transaction
      assert touched_inside == []
      assert claim_count(prefix) == 0
    end
  end

  describe "a subject not built for its action" do
    @describetag executing_only_route: :unbuilt

    test "an unbuilt changeset", %{prefix: prefix} do
      subject = %{
        builder(prefix, :create, unique_key("unbuilt")).()
        | __validated_for_action__: nil
      }

      assert_refused(subject, prefix)
    end

    test "a changeset built for another action", %{prefix: prefix} do
      built = Ash.Changeset.for_create(Resource, :seed, %{amount: 1}, tenant: prefix)
      issue = Info.action(Resource, :issue)
      assert_refused(%{built | action: issue}, prefix)
    end

    test "an action that declares no executing_only values", %{prefix: prefix} do
      assert_refused(
        Ash.Changeset.for_create(Resource, :seed, %{amount: 1}, tenant: prefix),
        prefix
      )
    end

    test "a subject of the wrong kind for its action", %{prefix: prefix} do
      changeset = builder(prefix, :create, unique_key("kind")).()
      mint = Info.action(Resource, :mint)
      assert_refused(%{changeset | action: mint}, prefix)
    end

    test "a term that is no subject", %{prefix: prefix} do
      for subject <- [nil, %{}, Ash.Query.new(Resource), {:changeset, Resource}] do
        assert_refused(subject, prefix)
      end

      assert error_code(AshOnetime.deliver(builder(prefix, :create, "k").(), :not_a_list)) ==
               :executing_only_refused
    end
  end

  defp assert_refused(subject, prefix) do
    {result, touched} = untouched(fn -> AshOnetime.deliver(subject) end)
    assert error_code(result) == :executing_only_refused
    assert error_class(result) == Ash.Error.Invalid
    assert touched == []
    assert claim_count(prefix) == 0
  end

  # The changeset Ash built inside a real bulk call, as the consumer's before-transaction
  # hook received it, at max_concurrency 0 so the hook runs in this process.
  defp bulk_subject(prefix, route) do
    key = unique_key("bulk-#{route}")
    opts = [tenant: prefix, authorize?: false, return_errors?: true, max_concurrency: 0]
    Hooks.capture(self())

    try do
      case route do
        :create ->
          Ash.bulk_create([%{amount: 1, request_key: key}], Guarded, :issue, opts)

        route ->
          record =
            Guarded
            |> Ash.Changeset.for_create(:seed, %{amount: 1}, tenant: prefix, authorize?: false)
            |> Ash.create!()

          action = %{update: :rotate, destroy: :revoke, soft_destroy: :retire}[route]
          opts = Keyword.merge(opts, resource: Guarded, strategy: [:stream])

          if route == :update,
            do: Ash.bulk_update([record], action, %{amount: 2, request_key: key}, opts),
            else: Ash.bulk_destroy([record], action, %{request_key: key}, opts)
      end
    after
      Hooks.release()
    end

    assert_received {:captured, %Ash.Changeset{} = subject}
    subject
  end

  # Runs `fun` with call tracing on this process and returns its result with every
  # key-pair generation and every write of a delivery entry it made.
  defp untouched(fun) do
    test = self()
    tracer = spawn_link(fn -> collect(test, []) end)

    patterns = [
      {{:crypto, :generate_key, 2}, [{[:ecdh, :x25519], [], []}]},
      {{:erlang, :put, 2}, [{[{Delivery, :_}, :_], [], []}]}
    ]

    result =
      try do
        for {mfa, spec} <- patterns, do: :erlang.trace_pattern(mfa, spec, [:local])
        :erlang.trace(test, true, [:call, {:tracer, tracer}])
        fun.()
      after
        :erlang.trace(test, false, [:call])
        for {mfa, _spec} <- patterns, do: :erlang.trace_pattern(mfa, false, [:local])
      end

    ref = :erlang.trace_delivered(test)
    receive(do: ({:trace_delivered, ^test, ^ref} -> :ok))
    send(tracer, {:report, test})
    events = receive(do: ({:events, ^tracer, events} -> events))

    {result,
     for(
       {:trace, _pid, :call, {module, function, _arity}, _args} <- events,
       do: {module, function}
     )}
  end

  defp collect(test, events) do
    receive do
      {:report, ^test} -> send(test, {:events, self(), Enum.reverse(events)})
      event -> collect(test, [event | events])
    end
  end

  defp error_class({:error, %module{}}), do: module
  defp error_class(_other), do: nil

  # A consumer hook body: notes that it ran and returns the subject unchanged.
  defp ran(test, subject) do
    send(test, :ran)
    subject
  end
end
