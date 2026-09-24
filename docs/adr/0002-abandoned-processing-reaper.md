# 2. Abandoned `processing` claim reaper

Date: 2026-08-05

## Status

Accepted. Extends [1. Single-use keyed effects](0001-single-use-keyed-effects.md); does not
supersede it.

## Context

Committed-external idempotency admission commits a `processing` claim before the peer effect
runs; the claim advances to `complete` only when the effect settles. ADR 0001 made `processing`
claims inviolable recovery points: cleanup removes only `complete` claims past their retention
horizon, and the delete guard raises on any attempt to delete a `processing` row.

If a `processing` claim never settles — the peer is permanently gone, the adapter is
decommissioned, or the caller abandons after commit — and no future request with the same logical
key ever recovers it, the row is immortal: cleanup skips it and the guard forbids deleting it.
Because a logical key may carry a client-supplied argument, a caller driving an external-effect
action with distinct keys, each abandoned after commit, accumulates unbounded, undeletable
`processing` rows — a storage-exhaustion denial of service specific to external-effect actions.
Nonce claims have no `processing` state and are unaffected.

## Decision

Add an opt-in, bounded reaper that deletes abandoned `processing` idempotency claims past a
**separate, much longer abandonment horizon**, through a **sanctioned delete path**:

- A `processing` claim is deletable only inside a sanctioned reap, and only when it is older than
  **both** the operator's abandonment horizon **and** a hard safety floor (1 day), **and** past
  its own retention horizon. All three conditions are re-enforced by the delete guard, not merely
  by the reaper query, so no caller — however it arms the reap session variable — can delete a
  recently-admitted or still-in-retention recovery point.
- The reaper (`ash_onetime_reap_idempotency(batch_size, abandonment_seconds)`, surfaced as
  `AshOnetime.Store.reap/3`) computes the cutoff on the PostgreSQL clock
  (`transaction_timestamp()`), arms a transaction-local session variable (`ash_onetime.reap_before`)
  that the guard reads, and deletes a bounded batch under `FOR UPDATE SKIP LOCKED`. It rejects an
  abandonment horizon below the floor and an out-of-range batch size.

Recoverability is therefore no longer unbounded: it becomes bounded by
`max(retention horizon, abandonment horizon)`. Reaping an abandoned claim means a later retry of
the same logical key re-inserts under a new claim id and executes as a **new execution with a new
peer operation key** — consistent with 0001's "reuse after retention is a new execution," now
extended to the abandoned-processing case.

## Consequences

- The delete guard for `processing` claims changes from "never" to "only under a sanctioned reap
  past both horizons"; the recovery-point invariant for in-flight and in-retention claims is
  unchanged and still enforced by the guard.
- The reaper bounds **steady-state** growth, not a burst: an attacker's accumulation is at most
  `admission rate × max(retention, abandonment)`, and while the reaper is unscheduled its
  mitigation is zero. Operators control the residual with application-edge rate limiting, reap
  cadence, and abandonment tuning. An admission-time cap is out of scope (it would contradict the
  "PostgreSQL admits, nothing else gates" posture).
- A partial index on `(inserted_at) WHERE state = 'processing'` supports the reaper's candidate
  scan under attacker volume.
- The change lives in the install migration template. Existing deployments fail closed until the
  guard-replacement and reaper-function SQL is applied manually (documented in the operations
  guide); a generalized upgrade-migration mechanism is out of scope.
- The reaper is opt-in and idempotency-only (nonce has no `processing` state).

## Amendment (2026-09-24): reaping an outcome-unknown claim removes the last key-based tie

The decision section above calls a post-reap retry "consistent with 0001's 'reuse after
retention is a new execution.'" The two cases differ in the decisive respect, and the
distinction is load-bearing for external effects: after **retention**, cleanup deletes only
`complete` claims — the prior execution is known complete, and a new execution is safe. After
**reap**, the deleted `processing` claim's outcome is unknown by definition (that is why it
was abandoned), and the operation key — the claim row's UUID, freshly generated per insert —
is deleted with it. A retry therefore executes at the peer under a brand-new operation key:
the peer's contractually required key dedup cannot recognize it as the same operation, and
the package has no record left either. No key-based defense remains at either layer.

This is not a defect in the reaper's mechanics (the recovery-point invariant for in-flight
and in-retention claims is unchanged); it is the honest boundary of reaping external-effect
claims. The normative statement lives in `documentation/external-effects.md`: enable the
reaper on an external-effect action only together with a business-level reconciliation path
that can settle an outcome-unknown claim before its abandonment horizon passes. A
reap-surviving derived operation key (stable across reap via the logical key plus an epoch,
or a reap tombstone) was considered and deliberately not taken: it changes the published
post-retention semantics for external effects and needs its own ADR if ever adopted.
