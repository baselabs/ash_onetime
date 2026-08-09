# ADR 0001: Single-use keyed effects

- Status: Accepted
- Date: 2026-08-04

## Context

Ash actions need two related but incompatible protections. Idempotency executes an
effect once per key and replays a classified stored result. A one-time nonce authenticates
a single opportunity and rejects every collision. Sharing defaults or failure behavior
between those strategies can silently turn replay defense into response replay or let a
nonce fail open.

The package must remain standalone. Reference applications and adjacent security
packages may inform the design but are not dependencies.

## Decision

### Separate strategies

Every protected action declares exactly one strategy: `:idempotency` or
`:one_time_nonce`. There is no default. Idempotency owns processing, completion, result
classification, response persistence, replay, and recovery. One-time nonce owns trusted
issuance facts, window validation, reservation, spend, and collision rejection; it has no
stored-response or external-effect configuration.

### Explicit scope and operation identity

Every protected action declares a nonempty scope. Missing or unresolved scope data is an
error and never becomes a global scope. The library adds a non-overridable operation
identity derived from the resource and action so the same caller key cannot collide or
replay across operations.

### PostgreSQL authority and transaction boundary

PostgreSQL is authoritative for admission. Optional caches can return a response payload
only after an authoritative collision binds that payload to the claim; they cannot grant
execution or reject a nonce. Database effects reserve admission in the protected
resource's current AshPostgres repository and transaction. There is no cross-repository
router or independent admission transaction for database effects. (Two deliberate
exceptions commit independently via the `claim_committed` worker: the external-recovery
protocol below, and the opt-in nonce `commit: :independent` replay fence — see
[3. Independent-commit nonce](0003-independent-commit-nonce.md).)

### External recovery protocol

Only idempotency supports external effects. The adapter supplies a stable operation key,
an idempotent `execute` callback, and a `recover` callback. The package commits a
`processing` recovery point in the same repository before contacting the peer. A retry
recovers by the same key, resumes local finalization for a known result, re-executes only
after proven absence, and reports an unknown outcome when recovery is ambiguous. A peer
without key-based idempotency and recovery cannot be configured. One-time nonce actions
with external effects are rejected.

### Cryptographic trust boundary

Package-owned HMAC is limited to a single trust domain where the same service signs and
verifies. Ed25519 separates a private signer from public-key verifiers. External or
provider authenticity decisions enter through trusted local verifier callbacks. Action
input cannot supply pre-verified keys, timestamps, algorithms, or verification state,
and this package does not implement provider signature schemes.

### Failure and safe cleanup

Nonce admission fails closed on authoritative store failure or uncertainty. Idempotency
may execute untracked only when the adapter proves no admission statement was dispatched,
and it emits value-free telemetry. Claims are removed only after their strategy-safe
horizon. Idempotency reuse after retention is a new execution. Nonce cleanup requires
database time strictly beyond the accepted replay window plus a positive safety margin;
old tokens are validated before insertion so cleanup cannot reopen replay.

### Maintenance: bounded retention requires forward partition creation

The bounded-retention guarantee above ("idempotency reuse after retention is a new execution")
is only true if a stale stored response is actually removed. The `ash_onetime_response_payloads`
table is range-partitioned by month, and cleanup drops only past, empty named partitions — the
`_default` partition is excluded from drop enumeration. The install migration generates a fixed
window of monthly partitions (install month through +12). Once retention exceeds that window,
new payloads route to `_default` and are never dropped, silently defeating the guarantee.

Forward monthly partition creation (`Store.roll_partitions/2`, `mix ash_onetime.roll_partitions`,
`AshOnetime.Oban.PartitionWorker`) is therefore the **retention maintenance path** that keeps
ADR-0001's bounded-retention contract true past the install window. It is operator-scheduled
(not auto-wired), because it performs DDL on the authoritative store and belongs to the same
operator-owned cadence as cleanup and reap. The `mix ash_onetime.gen.roll_forward` migration
reaches existing installs: it adds the `response_partition` index (SEC-6), back-fills the
elapsed+forward partitions, and drains past-retention payloads stranded in `_default` via a
claim-scoped delete (the delete guard removes the payload). Without scheduling the roll, an
operator's retention boundary degrades silently — this is a documented operational
requirement, not a library-managed one.

## Consequences

- Strategy-specific types, tables, options, and tests remain separate even where their
  unique-key machinery is similar.
- The compiler rejects missing strategy or scope, a tenant-less scope on an attribute-multitenant
  resource (whose tenants share one set of claim tables), unsafe transaction shapes, untrusted
  nonce facts, and unsupported external effects.
- Tests must use real committed PostgreSQL connections for contention and must cover
  failure direction, exact window edges, cross-operation isolation, and cleanup races.
- Optional integrations may improve operations but cannot become correctness dependencies.
