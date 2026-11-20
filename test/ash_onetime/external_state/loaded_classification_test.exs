for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.LoadedClassificationTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag :enforcement_loaded_classification_mutation

    for {kind, status, reason} <- [
      {:processing, :processing, nil},
      {:complete, :complete, nil},
      {:expired, :complete_expired, nil},
      {:corrupt, :failure, :corrupt_payload},
      {:invalid, :failure, :store_invariant},
      {:nonce, :collision, nil}
    ], operation <- [:load, :collision] do
      @kind kind
      @status status
      @reason reason
      @operation operation
      test "#{partitioning || "plain"}: #{@operation} classifies #{@kind} from authoritative state", c do
        request =
          if @kind == :nonce do
            {:ok, request} = Claim.nonce(operation_hash: :crypto.hash(:sha256, "operation"), scope_hash: :crypto.hash(:sha256, "scope"), key_hash: :crypto.hash(:sha256, "loaded"), verified: [%AshOnetime.Verified{key: "loaded", issued_at: DateTime.utc_now(), verifier_id: "test"}], max_age: 60, clock_skew: 0, clock: AshOnetime.Clock)
            request
          else
            request!("loaded")
          end

        {:ok, %Result{status: :admitted, claim: claim}} = runtime_transaction(c, fn -> Postgres.claim(target(c), request) end)

        if @kind in [:complete, :expired, :corrupt], do: complete_claim(c, claim.id)

        if @kind == :expired do
          age_claim(c, claim.id, retain: "transaction_timestamp()+interval '1 day'")
          assert {:ok, _} = step(c, "ash_onetime_expire_responses", "1")
        end

        if @kind == :corrupt do
          SQL.query!(c.owner_repo, "UPDATE #{rel(c, "ash_onetime_response_payloads")} SET encoded_response='changed'::bytea WHERE claim_id=$1::uuid", [Ecto.UUID.dump!(claim.id)])
        end

        if @kind == :invalid do
          SQL.query!(c.owner_repo, "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DROP CONSTRAINT ash_onetime_idempotency_claims_state_check", [])
          assert {:ok, _} = owner_replica(c, fn -> SQL.query!(c.owner_repo, "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET state='failure' WHERE id=$1::uuid", [Ecto.UUID.dump!(claim.id)]) end)
          on_exit(fn ->
            owner_replica(c, fn -> SQL.query!(c.owner_repo, "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET state='processing' WHERE id=$1::uuid", [Ecto.UUID.dump!(claim.id)]) end)
            SQL.query!(c.owner_repo, "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ADD CONSTRAINT ash_onetime_idempotency_claims_state_check CHECK (state IN ('processing','complete'))", [])
          end)
        end

        assert {:ok, %Result{status: @status, reason: @reason}} = runtime_transaction(c, fn ->
          if @operation == :load, do: Postgres.load(target(c), claim, lock_timeout_ms: 300), else: Postgres.claim(target(c), request)
        end)
      end
    end
  end
end
