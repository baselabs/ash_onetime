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

## DPoP replay fencing (`commit: :independent`)

By default a nonce spend commits **inside** the action's transaction, so an action-body
failure rolls the spend back — correct when a retry will bear a fresh proof. For
[RFC 9449 (DPoP)](https://datatracker.ietf.org/doc/html/rfc9449#section-11.1) §11.1 replay
protection, declare `commit: :independent` so the claim commits in its own transaction
**before** the action body runs (via the `claim_committed` worker). A body failure then
leaves the proof spent for the acceptance window, and a retry with the same proof is rejected
with `:nonce_already_used`:

```elixir
protect :redeem do
  strategy :one_time_nonce
  scope([{:static, "redeem"}])
  key({:verified, :proof, MyApp.DPoPVerifier})
  window(max_age: {5, :minute}, clock_skew: {30, :second})
  commit :independent
end
```

The fence reuses the independent-commit primitive the external-effect path already depends on
(ADR-0001 "External recovery protocol"): the `claim_committed` worker spawns a process that
commits on its own connection, nesting-guarded so it can never accidentally commit inside the
action's transaction. The spend survives any downstream failure — a body raise, an
`after_action` hook, a downstream token mint — because the worker's transaction already
committed before the body ran.

Operational characteristics apply per request (not just per external effect): the worker uses
a second connection checkout while the caller holds one, and a 30s timeout that fails closed
with `:dispatched_unknown` if the worker stalls. Size the pool for the expected concurrency of
fenced endpoints. See the [operations guide](operations.md#dpop-replay-fence-operational-characteristics)
and ADR-0003 (Independent-commit nonce).

The option is nonce-only (declaring `commit:` on `:idempotency` is a compile error) and
default-off, so existing nonce consumers are unchanged.

`AshOnetime.Token` provides bounded canonical envelopes for package-owned nonces. HMAC-SHA-256
requires explicit same-service trust. Ed25519 uses private signing material and public
verification material for separated trust. Verification requires the expected algorithm and
namespace outside the token, rejects noncanonical bytes, and performs meaningful signature
comparison. Provider-specific signature formats belong in a verifier callback.

Misuse: idempotency is not replay defense. Serving a stored success for a replayed signed
request accepts the replay. Declare `:one_time_nonce` when reuse must be rejected.

Misuse: copying idempotency's optional untracked failure path into nonce admission turns a
store outage into a replay bypass. Nonce store failure and uncertainty always reject.
