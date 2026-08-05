# One-time nonces

A one-time nonce is spend-once, reject-on-reuse protection. It is the strategy for replay
defense. A collision returns `:nonce_already_used`; no stored response exists to satisfy the
replayed request.

Nonce keys must come from trusted local facts. A verifier checks untrusted action input and
returns `AshOnetime.Verified`; a minter creates the same trusted shape locally. The verified
key, issuance time, optional expiry, and verifier identity are used to derive the claim but
are sanitized out of retained admission state. Reserved action input names cannot bypass
that boundary.

The accepted issuance band is inclusive:

```text
evaluated_at - max_age - clock_skew <= issued_at <= evaluated_at + clock_skew
```

An explicit expiry is also inclusive through its skew allowance. Cleanup begins one
microsecond after the safe replay horizon, so the exact boundary remains protected.
Composite verified facts use the latest issuance anchor, earliest expiry, and a digest of
all verifier identities; one invalid sibling rejects the whole claim.

Nonce admission always uses authoritative PostgreSQL state and always fails closed when the
store is unavailable or uncertain. Caches are ignored. There is no configurable untracked
execution, response replay, external-effect protocol, or retention override in nonce mode.

`AshOnetime.Token` provides bounded canonical envelopes for package-owned nonces. HMAC-SHA-256
requires explicit same-service trust. Ed25519 uses private signing material and public
verification material for separated trust. Verification requires the expected algorithm and
namespace outside the token, rejects noncanonical bytes, and performs meaningful signature
comparison. Provider-specific signature formats belong in a verifier callback.

Misuse: idempotency is not replay defense. Serving a stored success for a replayed signed
request accepts the replay. Declare `:one_time_nonce` when reuse must be rejected.

Misuse: copying idempotency's optional untracked failure path into nonce admission turns a
store outage into a replay bypass. Nonce store failure and uncertainty always reject.
