# ash_onetime usage rules

- Choose exactly one strategy for every protected action. Idempotency and one-time
  nonce semantics are not interchangeable.
- Declare a nonempty scope. Missing scope data is an error, never a global fallback.
- Let the library derive operation identity from the protected resource and action.
- PostgreSQL is authoritative. A cache may reduce payload reads but cannot grant or
  reject admission.
- One-time nonce admission fails closed whenever authoritative state is unavailable or
  uncertain.
- Idempotency may execute without a stored admission only when the store proves the
  admission statement was never dispatched; that path emits value-free telemetry.
- Treat verification callbacks as trusted local code. Action input may carry raw token
  material but cannot assert verified keys, timestamps, algorithms, or verification
  state.
- Use package-owned HMAC only when the same trust domain signs and verifies. Use
  Ed25519 or a verifier callback when signing and verification are separated.
- Provider-specific signatures belong behind verifier callbacks; do not implement them
  in this package.
- Database effects use the protected resource's current AshPostgres repository and
  transaction. External effects require the idempotency recovery protocol and are not
  allowed for one-time nonces.
- Cleanup occurs only after the strategy-safe horizon. Caches and cleanup jobs never
  decide correctness.
