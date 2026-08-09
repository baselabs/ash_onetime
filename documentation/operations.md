# Operations

Generate the PostgreSQL installation through Igniter or the deterministic Mix task:

```sh
mix igniter.install ash_onetime --repo MyApp.Repo
mix ash_onetime.gen.migrations --repo MyApp.Repo
mix ecto.migrate
```

The migration creates authoritative idempotency claims, nonce claims, response payload
partitions, collision constraints, cleanup functions, and deletion guards. Claim parents may
be unpartitioned or hash-partitioned by `operation_hash`; response payloads use date
partitions plus a default partition. All identifiers are quoted and every operation keeps the
operation hash in its logical key.

Run bounded cleanup manually or with the optional Oban worker:

```sh
mix ash_onetime.prune --repo MyApp.Repo --batch-size 500
```

Cleanup deletes only claims strictly past their replay/retention horizon, keeps processing
external recovery points, removes response bytes atomically with completed claims, and drops
only empty expired payload partitions after obtaining the required lock. Batch size and
prefix are explicit. Schedule `AshOnetime.Oban.CleanupWorker` only if Oban is installed.

Abandoned external `processing` claims — committed recovery points whose peer effect never
settles and that no retry ever recovers — are immortal under cleanup (it skips them) and the
delete guard (it forbids deleting them). Left unbounded this is a storage denial of service.
`AshOnetime.Store.reap(target, batch_size, abandonment_seconds)` is an opt-in, bounded reaper that
deletes such claims past a separate, much longer abandonment horizon. A claim is reaped only when
it is older than both `abandonment_seconds` and a hard 1-day floor and past its own retention
horizon (all re-enforced by the delete guard), so an in-flight or in-retention recovery point is
never removed. `abandonment_seconds` must be at least the 1-day floor. Schedule it far less
frequently than cleanup (recoverability becomes bounded by `max(retention, abandonment)`), and
size the horizon well beyond any legitimate in-flight window.

Run the reaper manually or with the optional Oban worker, mirroring cleanup:

```sh
mix ash_onetime.reap --repo MyApp.Repo --abandonment-seconds 1209600
```

