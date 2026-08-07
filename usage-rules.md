# ash_onetime usage rules

- Choose exactly one strategy for every protected action. Idempotency replays a classified
  stored result; one-time nonce protection rejects reuse. They are not interchangeable.
- Give equal weight to the two dangerous misuses: never use idempotency response replay as
  anti-replay protection, and never let nonce admission inherit idempotency's optional
  untracked failure direction.
- Declare a nonempty scope. Missing scope data is an error, never a global fallback. Include
  every tenant or principal boundary needed to prevent cross-scope blocking or replay.
- On a resource using `multitenancy strategy :attribute`, put the tenant discriminator in the
  scope (`{:attribute, <tenant_attribute>}` or a `{:tenant, module}` resolver). Those tenants
  share one set of claim tables, so the library rejects a tenant-less scope at compile time.
  Context multitenancy isolates by schema and needs no scope entry for this.
- Let the library derive operation identity from the protected resource and action. Do not
  substitute a caller-controlled operation name.
- Bind idempotency keys to all request arguments and attributes that change the effect.
  A conflicting fingerprint is an error, not a replay.
- PostgreSQL is authoritative. A cache may reduce response-payload reads after authoritative
  admission, but cannot grant or reject admission.
- One-time nonce admission fails closed whenever authoritative state is unavailable or
  uncertain. It has no stored-response, external-effect, or configurable failure surface.
- Idempotency may execute without a stored admission only when the store proves its statement
  was never dispatched and the DSL explicitly enables that branch. Ambiguity rejects.
- Treat verification callbacks as trusted local code. Action input may carry raw token
  material but cannot assert verified keys, timestamps, algorithms, or verification state.
- Use package-owned HMAC only when the same trust domain signs and verifies. Use Ed25519 or a
  verifier callback when signing and verification are separated.
- Application-specific signature schemes belong behind verifier callbacks; do not implement
  them in this package.
- Database effects use the protected resource's current AshPostgres repository and transaction.
  External effects require the idempotent execute/recover protocol and are forbidden for nonces.
- Cleanup occurs only after the strategy-safe horizon. Caches and cleanup jobs never decide
  correctness; processing external effects are not ordinary expiry candidates.
- A protected action's failure carries a typed `:code` that survives the Ash pipeline. Read it
  with `AshOnetime.Error.code/1` to drive HTTP status; do not assume a blanket class→status
  mapping, because `:store_invariant` and `:outcome_unknown` are server faults (500/503), not
  client input. See [Errors and HTTP mapping](documentation/errors.md).
- A protected action's success carries a replayed-vs-fresh signal. `AshOnetime.replayed?/1`
  returns `true` (stored replay), `false` (fresh execution), or `nil` (untracked execution,
  primitive-return action, or unprotected). Treat `nil` as "cannot tell," not as "fresh." See
  [Replay](documentation/replay.md).

See [the DSL guide](documentation/dsl.md), [idempotency guide](documentation/idempotency.md),
[nonce guide](documentation/one-time-nonces.md), [errors guide](documentation/errors.md),
[replay guide](documentation/replay.md), and [security model](documentation/security.md)
for examples and the complete contract.
