defmodule AshOnetime.Store.ClaimTest do
  use ExUnit.Case, async: true

  # ROADMAP H32: structural tests for the Claim/Claim.Request structs. These are the
  # authoritative admission records; a field-shape regression should surface directly, not via
  # an integration test. The @enforce_keys contract (the security-relevant fields that must
  # be present at construction) is the load-bearing invariant.

  alias AshOnetime.Store.Claim
  alias AshOnetime.Store.Claim.Request

  describe "Claim.Request struct" do
    test "constructs with the enforced security-relevant fields" do
      request = %Request{
        strategy: :idempotency,
        id: Ecto.UUID.generate(),
        operation_hash: :crypto.hash(:sha256, "op"),
        scope_hash: :crypto.hash(:sha256, "scope"),
        key_hash: :crypto.hash(:sha256, "key")
      }

      assert request.strategy == :idempotency
      assert is_binary(request.id)
      assert byte_size(request.operation_hash) == 32
      assert byte_size(request.scope_hash) == 32
      assert byte_size(request.key_hash) == 32
    end

    test "defaults clock to AshOnetime.Clock when not supplied" do
      request = base_request()
      assert request.clock == AshOnetime.Clock
    end

    test "optional fields (fingerprint, retention_seconds, verified, max_age, clock_skew) are nil by default" do
      request = base_request()
      assert request.fingerprint == nil
      assert request.retention_seconds == nil
      assert request.verified == nil
      assert request.max_age == nil
      assert request.clock_skew == nil
    end

    test "a nonce strategy carries verified facts and clock-skew/window fields" do
      request = %Request{
        strategy: :one_time_nonce,
        id: Ecto.UUID.generate(),
        operation_hash: :crypto.hash(:sha256, "op"),
        scope_hash: :crypto.hash(:sha256, "scope"),
        key_hash: :crypto.hash(:sha256, "key"),
        verified: [],
        max_age: 60,
        clock_skew: 5
      }

      assert request.strategy == :one_time_nonce
      assert request.verified == []
      assert request.max_age == 60
      assert request.clock_skew == 5
    end
  end

  describe "Claim struct" do
    test "constructs with the enforced fields including the retention horizons" do
      now = DateTime.utc_now()

      claim = %Claim{
        strategy: :idempotency,
        id: Ecto.UUID.generate(),
        logical_partition: "global",
        operation_hash: :crypto.hash(:sha256, "op"),
        scope_hash: :crypto.hash(:sha256, "scope"),
        key_hash: :crypto.hash(:sha256, "key"),
        admitted_at: now,
        retain_until: DateTime.add(now, 3600, :second),
        inserted_at: now
      }

      assert claim.strategy == :idempotency
      assert claim.admitted_at == now
      assert claim.inserted_at == now
      # retain_until is the bounded-retention horizon; it must be orderable after admitted_at.
      assert DateTime.compare(claim.retain_until, claim.admitted_at) == :gt
    end

    test "the response-binding fields (codec, digest, partition) are nil by default" do
      claim = base_claim()
      assert claim.response_codec == nil
      assert claim.response_digest == nil
      assert claim.response_partition == nil
    end

    test "the nonce-specific fields (issued_at, expires_at, verifier_id) are nil by default" do
      claim = base_claim()
      assert claim.issued_at == nil
      assert claim.expires_at == nil
      assert claim.verifier_id == nil
    end

    test "state is nil by default (the claim is not yet in a known admission state)" do
      claim = base_claim()
      assert claim.state == nil
    end
  end

  describe "fingerprint presence distinguishes the strategies" do
    # Idempotency carries a fingerprint (the replay-binding digest); nonce does not (it binds
    # by verifier_id + window, not a response fingerprint). The struct allows either, but the
    # presence pattern is strategy-specific.
    test "an idempotency claim carries a 32-byte fingerprint" do
      claim = %Claim{base_claim() | fingerprint: :crypto.hash(:sha256, "fp")}
      assert byte_size(claim.fingerprint) == 32
    end

    test "a nonce claim omits the fingerprint" do
      claim = %Claim{base_claim() | strategy: :one_time_nonce}
      assert claim.fingerprint == nil
    end
  end

  defp base_request do
    %Request{
      strategy: :idempotency,
      id: Ecto.UUID.generate(),
      operation_hash: :crypto.hash(:sha256, "op"),
      scope_hash: :crypto.hash(:sha256, "scope"),
      key_hash: :crypto.hash(:sha256, "key")
    }
  end

  defp base_claim do
    now = DateTime.utc_now()

    %Claim{
      strategy: :idempotency,
      id: Ecto.UUID.generate(),
      logical_partition: "global",
      operation_hash: :crypto.hash(:sha256, "op"),
      scope_hash: :crypto.hash(:sha256, "scope"),
      key_hash: :crypto.hash(:sha256, "key"),
      admitted_at: now,
      retain_until: DateTime.add(now, 3600, :second),
      inserted_at: now
    }
  end
end