`--abandonment-seconds` defaults to 604800 (7 days) and must be at least the 86400-second (1 day)
floor; `--batch-size` defaults to 500. Schedule `AshOnetime.Oban.ReapWorker` only if Oban is
installed, on its own far slower cadence than `AshOnetime.Oban.CleanupWorker`. Before reaping,
observe the backlog with `AshOnetime.Store.processing_backlog(target)`, which returns
`{:ok, %{processing_count: n, oldest_age_seconds: seconds}}` (`oldest_age_seconds` is `nil` when
no recovery points are in flight) — watch it grow to detect abandonment accumulation and to size
the abandonment horizon above the oldest legitimate in-flight claim. Existing deployments installed before
the reaper existed must, in a manual migration, `CREATE OR REPLACE` the
`ash_onetime_guard_idempotency_delete` function with the new body (the attached trigger keeps
pointing at the same name), `CREATE` the `ash_onetime_reap_idempotency` function, and `CREATE` the
`ash_onetime_idempotency_claims_processing_index`. Copy those three definitions from a freshly
generated install migration (`mix ash_onetime.gen.migrations`), changing the guard's `CREATE
FUNCTION` to `CREATE OR REPLACE FUNCTION`. Until they are applied a reap attempt fails closed
against the old guard.

### Forward response partitions

The `ash_onetime_response_payloads` table is range-partitioned by month. The install migration
generates a fixed window (install month through +12). Cleanup drops only past, empty named
partitions; the `_default` partition is excluded from drop enumeration. Once retention exceeds
the generated window, payloads route to `_default` and are never dropped — silently defeating
bounded retention. Forward monthly partition creation keeps the window ahead of retention:

```sh
mix ash_onetime.roll_partitions --repo MyApp.Repo --months 6
```

`--months` (default 3, 1..24) sets how many forward months to ensure exist. The roll is
idempotent and concurrency-safe (advisory-locked, bounded `lock_timeout`), so concurrent or
overlapping runs are safe. Schedule `AshOnetime.Oban.PartitionWorker` (or a cron cadence) ahead
of your retention horizon — missing it causes new writes to route to `_default`, so the roll is
more time-sensitive than cleanup/reap. Existing installs that predate the roll or have crossed
the window should generate and run the forward migration once:

```sh
mix ash_onetime.gen.roll_forward --repo MyApp.Repo --months 18
mix ecto.migrate
```

It adds the `response_partition` index, back-fills the elapsed+forward partitions, and drains
past-retention payloads stranded in `_default` (a claim-scoped delete; the delete guard removes
the payload). Within-retention stranded payloads are left — a retry under a new key is a new
execution, and the rolled-forward partitions now route future inserts correctly.

**Gap recovery:** `roll_partitions` only creates partitions ahead of the current month — it does
not back-fill. If the worker/cron is down for a month or longer, that month's within-retention
payloads strand in `_default` (which cleanup never drops). Re-running
`mix ash_onetime.gen.roll_forward` is the recovery procedure: its drain is idempotent and removes
any past-retention payloads that aged out while the roll was down. An exhausted `PartitionWorker`
(`max_attempts: 3` discards persistent failures) leaves the same gap — monitor for discarded
jobs and re-run the forward migration when the worker has been down across a month boundary.

**Worker backoff and discard alert.** Each Oban worker (`CleanupWorker`, `PartitionWorker`,
`ReapWorker`) declares a bounded, jittered `backoff/1` (30–120 s across the three attempts) rather
than Oban's default exponential, so a transient failure — lock contention on the unique index, a
slow query, a momentary checkout pressure — retries within minutes instead of pushing the next
attempt to hours. A job that exhausts its 3 attempts is discarded; for the retention-critical
`PartitionWorker` a discard strands a month of bounded retention. **Alert on discarded jobs:**

```sql
SELECT queue, attempt, max_attempts, inserted_at, discarded_at
FROM oban_jobs
WHERE state = 'discarded' AND queue IN ('ash_onetime_cleanup', 'ash_onetime_reap')
  AND discarded_at > now() - interval '24 hours';
