# 5. Oban worker backoff and discard alert (operational retention-safety)

Date: 2026-08-09

## Status

Accepted. Extends [1. Single-use keyed effects](0001-single-use-keyed-effects.md) (the bounded-
retention guarantee that forward partition creation keeps true) and [2. Abandoned `processing`
claim reaper](0002-abandoned-processing-reaper.md) (the reap worker's operational cadence); does
not supersede either.

## Context

The three optional Oban workers — `CleanupWorker`, `PartitionWorker`, `ReapWorker` — perform DDL
and bounded deletes on the authoritative PostgreSQL store. Each declared `max_attempts: 3` with
Oban's default exponential `backoff/1`, and none defined a custom backoff.

The default exponential pushes attempt 3 to hours after attempt 1. For a maintenance job on a
retention-critical surface this is the wrong shape:

- `PartitionWorker` is the retention-safety path (ADR-0001). A discarded roll strands a month of
  bounded retention: new payloads route to `_default` and are never dropped. Lengthening the retry
  window lengthens the window a transient failure (lock contention on the unique index, a slow
  query, momentary checkout pressure) can exhaust the 3 attempts and discard.
- `CleanupWorker` and `ReapWorker` bound steady-state growth (ADR-0001, ADR-0002). A delayed
  retry lengthens the cleanup/reap cadence unnecessarily for failures that are transient.

There was also no documented discard alert. An operator whose `PartitionWorker` exhausted its
attempts had no surfaced signal — the gap would surface only when retention silently degraded
past the install window, the exact failure ADR-0001's maintenance section warns about.

## Decision

### Bounded, jittered `backoff/1` on each worker

Each worker defines `c:backoff/1` returning a bounded linear-plus-jitter delay:

    base * attempt + rand.uniform(base) - 1, capped at max
    # base = 30 s, max = 120 s
    # attempt 1 -> [30, 60) s, attempt 2 -> [60, 90) s, attempt 3 -> [90, 120) s

Rationale:

- **Bounded, not exponential.** These are maintenance jobs, not request-path jobs. A transient
  failure should retry within minutes, well inside the monthly retention window. The default
  exponential (attempt 3 at hours) is tuned for request-path retry semantics, not retention safety.
- **Jittered.** Simultaneous failures (a contention event hitting a scheduled batch) do not retry
  in lockstep and re-contend.
- **Three attempts unchanged.** `max_attempts: 3` stays — persistent failures (a misconfigured
  repo, an out-of-range argument) discard fast rather than retrying a known-bad input. The
  `{:discard, :invalid_arguments}` arm is unchanged; the backoff only governs the retryable
  `{:error, :*_failed}` arms.

The three workers share the identical formula (they protect the same class of operation on the
same store). A shared helper was considered and rejected: the workers are independently scoped
under `if Code.ensure_loaded?(Oban.Worker)`, and a shared module would couple three separately-
optional entry points to a fourth module for three lines of arithmetic.

### Documented discard alert

`documentation/operations.md` carries the exact SQL query an operator runs to detect discarded
jobs on the `ash_onetime_cleanup` and `ash_onetime_reap` queues, plus the triage: a discarded
`PartitionWorker` triggers `mix ash_onetime.gen.roll_forward` (idempotent drain); a rising discard
rate is contention, triaged via `pg_stat_activity` and pool sizing.

## Consequences

- A transient failure retries within minutes, so a single contention event is far less likely to
  exhaust the 3 attempts and discard a retention-critical roll.
- The discard-alert SQL is the operational contract: an operator monitoring `oban_jobs` for
  discarded rows on the two queues has the signal ADR-0001's maintenance section requires.
- The backoff is bounded at 120 s; a job that is genuinely stuck (not transiently contended) still
  discards after 3 attempts at ~5 minutes total, preserving the fast-discard property for
  persistent failures.
- The choice is per-worker and source-local; no Oban configuration or plugin dependency is added.
  A consumer running these workers under their own Oban instance inherits the backoff via the
  worker module; a consumer using a different scheduler applies the same shape at their boundary.

## Alternatives considered

- **Keep the default exponential backoff.** Rejected — it is tuned for request-path retry, not
  retention safety, and lengthens the window a transient failure can become a discard.
- **Raise `max_attempts`.** Rejected — it lengthens the total window and masks persistent failures
  (a misconfigured repo retrying 10 times is worse, not better). The bounded backoff fixes the
  retry-timing problem without changing the attempt count.
- **A shared backoff helper module.** Rejected — three lines of arithmetic duplicated across three
  independently-optional workers is cheaper than a fourth coupling point, and the formula is pinned
  by each worker's test.
