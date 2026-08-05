# Idempotency

Idempotency means once-per-key execution with stored-result replay. It is for safe retries,
not for rejecting a captured request.

The logical admission identity is derived from the protected resource and action, explicit
scope components, and key components. A separate fingerprint binds request content. The
caller cannot override the operation hash. Reusing a key with a different fingerprint is
terminal and never executes again.

For local effects, PostgreSQL claims admission inside the Ash action's existing transaction.
The unique constraint decides concurrent races; there is no admission pre-read. The effect,
claim, encoded response, and response digest commit or roll back together. A completed retry
loads authoritative claim metadata and bytes, validates codec, digest, fingerprint, and
locator identity, then reconstructs the declared Ash return type without running the action,
notifications, or unsafe lifecycle hooks again.

Actions with the same key remain independent when their resource/action identity differs.
Actions with the same operation and key remain independent when their explicit scope differs.
Natural attribute keys and client-supplied keys have the same database race semantics.

## Failure direction

All sent, rolled-back, disconnected, or ambiguous admission outcomes fail closed. The only
optional untracked path is a checkout failure classified as never dispatched and not
applicable to a transaction. It requires explicit
`on_definite_store_failure :execute_untracked` and emits
`[:ash_onetime, :untracked_execution]`. This exception is retry-safe idempotency behavior;
it is structurally unavailable to one-time nonces.

An optional cache can replace authoritative response payload bytes only after PostgreSQL has
returned a complete claim and every cached identity and digest field matches. A cache miss,
timeout, circuit-open result, corrupt value, or stale entry falls back to authoritative bytes;
the cache never admits an effect.

Do not describe this as exactly-once delivery. The guarantee is a PostgreSQL-authoritative,
once-per-key local effect and typed replay within the declared retention boundary.
