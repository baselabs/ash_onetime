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

Oban 2.23.1's default is a short exponential: `15 + 2^attempt` seconds with 0–10%
incremental jitter (`Oban.Worker.backoff/1` → `Oban.Backoff.exponential/2` + `jitter/2`),
which at `max_attempts: 3` spaces attempts 1→3 roughly 36–40 s apart. For DDL-class
maintenance work on a contended, retention-critical store this is the wrong shape:

- It re-collides at ~17–21 s. A failed partition roll returns quickly (rolls fail fast
  under their own 5 s `lock_timeout`), so a retry that soon can arrive while the
  contending lock holder is still holding — and a discarded roll strands a month of
  bounded retention (ADR-0001): new payloads route to `_default` and are never dropped.
- Its jitter is narrow (0–10% incremental), so simultaneous failures from one contention
  event (lock contention on the unique index, a slow query, momentary checkout pressure)
  retry nearly in lockstep and re-contend together.
- It grows as `15 + 2^n` with the attempt count (`~17 min` by attempt 10; Oban bounds it
  only by rescaling the effective attempt to at most `@clamped_max` 20 — an effective
  ceiling of `15 + 2^20` s ≈ 12 days), so any future raise of `max_attempts` would
  silently re-introduce long windows.

There was also no documented discard alert. An operator whose `PartitionWorker` exhausted its
attempts had no surfaced signal — the gap would surface only when retention silently degraded
past the install window, the exact failure ADR-0001's maintenance section warns about.

## Decision

### Bounded, jittered `backoff/1` on each worker

Each worker defines `c:backoff/1` returning a bounded linear-plus-jitter delay:

    base * attempt + rand.uniform(base) - 1, capped at max
    # base = 30 s, max = 120 s
    # attempt 1 -> [30, 60) s, attempt 2 -> [60, 90) s, attempt 3 -> [90, 120) s
    # Oban calls backoff/1 with the FAILED attempt number and discards after the last,
    # so at max_attempts: 3 only the attempt-1 and attempt-2 rows gate (the delays
    # before attempts 2 and 3); the attempt-3 row exists for a future raised ceiling.

Rationale (corrected 2026-08-19 — the original recorded the default as pushing attempt 3
to hours, which is false at Oban 2.23.1, and derived the rationale from that premise):

- **Spaced DDL-class cadence, not faster retries.** These are maintenance jobs doing DDL
  and bounded deletes on a contended store, not request-path jobs. At `max_attempts: 3`
  this backoff is deliberately *slower* in total than the default (the two gating delays,
  [30, 60) and [60, 90), put attempts 1→3 roughly 90–148 s apart vs the default's
  ~36–40 s): a failed roll returns fast under its own 5 s `lock_timeout`, and the wider
  spacing gives a still-holding contender time to finish instead of re-colliding at the
  default's ~17–21 s.
- **Wider jitter.** A uniform ~0–30 s spread per delay (vs the default's 0–10%
  incremental) decorrelates simultaneous failures (a contention event hitting a
  scheduled batch) so they do not retry in lockstep and re-contend.
- **Capped.** The 120 s ceiling bounds the delay however far `max_attempts` is ever raised
  (the default's `15 + 2^n` reaches ~17 min by attempt 10, bounded only at Oban's
  attempt-20 clamp).
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
jobs on the three worker queues (`ash_onetime_cleanup`, `ash_onetime_reap`, and — per the L4
dedicated-queue amendment below — `ash_onetime_partitions`), plus the triage: a discarded
`PartitionWorker` triggers `mix ash_onetime.gen.roll_forward` (idempotent drain); a rising discard
rate is contention, triaged via `pg_stat_activity` and pool sizing.

## Consequences

- A transient failure retries on a spaced cadence that gives contention time to clear
  between attempts instead of re-colliding with it, so a single contention event is far
  less likely to discard a retention-critical roll.
- The discard-alert SQL is the operational contract: an operator monitoring `oban_jobs` for
  discarded rows on the queues has the signal ADR-0001's maintenance section requires.
- The backoff is bounded at 120 s; a job that is genuinely stuck (not transiently contended) still
  discards after 3 attempts at roughly 90–148 s end to end (the two gating delays), preserving the
  fast-discard property for persistent failures.
- The choice is per-worker and source-local; no Oban configuration or plugin dependency is added.
  A consumer running these workers under their own Oban instance inherits the backoff via the
  worker module; a consumer using a different scheduler applies the same shape at their boundary.

## Dedicated partition-creation queue (L4, added 2026-08-10)

`PartitionWorker` runs on a dedicated `:ash_onetime_partitions` queue, separate from
`CleanupWorker`'s `:ash_onetime_cleanup` and `ReapWorker`'s `:ash_onetime_reap`. Forward
partition creation is the retention-safety path (a discarded job strands a month of bounded
retention, per ADR-0001); routine cleanup is not. A shared queue let saturation on the
cleanup path delay or starve the retention-critical roll. Consumers configuring Oban queues
must include `:ash_onetime_partitions` or `PartitionWorker` jobs sit unscheduled. The
discard-alert SQL and the partition-discard triage section in `operations.md` name the new
queue.

## Worker error tuples carry the inner reason (L5, added 2026-08-10)

The three workers' error tuples embed the store `Result.reason`: `{:error,
{:roll_partitions_failed, reason}}`, `{:error, {:reap_failed, reason}}`, `{:error,
{:cleanup_failed, reason}}` (previously opaque `{:error, :tag}`). Oban serializes the error
tuple to the job's `errors` array, so the distinguishable cause (`:lock_timeout` /
`:disconnected` / `:store_invariant` / ...) survives past exhaustion instead of collapsing
to a single opaque atom. The retry/discard semantics are unchanged (still `{:error, _}` →
retry). The store functions return bare `%Result{}` on failure (not `{:error, %Result{}}`),
so the worker else-clauses match `%Result{reason: reason}` directly.

## Alternatives considered

- **Keep the default exponential backoff.** Rejected — its ~17–21 s re-collision can arrive
  while a DDL contender still holds (rolls fail fast under their own 5 s `lock_timeout`), its
  narrow 0–10% jitter re-contends in lockstep, and its `15 + 2^n` growth re-introduces long
  windows if `max_attempts` is ever raised (bounded only at Oban's attempt-20 clamp).
- **Raise `max_attempts`.** Rejected — it lengthens the total window and masks persistent failures
  (a misconfigured repo retrying 10 times is worse, not better). The bounded backoff fixes the
  retry-timing problem without changing the attempt count.
- **A shared backoff helper module.** Rejected — three lines of arithmetic duplicated across three
  independently-optional workers is cheaper than a fourth coupling point, and the formula is pinned
  by each worker's test.
