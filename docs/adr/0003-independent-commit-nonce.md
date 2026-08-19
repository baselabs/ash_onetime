# 3. Independent-commit nonce (DPoP §11.1 replay fence)

Date: 2026-08-09

## Status

Accepted. Extends [1. Single-use keyed effects](0001-single-use-keyed-effects.md); does not
supersede it. Adds a second deliberate exception (alongside the external-recovery protocol) to
the "no independent admission transaction" clause, scoped to the nonce burn-marker.

## Context

A one-time-nonce claim commits **inside** the protected action's transaction. The `before_action`
reserve calls `Store.claim/2`, which runs a plain `INSERT ... ON CONFLICT DO NOTHING` on the
action's transaction connection — no inner commit. So any failure after `before_action` (the
action body, `after_action` hooks, a downstream token mint) rolls the whole transaction back,
including the nonce claim.

For [RFC 9449 (DPoP)](https://datatracker.ietf.org/doc/html/rfc9449) this is the opposite of the
requirement. §11.1 ("DPoP Proof Replay") permits a server to "store the `jti` value of each DPoP
proof for the time window in which the respective DPoP proof JWT would be accepted" so that a
reuse "would be declined." (Replay tracking is **optional** under §11.1; the library builds the
mechanism a server opts into.) A `jti` that rolls back when the consuming action fails is not
stored "for the time window" — it is stored for zero milliseconds on body failure. A retry after
a transient downstream failure would spend the same `jti` twice, defeating the replay fence.

The gap is proven by `test/ash_onetime/nonce_rollback_gap_test.exs` (the default-`commit` half):
a nonce action whose body fails leaves zero claims, and the same proof is re-admitted on retry.

The independent-commit mechanism the fix needs **already exists and is proven**:
`Store.claim_committed/2` spawns a worker process on its own connection, guarded against nesting
(`run_committed_claim_transaction` fails closed with `:store_invariant` if called inside an
active transaction within the same process). The external-effect idempotency path already depends
on it ([the external-recovery protocol](0001-single-use-keyed-effects.md), and
`lib/ash_onetime/external_recovery.ex`). The worker-process isolation is what makes the
independent commit real: `in_transaction?/0` reports the calling process's transaction state, and
the spawned worker is a fresh process with no transaction of its own, so its INSERT commits in
its own fresh transaction, independent of the action transaction's eventual commit/rollback.

## Decision

Add an opt-in `commit: :independent` option on `:one_time_nonce` protections (default
`:with_action`, preserving every existing nonce consumer byte-for-byte). When set, the nonce
claim routes through the existing `Store.claim_committed/2` worker, committing in its own
transaction **before** the action body runs, so the spend survives action-body failure.

A reused `(operation_hash, scope_hash, key_hash)` triple within the acceptance window is rejected
with `:nonce_already_used` via the existing `:collision` decide arm — no new error code. The burn
marker is retained for its acceptance window (`retain_until`, unchanged) and reaped by the
existing `ash_onetime_cleanup_nonce` regardless of whether the action ever completed — no new
SQL, column, or migration. The marker is unreapable inside its window (strict `>` eligibility +
the `ash_onetime_nonce_delete_guard` BEFORE DELETE trigger).

The option is rejected (compile-time `DslError`) on `:idempotency`, whose correct semantics are
commit-with-effect. Nonce's fail-closed posture is preserved: the `:execute_untracked` arm is
structurally unreachable for nonce (gated on `:idempotency`), and every `claim_committed`
failure shape falls to the catch-all `decide` and surfaces as a typed store error. (Corrected
2026-08-19: this paragraph originally enumerated three failure shapes — `:checkout_unavailable`
/ `:dispatched_unknown` / `:disconnected` — and claimed "no new telemetry event". Both the
enumeration and that claim were overtaken by later work; the live public taxonomy is recorded
in the amendment below.)

Three surgical store-layer widenings let a committed nonce collision reach `decide` (the
load-bearing mechanism): the `claim_committed/2` head guard widened to accept
`:one_time_nonce` (defense-in-depth, the explicit guard kept); the `claim_for_commit/2` allowlist
widened to accept `:collision` (nonce-only by construction — idempotency collisions resolve to
`:processing`/`:complete`); and `Result.committed/1`'s status guard widened to accept `:collision`.
Without these, a committed nonce collision would be rolled back to `:store_invariant` instead of
reaching `:nonce_already_used`.

## ADR-0001 hazard test

ADR-0001's Context names exactly two hazards the "separate strategies" decision exists to
prevent: *"Sharing defaults or failure behavior between those strategies can silently turn replay
defense into response replay or let a nonce fail open."* This option introduces neither:

1. **"Replay defense into response replay"?** No. The fence has no stored response and no replay
   path. `execution_class(:one_time_nonce, :committed_external_claim) → :nonce` routes through
   `complete/2`'s nonce short-circuit, which returns `{:ok, result}` with no persistence.
2. **"Let a nonce fail open"?** No. `:execute_untracked` is structurally unreachable for nonce.

The option changes the commit **boundary** (when the spend becomes durable), not the failure
**direction** — a new axis ADR-0001 did not contemplate, which is exactly what this ADR names.
The "no independent admission transaction for database effects" clause (scoped to idempotency) is
unchanged; the external-recovery protocol remains the first exception, and this is the second.

## Consequences

- One new DSL keyword (`commit:`); the strategy enum, claim table, migration, error codes, and
  telemetry events are all unchanged.
- The burn marker is a one-way spend: once observed, it rejects every reuse for the acceptance
  window regardless of whether the action body succeeded. Clients are RECOMMENDED (RFC 9449 §7.3)
  to generate a unique proof per retry.
- Operational characteristics inherited from the external-effect path now apply per-request: the
  `claim_committed` worker needs a +1 connection checkout per in-flight protected request (size
  the pool accordingly), and a 30s worker timeout bounds how long a fence admit blocks before
  failing closed. Both are documented in the operations guide.
- The store-layer widenings are recorded here so future maintainers see they are the §11.1 "would
  be declined" clause made executable, not accidental broadening.

## Committed-claim failure taxonomy (added 2026-08-19)

*The failure shapes of the `claim_committed` worker are public operational semantics, not
internals — they are the classes an operator triages from telemetry. At decision time three
shapes existed; the surface has since grown, and this amendment records the live taxonomy as
deliberate public semantics (D5, merging the stale-anchor correction above).*

- `[:ash_onetime, :store_uncertainty]` — the closed allowlist is `:sent`, `:unknown`,
  `:disconnected`, `:lock_timeout`, `:worker_timeout` (`lib/ash_onetime/telemetry.ex`).
  Four are emitted by the live path (`emit_uncertainty/2` in `lib/ash_onetime/admission.ex`
  maps store result reasons to classes): `:worker_timeout` is pool/lock contention (the
  30 s worker timeout in Consequences above), `:disconnected` is a network partition,
  `:lock_timeout` a lock-timeout rollback, `:unknown` an unspecified dispatch.
  `:sent` is allowlisted reserved vocabulary with no emission path today. All fail
  closed — none can cause a silent re-admit.
- `[:ash_onetime, :uncertain_exception]` — the diagnosis event, emitted when a
  committed-claim transaction raises before collapsing to a result class. Metadata is
  `%{strategy, phase, exception}` with the exception **module** atom only — value-free by
  the same rule as every other event. Routed by the default `attach/0` router with the
  rest of the surface.
- `[:ash_onetime, :untracked_execution]` — `result_class: :checkout_unavailable`, the
  idempotency-only execute-untracked opt-out (structurally unreachable for nonce, as above).

The three families are closed, documented (`documentation/telemetry.md`), and
mutation-pinned. The original decision's "no new error code" claim stands — these are
telemetry result classes, not caller-facing error codes — and every failure still falls to
the catch-all `decide` and surfaces as a typed store error; what changed is that the
uncertainty conditions now carry distinguishable public names.
