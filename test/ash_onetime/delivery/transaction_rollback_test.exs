defmodule AshOnetime.Delivery.TransactionRollbackTest do
  # A value delivered inside a transaction that later rolls back must not be delivered a
  # second time when the same key is retried. Each case runs on every route and asserts
  # at most one value per key.
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias AshOnetime.Delivery
  alias AshOnetime.Test.DeliveryExamples.{NestedDeliverCheck, Outer, Resource}

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    install!(prefix)
  end

  for route <- [:create, :update, :destroy, :soft_destroy, :generic] do
    @route route

    @tag executing_only_transaction: true
    test "case A on #{route}: a caller transaction rolls back after deliver/2 returned", %{
      prefix: prefix
    } do
      build = builder(prefix, @route, unique_key("caller-transaction"))

      first =
        Ash.DataLayer.transaction(Resource, fn ->
          result = AshOnetime.deliver(build.())
          Ash.DataLayer.rollback(Resource, {:caller_rolled_back, result})
        end)

      assert {:error, {:caller_rolled_back, refused}} = first
      assert error_code(refused) == :executing_only_in_transaction
      assert claim_count(prefix) == 0

      retry = AshOnetime.deliver(build.())
      assert %Delivery{outcome: :executed} = elem(retry, tuple_size(retry) - 1)

      assert_at_most_one_value([first, retry])
    end

    @tag executing_only_transaction: true
    test "case B on #{route}: a nested deliver/2 in a policy check under Ash's transaction", %{
      prefix: prefix
    } do
      build = builder(prefix, @route, unique_key("policy-transaction"))

      Process.put({NestedDeliverCheck, :subject}, build)

      outer =
        Outer
        |> Ash.ActionInput.for_action(:outer, %{})
        |> Ash.run_action(authorize?: true)

      nested = Process.delete({NestedDeliverCheck, :result})

      assert {:error, _error} = outer
      assert error_code(nested) == :executing_only_in_transaction
      assert claim_count(prefix) == 0

      retry = AshOnetime.deliver(build.())
      assert %Delivery{outcome: :executed} = elem(retry, tuple_size(retry) - 1)

      assert_at_most_one_value([nested, retry])
    end
  end
end