```

A discarded `PartitionWorker` is the signal to run `mix ash_onetime.gen.roll_forward` (its drain is
idempotent). A rising discard rate on any of the three queues is contention — inspect
`pg_stat_activity` for lock waits during the worker's window and consider raising the pool or
scheduling the worker off-peak.

A context-multitenant tenant prefix must be 1..63 bytes — PostgreSQL truncates identifiers at
63 bytes (NAMEDATALEN), so a longer prefix could route two tenants to the same schema. Both
admission and cleanup reject an out-of-range prefix (admission fails closed with
`:missing_prefix`) rather than truncating.

Configure an optional completed-response cache with `config :ash_onetime, :cache, MyCache`
and a bounded `:cache_timeout`. Implement `AshOnetime.Cache`; treat every value as untrusted.
The default `AshOnetime.Cache.None` needs no application configuration or supervision tree.

`AshOnetime.Plug` can copy configured headers into `conn.private.ash_onetime.untrusted`; it
does not verify them. Trusted verification remains inside the protected action.

Telemetry events are `[:ash_onetime, event]`, where event is `:admission`, `:conflict`,
`:replay`, `:fingerprint_mismatch`, `:verification`, `:encoding`, `:cache`, `:cleanup`, `:reap`,
`:external_recovery`, `:store_uncertainty`, or `:untracked_execution`. The `:reap` event carries a
`:claims_reaped` count for each bounded reaper run. Metadata is exactly
`strategy`, `resource`, `action`, and `result_class`; measurements are only `duration` or
`count`. Raw keys, scopes, tokens, fingerprints, payloads, signatures, resolver identities,
exceptions, and store results are never telemetry fields.

### DPoP replay fence operational characteristics

A `:one_time_nonce` protection with `commit: :independent` (the DPoP §11.1 replay fence,
ADR-0003) routes its claim through the
`claim_committed` worker, which spawns a process that opens its own transaction on its own
connection. Two operational characteristics apply, inherited from the external-effect path but
now exercised per-request rather than per-external-effect:

- **Connection-pool pressure.** The worker needs a checkout from the same pool while the
  caller's `before_action` still holds one — effectively +1 connection per in-flight protected
  request. Under `pool_size N` concurrent protected actions, the `(N+1)`th blocks waiting for a
  checkout; under sustained burst this surfaces as latency and, at the limit, a
  `:checkout_unavailable` rejection (which fails closed — the request is rejected, never
  admitted unsafely). Size the pool for the expected concurrency of DPoP-protected endpoints.
- **30s worker timeout.** If the worker stalls (slow query, lock contention on the unique index,
  pool pressure), `before_action` blocks for up to 30s before the worker times out and returns
  a `:worker_timeout` result, which surfaces as a `[:ash_onetime, :store_uncertainty]` telemetry
  event with `result_class: :worker_timeout` and a typed store error. This is distinct from a
  genuine disconnect (`result_class: :disconnected`) and from other unknown dispatches
  (`result_class: :unknown`): all three fail closed and none can cause a silent re-admit, but the
  `:worker_timeout` class names the stall condition an operator should triage as pool/lock/contention
  (raise the pool, inspect the slow query) rather than a network partition (the `:disconnected`
  triage). A rising `:worker_timeout` rate is the signal to size the pool for DPoP-protected
  concurrency.

The fence's fail-closed posture means neither characteristic can reopen the replay gap the fence
exists to close — the worst case is rejection under stress, never a double-spend.

## Runbooks

Named procedures for the operational failure modes the library surfaces. Each names the
symptom, the diagnostic query, and the remediation. Every procedure is safe to run against
a live authoritative store unless noted.

### backlog-stuck — abandoned `processing` recovery points accumulating

**Symptom.** `[:ash_onetime, :external_recovery]` with `result_class: :outcome_unknown`
sustained over time, or `processing_backlog/1` showing a growing `processing_count` whose
`oldest_age_seconds` exceeds any legitimate in-flight window. Abandoned external-effect
recovery points are immortal under cleanup (it skips `processing` claims) and the delete
guard forbids deleting them; left unbounded this is a storage-exhaustion denial of service
(ADR-0002).

**Diagnose.** Observe the backlog before reaping:

```elixir
{:ok, %{processing_count: n, oldest_age_seconds: age}} =
  AshOnetime.Store.processing_backlog(target)
```

Or directly in SQL (replace `:prefix`):

```sql
SELECT count(*) AS processing_count,
       extract(epoch from now() - min(inserted_at))::int AS oldest_age_seconds
FROM "ash_onetime_idempotency_claims"
WHERE state = 'processing';
```

**Remediate.** If `oldest_age_seconds` is well beyond any legitimate in-flight window (e.g.
days), run the bounded reaper with an `abandonment_seconds` sized above your longest
legitimate in-flight claim but below the point where storage pressure bites:

```sh
mix ash_onetime.reap --repo MyApp.Repo --abandonment-seconds 1209600 --batch-size 500
```

`--abandonment-seconds` (default 604800 = 7 days, minimum 86400 = 1 day) must be at least the
1-day floor; the reaper re-enforces both this floor and each claim's own retention horizon via
the delete guard, so an in-flight or in-retention recovery point is never removed. Reaping an
abandoned claim means a later retry re-inserts under a new claim id and executes as a new
peer operation (ADR-0002). Schedule `AshOnetime.Oban.ReapWorker` on a slow cadence to keep
this bounded steady-state rather than a manual fire drill.

### partition-discard-detected — a PartitionWorker exhausted its retries

**Symptom.** A discarded `PartitionWorker` job on the `ash_onetime_cleanup` queue. This
strands a month of bounded retention: new payloads route to `_default` and are never dropped
(ADR-0001). The bounded jittered backoff (ADR-0005) retries transient failures within minutes,
so a discard means a persistent failure (a malformed argument, an unresolvable repo, a DDL
error) — not a transient stall.

**Diagnose.** Alert on discarded jobs:

```sql
SELECT queue, attempt, max_attempts, inserted_at, discarded_at, args
FROM oban_jobs
WHERE state = 'discarded' AND queue = 'ash_onetime_cleanup'
  AND discarded_at > now() - interval '24 hours'
