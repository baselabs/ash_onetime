for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.AdmissionClassificationTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.{Admission, Response}
    alias AshOnetime.Admission.State
    alias AshOnetime.Resource.Info, as: ResourceInfo
    @moduletag hash_partitions: partitioning

    for {rule, kind, mode, expected} <- [
          {"admission-classify-admitted", :admitted, :local_claim, {:execute, :execute}},
          {"admission-classify-processing-local", :processing, :local_claim,
           {:error, :request_in_progress}},
          {"admission-classify-processing-committed", :processing, :committed_external_claim,
           {:recover, :processing}},
          {"admission-classify-processing-finalize", :processing, :locked_external_finalize,
           {:execute, :external_execute}},
          {"admission-classify-processing-locked", :processing, :locked_external_claim,
           {:execute, :external_execute}},
          {"admission-classify-processing-mismatch", :processing_mismatch, :local_claim,
           {:error, :key_reused_with_different_request}},
          {"admission-classify-processing-invalid", :processing_invalid, :local_claim,
           {:error, :store_invariant}},
          {"admission-classify-complete", :complete, :local_claim, {:replay, 42}},
          {"admission-classify-complete-mismatch", :complete_mismatch, :local_claim,
           {:error, :key_reused_with_different_request}},
          {"admission-classify-complete-invalid", :complete_invalid, :local_claim,
           {:error, :store_invariant}},
          {"admission-classify-expired", :expired, :local_claim, {:error, :response_expired}},
          {"admission-classify-expired-mismatch", :expired_mismatch, :local_claim,
           {:error, :key_reused_with_different_request}},
          {"admission-classify-expired-invalid", :expired_invalid, :local_claim,
           {:error, :store_invariant}},
          {"admission-classify-nonce", :nonce, :local_claim, {:error, :nonce_already_used}},
          {"admission-classify-nonce-invalid", :nonce_invalid, :local_claim,
           {:error, :store_invariant}}
        ] do
      @kind kind
      @mode mode
      @expected expected
      @tag [
        {String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}
      ]
      test "#{partitioning || "plain"}: #{rule} resolves a native store result", c do
        resource = AshOnetime.Test.ActionExamples.Resource
        protection = ResourceInfo.protection(resource, :redeem)

        {:ok, contract} =
          Response.contract(resource, :redeem, protection.response, %{limits: protection.limits})

        nonce = @kind in [:nonce, :nonce_invalid]

        request =
          if nonce do
            {:ok, request} =
              Claim.nonce(
                operation_hash: :crypto.hash(:sha256, "operation"),
                scope_hash: :crypto.hash(:sha256, "scope"),
                key_hash: :crypto.hash(:sha256, "admission"),
                verified: [
                  %AshOnetime.Verified{
                    key: "admission",
                    issued_at: DateTime.utc_now(),
                    verifier_id: "test"
                  }
                ],
                max_age: 60,
                clock_skew: 0,
                clock: AshOnetime.Clock
              )

            request
          else
            request!("admission")
          end

        granted =
          if @mode == :local_claim do
            {:ok, granted} = runtime_transaction(c, fn -> Postgres.claim(target(c), request) end)
            granted
          else
            Postgres.claim_committed(target(c), request, lock_timeout_ms: 300)
          end

        %Result{status: :admitted, claim: claim} = granted

        if @kind in [
             :complete,
             :complete_mismatch,
             :complete_invalid,
             :expired,
             :expired_mismatch,
             :expired_invalid
           ] do
          {:ok, encoded} = Response.encode(42, contract, [])

          {:ok, %Result{status: :complete}} =
            runtime_transaction(c, fn ->
              Postgres.complete(target(c), claim, encoded.codec, encoded.digest, encoded.payload)
            end)
        end

        if @kind in [:expired, :expired_mismatch, :expired_invalid] do
          age_claim(c, claim.id, retain: "transaction_timestamp()+interval '1 day'")
          assert {:ok, _} = step(c, "ash_onetime_expire_responses", "1")
        end

        result =
          cond do
            @kind == :admitted ->
              granted

            @mode == :committed_external_claim ->
              Postgres.claim_committed(target(c), request, lock_timeout_ms: 300)

            @mode in [:locked_external_claim, :locked_external_finalize] ->
              {:ok, result} =
                runtime_transaction(c, fn ->
                  Postgres.lock_for_effect(target(c), claim, lock_timeout_ms: 300)
                end)

              result

            true ->
              {:ok, result} = runtime_transaction(c, fn -> Postgres.claim(target(c), request) end)
              result
          end

        request =
          if @kind in [:processing_mismatch, :complete_mismatch, :expired_mismatch],
            do: %{request | fingerprint: :crypto.hash(:sha256, "changed request")},
            else: request

        admission_target =
          if @kind in [:processing_invalid, :complete_invalid, :expired_invalid, :nonce_invalid],
            do: %{target(c) | logical_partition: "other"},
            else: target(c)

        state = %State{
          class: :pending,
          strategy: request.strategy,
          resource: resource,
          action: :redeem,
          request: request,
          target: admission_target,
          claim: claim,
          contract: contract,
          cache: AshOnetime.Cache.config([])
        }

        actual =
          case Admission.resolve(result, state, protection, System.monotonic_time(), @mode) do
            {:error, %AshOnetime.Error{code: code}} -> {:error, code}
            {:execute, %State{class: class}} -> {:execute, class}
            {:recover, %State{claim: %{state: status}}} -> {:recover, status}
            {:replay, value, %State{class: :replay}} -> {:replay, value}
            value -> value
          end

        assert actual == @expected
      end
    end
  end
end
