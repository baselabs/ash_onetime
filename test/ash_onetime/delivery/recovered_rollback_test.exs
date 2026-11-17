defmodule AshOnetime.Delivery.RecoveredRollbackTest do
  # Ash rolls an action back and an after-transaction hook turns the error into success.
  # The value of the rolled-back execution must not be delivered, or a retry under the
  # same key delivers a second one. Each case asserts at most one value per key.
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias AshOnetime.Delivery

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    install!(prefix)
  end

  for route <- [:create, :update, :destroy, :soft_destroy, :generic] do
    @route route

    @tag executing_only_recovered: true
    test "case A on #{route}: a failure after the entry completed is recovered", %{
      prefix: prefix
    } do
      build = builder(prefix, @route, unique_key("recovered"))
      Process.put(:fail_after_completion, true)

      first =
        build.()
        |> fail_after_completion(:fail_after_completion)
        |> recover_errors()
        |> AshOnetime.deliver()

      refute Process.get(:fail_after_completion)
      assert error_code(first) == :executing_only_lost
      assert claim_count(prefix) == 0

      retry = AshOnetime.deliver(build.())
      assert %Delivery{outcome: :executed} = elem(retry, tuple_size(retry) - 1)

      assert_at_most_one_value([first, retry])
    end

    @tag executing_only_recovered: true
    test "case B on #{route}: a nested deliver/2 from before_transaction is rolled back and recovered",
         %{prefix: prefix} do
      build = builder(prefix, @route, unique_key("recovered-nested"))
      Process.put(:fail_after_completion, true)
      Process.put(:nest, true)

      subject =
        build.()
        |> fail_after_completion(:fail_after_completion)
        |> recover_errors()
        |> hook(
          :before_transaction,
          fn pending ->
            if Process.delete(:nest),
              do: Process.put(:nested_result, AshOnetime.deliver(pending))

            pending
          end,
          []
        )

      outer = AshOnetime.deliver(subject)
      nested = Process.delete(:nested_result)

      refute Process.get(:fail_after_completion)
      assert error_code(nested) == :executing_only_lost
      assert %Delivery{outcome: :executed} = elem(outer, tuple_size(outer) - 1)

      assert_at_most_one_value([nested, outer])
    end
  end

  for route <- [:create, :update, :destroy, :soft_destroy] do
    @route route

    @tag executing_only_recovered: true
    test "case A on #{route}: an after-action failure the entry encloses is recovered", %{
      prefix: prefix
    } do
      build = builder(prefix, @route, unique_key("recovered-after-action"))
      Process.put(:fail_in_after_action, true)

      first =
        build.()
        |> fail_in_after_action(:fail_in_after_action)
        |> recover_errors()
        |> AshOnetime.deliver()

      refute Process.get(:fail_in_after_action)
      assert error_code(first) == :executing_only_lost

      retry = AshOnetime.deliver(build.())
      assert %Delivery{outcome: :executed} = elem(retry, tuple_size(retry) - 1)

      assert_at_most_one_value([first, retry])
    end
  end
end
