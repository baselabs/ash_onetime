# One-time nonces

A one-time nonce is spend-once, reject-on-reuse protection. It is the strategy for replay
defense. A collision returns `:nonce_already_used`; no stored response exists to satisfy the
replayed request.

Nonce keys must come from trusted local facts. A verifier checks untrusted action input and
returns `AshOnetime.Verified`; a minter creates the same trusted shape locally through
`AshOnetime.Verified.new/1`, the type's only sanctioned constructor (the type is opaque —
hosts never build the struct literal). The verified
key, issuance time, optional expiry, and verifier identity are used to derive the claim but
are sanitized out of retained admission state. Reserved action input names cannot bypass
that boundary.

The accepted issuance band is inclusive:

```text
evaluated_at - max_age - clock_skew <= issued_at <= evaluated_at + clock_skew
```

An explicit expiry is also inclusive through its skew allowance. Composite verified facts
validate each sibling's issuance and expiry; one invalid sibling rejects the whole claim.
The stored aggregate uses the latest issuance anchor and a digest of all verifier identities.

Nonce admission always uses authoritative PostgreSQL state and always fails closed when the
store is unavailable or uncertain. Caches are ignored. There is no configurable untracked
execution, response replay, or external-effect protocol in nonce mode.

## Retain claims longer than proof acceptance

From 1.6.0, optional `retain_for` separates claim retention from `max_age`. For example,
accept proofs up to 300 seconds old while retaining their nonce claims for 664 seconds:

<!-- nonce-retention-dsl:start -->
```elixir
protect :redeem do
  strategy :one_time_nonce
  scope [{:static, "redeem"}]
  key {:verified, :proof, MyApp.DPoPVerifier}
  window max_age: {5, :minute}, clock_skew: {0, :second}, retain_for: {664, :second}
end
```
<!-- nonce-retention-dsl:end -->

`retain_for` defaults to `max_age`, preserving 1.5.0 behavior when omitted. It must be at
least `max_age`; `retain_for + clock_skew` cannot exceed 2,147,483,647 seconds. Invalid DSL
values fail compilation; invalid transaction options return `:invalid_request`. An unclaimed
proof older than `max_age + clock_skew` still returns `:invalid_nonce_window`.

The retention deadline is `issued_at + retain_for + clock_skew + cleanup margin`;
composite proofs use the latest sibling deadline. The existing PostgreSQL safety floor
also keeps the deadline at least one cleanup margin after admission. Cleanup removes rows
only strictly after their stored deadline. Explicit token expiry still limits acceptance;
it does not shorten retention.

With `retain_for` explicitly configured, a verified late replay returns
`:nonce_already_used` while `now <= retain_until`, using the stored deadline. Past that
deadline it returns `:invalid_nonce_window`, even if cleanup has not removed the row.
Changing the presented retention policy cannot extend or shorten an existing deadline.
Omitting `retain_for` preserves the legacy window error. Verifiers still authenticate
proofs before admission and may reject them earlier (including `Token.verify/3`'s own
window checks).

An expired proof with explicit `retain_for` now performs a read to classify the refusal:
its store result has `admission_dispatch: :sent`, including when no matching row exists.
Without `retain_for`, the window refusal remains `admission_dispatch: :not_started`.
Neither refusal admits the request or runs the protected effect. These dispatch fields
describe the admission attempt; the separate deadline reader always reports
`:not_started` on failure because it has no admission effect.

Transaction-owned callers pass integer seconds. Inside the caller's existing transaction,
with a trusted `verified_fact` and an authorized locator, the following also reads the
stored deadline. `repo` is the host repo, `prefix` its schema (or `nil`), and `clock` a
trusted module implementing `AshOnetime.Clock` (`AshOnetime.Clock` uses UTC time):

<!-- nonce-retention-transaction:start -->
```elixir
options = [
  operation: {MyApp.Gateway, :invoke},
  partition: tenant_id,
  scope: principal_id,
  key: nonce,
  prefix: prefix,
  verified: [verified_fact],
  max_age: 300,
  retain_for: 664,
  clock_skew: 0,
  clock: clock
]

:ok = AshOnetime.Transaction.nonce(repo, options)
locator = Keyword.take(options, [:operation, :partition, :scope, :key, :prefix])
{:ok, deadline} = AshOnetime.Transaction.nonce_retention_deadline(repo, locator)
deadline
```
<!-- nonce-retention-transaction:end -->

`nonce_retention_deadline/2` returns `{:ok, datetime}`, `:not_found`, or `{:error, error}`.
It can also run outside a transaction and observes the stored deadline without changing it.
It reads claims created by `Transaction.nonce/2` using that boundary's locator; it does not
translate resource DSL keys. The complete locator is a capability: the host must authorize
the caller's access to its partition, scope, key, operation, and schema before this call.
The library does not perform actor authorization. A read grants no admission. Inside a
transaction the query uses a savepoint, so a query error (such as an uninstalled schema)
does not abort the caller's transaction or discard its earlier writes.
No migration is required: nonce claims already store `retain_until`. Existing rows keep
their original deadlines; changing configuration affects newly admitted claims.

## DPoP replay fencing (`commit: :independent`)

By default a nonce spend commits **inside** the action's transaction, so an action-body
failure rolls the spend back — correct when a retry will bear a fresh proof. For
[RFC 9449 (DPoP)](https://datatracker.ietf.org/doc/html/rfc9449#section-11.1) §11.1 replay
protection, declare `commit: :independent` so the claim commits in its own transaction
**before** the action body runs (via the `claim_committed` worker). A body failure then
leaves the proof spent for the retention window, and a retry with the same proof is rejected
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
