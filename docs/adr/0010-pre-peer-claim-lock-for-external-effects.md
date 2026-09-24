# 10. Pre-peer claim lock for external effects

Date: 2026-09-24

## Status

Accepted.

## Context

The package held no lock between the independently committed claim and finalize. A same-key
retry arriving inside that window truthfully recovered `:absent` (the peer had not
committed the effect) and executed under the same operation key — observed overlapping with
the original's in-flight execute (ADR-0001's 2026-09-24 amendments record the race). The
local effect stayed single (the finalize row lock), but the peer effect was protected only
by the peer's own key dedup, which the published contract did not require to be atomic —
a check-then-act peer conforms to the contract as published at v1.3.2 and double-spends in
exactly that window.

## Decision

Take the claim row `FOR UPDATE` in the caller's open transaction before any peer call, with
a bounded wait:

- `Store.lock_for_effect/3` — in the caller's transaction: `SET LOCAL lock_timeout` then a
  full-row `SELECT … FOR UPDATE` binding the claim id alongside the logical key. The id
  bind makes a reaped-and-reinserted row `:missing` (fail closed, `:store_invariant`)
  rather than adopting another generation's claim. The full-row result routes through the
  finalize-mode resolver: `:processing` proceeds under the lock, `:complete` replays — a
  claim that settled while this caller was blocked is never re-executed against the peer.
- The same-key retry's committed-claim worker arms the same bounded `lock_timeout` inside
  its own transaction, scoped to the external path only (the nonce replay fence passes no
  option and is unchanged). The retry's real wait under a held lock is in its *worker*
  (`select_claim … FOR UPDATE` on a second connection), so the caller-side timeout alone
  would not bind it.
- A lock timeout on either path maps to `:request_in_progress` — the local path's existing
  semantic for a concurrent same-key request — and is terminal: the timeout aborts the
  caller's transaction, so no further query is issued.
- Per-protection `external_lock_timeout_ms` (default 2000, validated `1..25_000` at
  compile time and at the store — 5 s of headroom under the committed-claim worker's 30 s
  kill, so a contended wait fails with `:lock_timeout` (`:request_in_progress`), not the
  parent's `:worker_timeout`). 2000 ms is comfortably longer than a local finalize, far
  shorter than a peer call.
- The `lock_timeout` GUC is scoped to the lock itself: the caller path captures the
  session's value (`SHOW lock_timeout`), arms `SET LOCAL`, takes the lock, and restores
  the value afterward — leaving it armed would cap the adapter's own contended writes and
  the finalize writes at the lock wait, exactly the class of library-imposed bound
  ADR-0011 rejects (on `:lock_timeout` the transaction has aborted; there is nothing to
  restore into). The worker path needs no restore: its transaction commits immediately.
- Same-key callers serialize at the *worker* first (its conflict-path `FOR UPDATE` runs
  before the caller-side lock), so the caller-side lock timeout is defense for
  interleavings a deterministic end-to-end test cannot arrange (a holder locking between
  the retry's worker commit and its caller-side lock). Its store-level behavior is tested
  (foreign-holder timeout) and its `:lock_timeout` mapping is the same code the worker
  path exercises end-to-end.

Behavior change (the release is a minor, not a patch): a concurrent same-key external retry
that previously waited out the original and replayed may now return `:request_in_progress`
within the configured wait. The caller retries — which is the correct client posture for
429/409-class responses on idempotent actions.

Residuals the lock does NOT close, stated plainly:

- A *sequential* retry after the original's transaction ended, with a lying `:absent`,
  still re-executes under the same key. Peer idempotency by operation key remains a MUST;
  atomic key claims drop to SHOULD (correct under every interleaving, but no longer the
  only defense).
- The one-key-per-transaction constraint: no path may run two protected actions on the
  same key inside one transaction — the second action's claim worker would block on the
  first's lock across two connections, a stall PostgreSQL cannot detect as a deadlock and
  only the worker timeout breaks.

Evidence: observed on live PostgreSQL in `test/ash_onetime/external_contention_test.exs`
(refused retries with the block observed via `pg_blocking_pids`; unchanged dead-caller
recovery) and `test/ash_onetime/store/contention_test.exs` (lock timeout against a foreign
holder; id-bind generation refusal). The mutation battery pins the lock twice:
`effect-lock-generation` defeats the id comparison while keeping the bind (reds on
generation adoption, not on a bind-arity error) and `pre-peer-lock-removed` removes the
lock call itself (reds on the unlocked race — B's red-proof, re-demonstrating the
observation preserved at `bf37ff5` on demand).

Rejected alternatives: *unbounded blocking lock* — holds the row across a callback the
package does not bound, converting every same-key retry into a 30 s worker timeout under a
slow peer. *No lock, normative atomicity only* — circular against a contract that had never
shipped at the time of the decision, and leaves the installed base's check-then-act peers
exposed. *Advisory locks* — weaker than the row lock the finalize path already takes, and
unrelated to claim-row state.

## Consequences

- `AshOnetime.Store` gains `lock_for_effect/3`; `claim_committed/3` takes options (the
  2-arity facade is unchanged for existing callers).
- The external-effects guide's concurrency section, the adapter recipe guidance, and the
  error/FAQ surfaces document `:request_in_progress` on the external path.
- Telemetry reuses the existing `conflict/processing` class — no new telemetry contract.
