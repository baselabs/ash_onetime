for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.ValidationOrderTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :enforcement_raised_before_checkout_mutation

    @scenarios [
      {:claim, :open},
      {:lock, :not_applicable},
      {:complete_hold, :open},
      {:external_hold, :open},
      {:external_timeout, :not_applicable},
      {:release, :open},
      {:load, :not_applicable}
    ]

    for {scenario, transaction} <- @scenarios do
      @scenario scenario
      @transaction transaction
      test "#{partitioning || "plain"}: malformed #{@scenario} is rejected before native checkout", c do
        request = request!("validation-before-#{@scenario}")
        assert %Result{status: :admitted, claim: claim} =
                 Postgres.claim_committed(target(c), request, lock_timeout_ms: 300)
        pool = connection!(c, :runtime, 1)
        native_target = target(%{c | runtime_repo: pool})
        GenServer.stop(pool, :normal, 5000)

        assert %Result{reason: :checkout_unavailable} = Postgres.claim(native_target, request)
        assert %Result{
                 status: :failure,
                 reason: :invalid_request,
                 admission_dispatch: :not_started,
                 transaction: @transaction
               } = reject(@scenario, native_target, request, claim)
      end
    end

    test "#{partitioning || "plain"}: malformed inputs precede transaction preconditions without changing their triples", c do
      request = request!("validation-before-isolation")
      assert %Result{status: :admitted, claim: claim} =
               Postgres.claim_committed(target(c), request, lock_timeout_ms: 300)

      assert {:ok, :checked} = runtime_transaction(c, fn ->
        SQL.query!(c.runtime_repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
        for {scenario, transaction} <- @scenarios do
          assert %Result{status: :failure, reason: :invalid_request,
                         admission_dispatch: :not_started, transaction: ^transaction} =
                   reject(scenario, target(c), request, claim)
        end
        assert %Result{reason: :unsupported_isolation, admission_dispatch: :sent,
                       transaction: :open} = Postgres.claim(target(c), request)
        :checked
      end)
    end

    defp reject(:claim, target, request, _claim),
      do: Postgres.claim(target, %{request | retention_seconds: 0})
    defp reject(:lock, target, _request, claim),
      do: Postgres.lock_for_effect(target, claim, lock_timeout_ms: 0)
    defp reject(:complete_hold, target, _request, claim),
      do: Postgres.complete(target, claim, "test", :crypto.hash(:sha256, "response"), "response", "")
    defp reject(:external_hold, target, _request, claim),
      do: Postgres.complete_external(target, claim, "test", :crypto.hash(:sha256, "response"), "response", "", [])
    defp reject(:external_timeout, target, _request, claim),
      do: Postgres.complete_external(target, claim, "test", :crypto.hash(:sha256, "response"), "response", nil, lock_timeout_ms: 0)
    defp reject(:release, target, _request, _claim), do: Postgres.release(target, "")
    defp reject(:load, target, _request, claim), do: Postgres.load(target, claim, lock_timeout_ms: 0)
  end
end
