for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.ResponseExpiryTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_response_expiry_mutation

    test "#{partitioning || "plain"}: an expired replay compares its fingerprint before returning response_expired",
         c do
      request = request!("expired-replay")
      grant = Postgres.claim_committed(target(c), request, lock_timeout_ms: 300)
      complete_claim(c, grant.claim.id)
      age_claim(c, grant.claim.id, retain: "transaction_timestamp()+interval '1 day'")
      assert {:ok, _} = step(c, "ash_onetime_expire_responses", "100")

      assert {:ok, %Result{status: :complete_expired} = loaded} =
               runtime_transaction(c, fn ->
                 Postgres.load(target(c), grant.claim, lock_timeout_ms: 300)
               end)

      state = %AshOnetime.Admission.State{
        class: :pending,
        strategy: :idempotency,
        resource: AshOnetime.Test.ActionExamples.Resource,
        action: :external_generic,
        request: request,
        target: target(c),
        claim: grant.claim
      }

      mismatched = %{
        state
        | request: %{request | fingerprint: :crypto.hash(:sha256, "different request")}
      }

      assert {:error, %AshOnetime.Error{code: :key_reused_with_different_request}} =
               AshOnetime.Admission.resolve(
                 loaded,
                 mismatched,
                 %{},
                 System.monotonic_time(),
                 :locked_external_finalize
               )

      assert {:error, %AshOnetime.Error{code: :response_expired}} =
               AshOnetime.Admission.resolve(
                 loaded,
                 state,
                 %{},
                 System.monotonic_time(),
                 :locked_external_finalize
               )
    end

    test "#{partitioning || "plain"}: expiry finishes beside held and unexpired responses", c do
      held =
        insert_claim(c)
        |> then(&complete_claim(c, &1, hold: "operation-hold"))
        |> then(&age_claim(c, &1, retain: "transaction_timestamp()+interval '1 day'"))

      early = insert_claim(c) |> then(&complete_claim(c, &1))

      eligible =
        insert_claim(c)
        |> then(&complete_claim(c, &1))
        |> then(&age_claim(c, &1, retain: "transaction_timestamp()+interval '1 day'"))

      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_expire_responses", "100")

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=ANY($1::uuid[])",
               [Enum.map([held, early], &Ecto.UUID.dump!/1)]
             ) == 2

      assert [[nil, nil, nil, %DateTime{}]] =
               SQL.query!(
                 c.runtime_repo,
                 "SELECT response_partition,response_codec,response_digest,response_expired_at FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
                 [Ecto.UUID.dump!(eligible)]
               ).rows

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             ) == 3
    end

    test "#{partitioning || "plain"}: cleanup removes an expired claim with zero payloads and cascades its outcomes",
         c do
      id = insert_claim(c) |> then(&complete_claim(c, &1)) |> then(&age_claim(c, &1))
      assert {:ok, _} = record_outcome(c, id)
      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_expire_responses", "100")
      assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_effect_outcomes")} WHERE claim_id=$1::uuid",
               [Ecto.UUID.dump!(id)]
             ) == 0
    end

    test "#{partitioning || "plain"}: expiry refuses a completed claim whose payload was deleted",
         c do
      id = insert_claim(c) |> then(&complete_claim(c, &1)) |> then(&age_claim(c, &1))

      SQL.query!(
        c.runtime_repo,
        "DELETE FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1::uuid",
        [Ecto.UUID.dump!(id)]
      )

      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  pg_code: "23514",
                  message: "completed idempotency claim payload cardinality mismatch"
                }
              }} = step(c, "ash_onetime_expire_responses", "100")

      assert scalar(
               c.runtime_repo,
               "SELECT response_expired_at IS NULL FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
               [Ecto.UUID.dump!(id)]
             )
    end

    test "#{partitioning || "plain"}: cache lifetime ends at the response deadline", c do
      start_supervised!(AshOnetime.Cache.Ets)

      request =
        request!("cache-lifetime", retention_seconds: 3600, response_retention_seconds: 600)

      grant = Postgres.claim_committed(target(c), request, lock_timeout_ms: 300)

      assert {:ok, %Result{status: :complete, claim: claim}} =
               runtime_transaction(c, fn ->
                 Postgres.complete_external(
                   target(c),
                   grant.claim,
                   "test",
                   :crypto.hash(:sha256, "response"),
                   "response",
                   nil,
                   lock_timeout_ms: 300
                 )
               end)

      config = %AshOnetime.Cache.Config{
        module: AshOnetime.Cache.Ets,
        timeout: 100,
        max_entry_bytes: 1024
      }

      before_cache = System.monotonic_time(:second)
      assert :stored = AshOnetime.Cache.store(config, claim, "response")
      [{_, _, expiry}] = :ets.lookup(AshOnetime.Cache.Ets, AshOnetime.Cache.key(claim))
      assert expiry - before_cache <= 600
      assert expiry - before_cache > 590
    end
  end
end

defmodule AshOnetime.ExternalState.ResponseRetentionVerifierTest do
  use ExUnit.Case, async: false
  @moduletag :external_state_response_expiry_mutation
  test "response retention above claim retention refuses the resource" do
    name = Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")

    quoted =
      quote do
        defmodule unquote(name) do
          use Ash.Resource,
            domain: nil,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshOnetime.Resource]

          postgres do
            table "response_retention_examples"
            repo AshOnetime.Test.Repo
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            create :perform do
              argument :idempotency_key, :string, allow_nil?: false
            end
          end

          onetime do
            protect :perform do
              strategy :idempotency
              scope([{:static, "response-retention"}])
              key({:client, :idempotency_key})
              fingerprint(arguments: [], attributes: [:id])

              response(AshOnetime.Test.Support.ResponseCodec,
                fields: [:id],
                classify: AshOnetime.Test.Support.ResponseClassifier
              )

              retention({1, :hour})
              response_retention({2, :hour})
            end
          end
        end
      end

    on_exit(fn ->
      :code.purge(name)
      :code.delete(name)
    end)

    assert_raise Spark.Error.DslError, ~r/response_retention.*retention/s, fn ->
      Code.compile_quoted(quoted)
    end
  end
end