ORDER BY discarded_at DESC;
```

Check whether the current month's partition exists:

```sql
SELECT count(*)
FROM pg_inherits
JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
JOIN pg_namespace n ON n.oid = parent.relnamespace
WHERE n.nspname = ':prefix'
  AND parent.relname = 'ash_onetime_response_payloads'
  AND pg_inherits.inhrelid::regclass::text LIKE '%_default';
-- a non-zero count here means payloads are routing to _default (the catch-all),
-- i.e. the forward window has lapsed.
```

**Remediate.** A discarded `PartitionWorker` triggers the idempotent forward migration, which
both creates the elapsed+forward partitions AND drains past-retention payloads stranded in
`_default`:

```sh
mix ash_onetime.gen.roll_forward --repo MyApp.Repo --months 18
mix ecto.migrate
```

Then re-schedule the `PartitionWorker` (or cron) ahead of the retention horizon so the window
does not lapse again. A rising discard rate on the partition or cleanup queues is contention
— see pool-saturated.

### pool-saturated — worker timeouts or checkout failures rising

**Symptom.** `[:ash_onetime, :store_uncertainty]` with `result_class: :worker_timeout`
climbing, or `:checkout_unavailable` (`[:ash_onetime, :untracked_execution]` may follow for
opted-in idempotency). The committed-claim worker needs a +1 connection checkout per
in-flight protected request (ADR-0003); under `pool_size N` concurrent protected actions the
`(N+1)`th blocks, and at the limit the 30s worker timeout fires. All paths fail closed — the
worst case is rejection under stress, never a double-spend — but a rising rate degrades the
DPoP-protected endpoint.

**Diagnose.** Confirm the timeout class is the dominant uncertainty signal (distinct from
`:disconnected`, which is a network partition, and `:unknown`, which is an unspecified
dispatch):

```sql
-- in your telemetry backend, filter the store_uncertainty stream:
-- result_class = 'worker_timeout' (rising) vs 'disconnected' vs 'unknown'
```

Inspect live lock waits and checkout pressure during the worker's window:

```sql
SELECT activity.state, activity.wait_event_type, activity.wait_event,
       count(*)
FROM pg_stat_activity activity
WHERE activity.state != 'idle'
GROUP BY 1, 2, 3
ORDER BY count(*) DESC;
```

```elixir
# DBConnection checkout queue length (EctoMyApp.Repo substituted):
{:ok, %{checkin_queue: q, total_connections: t}} =
  MyXQL or Postgrex connection info # via DBConnection's :telemetry on [:db_connection, :checkout, *]
```

**Remediate.** Raise the pool size to accommodate the `(N+1)` checkout pattern for the
expected concurrency of DPoP-protected endpoints:

```elixir
config :my_app, MyApp.Repo, pool_size: 20  # was 10, for example
```

If the timeout class is `:disconnected` instead, triage as a network partition (check
`pg_stat_activity` for connection churn, the load balancer, the Postgres instance health) —
not a pool-sizing issue. If it is `:unknown`, inspect the worker's exit reason in the Oban
job or application logs; that class names an unspecified dispatch failure a pool raise will
not fix.

## Key rotation

Token verification resolves material by the signed key identifier. Add a new key before
using it to sign. Retain every old verification key until the last token it signed is outside
`max_age + clock_skew`, then remove it. An unknown key identifier fails verification; never
fall back silently to a different key.

The supported runtime is Elixir `~> 1.20` (verified on 1.20.2) and Erlang/OTP 29 with
Ash `>= 3.31.1`, AshPostgres 2, and PostgreSQL 18. Release checks include the full suite, mutation
matrix, warnings-as-errors documentation, exact Hex archive inspection, and an unpacked
zero-configuration consumer, all run on the runtime pinned in `.tool-versions`; see
[CONTRIBUTING](../CONTRIBUTING.md).
