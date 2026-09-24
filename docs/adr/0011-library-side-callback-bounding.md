# 11. Library-side bounding of the external-effect callbacks

Date: 2026-09-24

## Status

Rejected (the wall-clock bound). The DB-resource bound and the configurable immediate
recovery are recorded as candidates with named decision criteria — not scheduled.

## Context

Both effect callbacks (`execute/3`, `recover/3`) run inside the caller's open PostgreSQL
transaction and the package applies no timeout to them (observed per callback, including
the caller's backend `idle in transaction` on `pg_stat_activity`). The external-effects
guide makes bounding the peer call an adapter-side MUST. Whether the library should bound
the callbacks itself was examined.

## Decision

**A wall-clock bound is rejected.** The mechanism the package already has for other
external callbacks (`timed_callback/4`) runs the callback in a `Task` — a different
process, outside the caller's transaction — which would silently break every
same-transaction adapter write, including the transactional-outbox composition the recipes
publish (an outbox row that must commit with the action). Killing the caller process on
timeout is the only in-process alternative and is hostile: it destroys the caller's action
mid-flight. No further mechanism exists: Elixir cannot preempt a synchronous in-process
call. The wall-clock obligation stays adapter-side, where the adapter controls its own
HTTP client.

**Recorded candidates (decided, with criteria — not parked indefinitely):**

1. *DB-resource bound* — arm `SET LOCAL idle_in_transaction_session_timeout` on the
   caller's connection before the callbacks (the harm is library-created: the package
   mandates the transaction, checks out the connection, and invokes network IO inside it).
   Decision criterion: a live probe showing the GUC does not fire while the backend is
   `wait_event_type = 'Lock'` during Recipe 4's contended outbox insert — that
   non-interference is the whole safety argument and must be observed, not read. The
   candidate is designed against the shipped ADR-0010 lock (under it, an idle callback
   also blocks same-key retries, which raises the bound's value and changes its default).
   `statement_timeout` is rejected outright: it would override the adapter's own
   contracted per-query timeouts underneath it.
2. *Configurable immediate post-ambiguous `recover/3`* — the package currently calls
   `recover/3` immediately after an ambiguous `execute/3` in the same request and
   transaction, doubling the worst-case hold. Making that configurable trades hold time
   for settlement rate (more claims stranded in `processing`); it requires its own
   reasoning and is not a bundled knob. Criterion: demonstrated operator demand for
   bounded in-transaction time on external actions that the adapter-side timeout does not
   satisfy.

## Consequences

- The adapter-side MUST (bound your own peer call) remains the only wall-clock bound; the
  guide's execution-environment section documents the doubling caveat.
- Both candidates above state their decision criteria in this record; opening either is a
  new decision against its criterion, not a resumption of this one.
