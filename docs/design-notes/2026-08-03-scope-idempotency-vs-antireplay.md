# Scope: idempotency and anti-replay

Idempotency and nonce protection serve different rules. Idempotency executes once per key
and replays a classified response; nonce protection rejects every reuse and never replays.
Each protected action chooses explicitly. Neither strategy inherits the other's failure mode.
PostgreSQL owns admission; caches and schedulers are optional.
Nonce admission fails closed; idempotency's explicitly enabled untracked path requires proof
that no admission statement was dispatched and surfaces through telemetry.

## Explicit natural identities

Both strategies accept natural keys as well as minted material. Bind keys to the resource,
action, and explicit nonempty scope, including every shared-table tenant boundary.
Idempotency fingerprints every effect-changing input. A conflicting request is rejected.
A nonce's spend key comes from trusted verification facts, never a pre-verified input flag.

## Verification boundary

Package-owned HMAC serves a shared signing/verifying trust domain; Ed25519 separates them.
Provider-specific authentication stays behind trusted verifier callbacks.
Verify authenticity before spending; the ledger consumes the resulting key and time facts
without interpreting the provider's signature scheme.

## Windows and transactions

Verified facts carry the exact spend key and issuance time, with optional expiry.
Acceptance uses max-age and clock-skew: issuance must lie between
`evaluated_at - max_age - skew` and `evaluated_at + skew`, subject to expiry.
Retention covers the acceptance horizon plus the cleanup safety margin.
Cleanup never makes an otherwise valid spent proof admissible again.

Admission precedes the guarded effect in its current repository and transaction.
Default nonce spends roll back with body failure; `commit: :independent` deliberately keeps
the spend after failure for request-attempt replay fencing.
External effects use idempotency's independently committed recovery protocol, never nonce mode.
Ordered authority chains, delegation policy, and business authorization belong to consumers.
The library supplies keyed-effect admission and trusted verification seams.
It does not depend on an authority protocol or provider integration package.
