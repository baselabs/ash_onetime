# Security model

`ash_onetime` protects keyed effects against concurrent duplication and replay within an
explicit namespace. It does not authenticate a caller by itself, provide delivery, or turn
an unrecoverable external API into a transactional peer.

## Trust boundaries

- PostgreSQL is the sole admission authority. A cache cannot admit or reject work.
- Scope is mandatory. Missing tenant, attribute, argument, or resolver data is an error.
- Operation identity is derived from the resource and action; callers cannot supply it.
- Verification callbacks and minters return trusted local `AshOnetime.Verified` facts.
  Action input remains untrusted even when field names resemble trusted state.
- Stored responses are bound to locator hashes, request fingerprint, codec, SHA-256 digest,
  exact payload bytes, and declared Ash return shape before replay.
- One-time nonce store uncertainty fails closed. Only a proven never-dispatched idempotency
  checkout may use an explicitly enabled untracked path.
- External recovery treats every outcome except `{:ok, result}` and authoritative `:absent`
  as ambiguous and never retries the peer effect under a new decision.

Canonical encoding is bounded, type-tagged, length-framed, and deterministic. Token
verification binds exact canonical body bytes, expected namespace, algorithm, key identifier,
issuance, and expiry. HMAC key material must declare same-service trust. Ed25519 separates
private signing and public verification roles. Key resolution is purpose-specific; secrets
must remain in the consumer's secret store and must not be logged or committed.

## Named misuses

Misuse: using idempotency as replay defense. Idempotency returns a stored response on reuse;
it does not reject a captured signed request. Use `:one_time_nonce`.

Misuse: letting nonce admission inherit idempotency's optional untracked failure direction.
Nonce store failure and uncertainty must reject; there is no nonce fail-open configuration.

Misuse: using a shared HMAC secret across a separated signer/verifier boundary. Anyone who can
verify can then forge. Use Ed25519 or a verifier callback backed by the provider's supported
scheme.

Retention and cleanup are security boundaries. Deleting a nonce at the inclusive horizon can
admit replay; cleanup is strictly later. Processing external claims are retained for recovery.
Telemetry is deliberately value-free to avoid exporting keys, tokens, signatures, payloads,
or verifier identities.

Report suspected vulnerabilities through the private process in [SECURITY](../SECURITY.md).
