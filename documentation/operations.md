# Operations

Generate the PostgreSQL installation through Igniter or the deterministic Mix task:

```sh
mix igniter.install ash_onetime --repo MyApp.Repo
mix ash_onetime.gen.migrations --repo MyApp.Repo
mix ecto.migrate
```

Existing 1.0 installations must add the logical-partition key before using
`AshOnetime.Transaction`:

```sh
mix ash_onetime.gen.logical_partitions --repo MyApp.Repo
mix ecto.migrate
```

The generated migration backfills existing claims and payloads into the exact `global`
partition, then widens collision authority to include `logical_partition`. Its down migration
refuses while any non-global row exists; distinct tenant authorities are never merged during
rollback. Generate and apply it once per installation/prefix family before transaction-owned
callers admit non-global work.

The migration creates authoritative idempotency claims, nonce claims, response payload
partitions, collision constraints, cleanup functions, and deletion guards. Claim parents may
be unpartitioned or hash-partitioned by `operation_hash`; response payloads use date
partitions plus a default partition. All identifiers are quoted and every operation keeps the
operation hash in its logical key.

Run bounded cleanup manually or with the optional Oban worker:

```sh
mix ash_onetime.prune --repo MyApp.Repo --batch-size 500
```

Cleanup deletes only unheld claims strictly past their replay/retention horizon, keeps processing
external recovery points, removes response bytes atomically with completed claims, and drops
only empty expired payload partitions after obtaining the required lock. Batch size and
prefix are explicit. Schedule `AshOnetime.Oban.CleanupWorker` only if Oban is installed.

### Operation holds

A completed idempotency claim with `hold_reference` is retained regardless of `retain_until`.
The caller must release it in the operation's settling transaction. If it never releases, the
record and its payload are kept forever by design. Monitor:

```elixir
AshOnetime.Store.held_backlog(target)
# {:ok, %{held_count: count, oldest_age_seconds: seconds_or_nil}}
```

The age is measured from the oldest held claim's admission; no held claims means `nil`.
`mix ash_onetime.doctor --repo MyApp.Repo --live` prints the same figures and verifies the
operation-hold column, validated CHECK, partial indexes, and guard/cleanup definitions. With
row security applying to its current role (row security enabled and FORCE or a non-owner,
without superuser/BYPASSRLS), it explicitly labels them **rows visible to this role, not an
installation total**. The Store read likewise observes only visible rows. Use a maintenance
role with the appropriate policy when an installation-wide view is needed.

Cleanup and the DEFAULT drain exclude held rows; reap never selects complete rows. The
BEFORE DELETE guard stops ordinary DELETEs even by an owner or superuser with SQLSTATE `23514`.
It does not stop TRUNCATE, DROP, disabled triggers, or a superuser's
`session_replication_role = replica`. No additional guards are installed for those operations.
The payload prune retains an occupied month even when its held claim's deadline is long past.

Existing installations need the [operation-hold upgrade](upgrading.md#v1100--operation-holds-november-13-2026).
References are unique within the installation's logical partition; release clears every visible
claim sharing the reference, so use a UUID per operation. See
[Idempotency](idempotency.md#keep-an-open-operations-record) for the transaction and Ash change
APIs and the settle-before-commit race.

Abandoned external `processing` claims — committed recovery points whose peer effect never
settles and that no retry ever recovers — are immortal under cleanup (it skips them) and the
delete guard (it forbids deleting them). Left unbounded this is a storage denial of service.
`AshOnetime.Store.reap(target, batch_size, abandonment_seconds)` is an opt-in, bounded reaper that
deletes such claims past a separate, much longer abandonment horizon. A claim is reaped only when
it is older than both `abandonment_seconds` and a hard 1-day floor and past its own retention
horizon (all re-enforced by the delete guard), so an in-flight or in-retention recovery point is
never removed. `abandonment_seconds` must be at least the 1-day floor. Schedule it far less
frequently than cleanup (recoverability becomes bounded by `max(retention, abandonment)`), and
size the horizon well beyond any legitimate in-flight window. For **external-effect** actions,
reaping is a stronger decision than for local ones: a reaped claim takes its operation key
(the claim UUID) with it, so a later retry executes at the peer under a new key and no
key-based defense remains at either layer — enable the reaper there only together with a
business-level reconciliation path that can settle an outcome-unknown claim before its
abandonment horizon passes (see the external-effects guide).

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

The payload table is range-partitioned by month. Fresh migrations calculate the window
from the transaction's current month. Cleanup deletes expired claims and their payloads;
prune drops only expired, empty named partitions and never drops `_default`.

After the maintenance upgrade, the runtime role calls owner-owned functions through its
declared maintenance role. The roll creates forward months and recovers historical months
whose rows are in `_default`, with at most 24 total months created per call:

```sh
mix ash_onetime.roll_partitions --repo MyApp.Repo --months 6
```

The roll serializes by the payload parent's OID. Recovery moves every payload column without
changing claim locators, attaches the new child, copies policies and flags, and explicitly
restores `_default`'s FORCE flag. Every created child is owner-only, including column grants
and grant options. Runtime queries use the parent. A failed recovery leaves all rows,
partitions, flags, ACLs, and step records unchanged.

There is no separate `ash_onetime.gen.roll_forward` task. A subsequent roll repairs missed
months, including past months. Schedule it ahead of the retention horizon and inspect the
per-schema `ash_onetime_maintenance_status()` facts for coverage and `_default` backlog.

**Worker backoff and discard alert.** Each Oban worker (`CleanupWorker`, `PartitionWorker`,
`ReapWorker`) declares a bounded, jittered `backoff/1` (`30 × attempt + :rand.uniform(30) − 1`,
capped at 120 s) instead of Oban's default (`15 + 2^attempt` seconds with 0–10% jitter, which
spaces attempts 1→3 roughly 36–40 s apart). The custom shape suits DDL-class retries: a
transient failure — lock contention, a slow query, momentary checkout pressure — retries after
30–90 s, giving a still-holding contender time to finish (a failed roll returns fast under its
own 5 s `lock_timeout`); the wide jitter decorrelates simultaneous failures, and the cap bounds
the delay however far `max_attempts` is raised (ADR-0005). A job that exhausts its 3 attempts
is discarded. A discarded `CleanupWorker` delays retention itself (claim cleanup deletes
expired payloads); a discarded `PartitionWorker` routes new payloads to `_default`, which is
emptied at retention but never reclaimed as a table. **Alert on discarded jobs:**

```sql
SELECT queue, attempt, max_attempts, inserted_at, discarded_at
FROM oban_jobs
WHERE state = 'discarded' AND queue IN ('ash_onetime_cleanup', 'ash_onetime_reap', 'ash_onetime_partitions')
  AND discarded_at > now() - interval '24 hours';
```

A discarded `PartitionWorker` is the signal to rerun `mix ash_onetime.roll_partitions`; its
historical recovery is idempotent. A rising discard rate on any of the three queues is contention — inspect
`pg_stat_activity` for lock waits during the worker's window and consider raising the pool or
scheduling the worker off-peak.

#### Upgrade check

**Stuck `available` jobs — the unconfigured-queue hazard.** `PartitionWorker`
runs on a dedicated `:ash_onetime_partitions` queue (separate from cleanup). If you upgrade
without adding `:ash_onetime_partitions` to your Oban `queues` config, jobs are enqueued but
never executed — forward partition creation silently stalls and payloads past the install
window route to `_default` (still deleted at retention, never reclaimed as a table), with
NOTHING discarded (so the discard alert above stays green). Alert on stuck-available jobs:

```sql
SELECT queue, count(*) AS stuck, min(inserted_at) AS oldest
FROM oban_jobs
WHERE state = 'available' AND queue = 'ash_onetime_partitions'
  AND inserted_at < now() - interval '1 hour'
GROUP BY queue;
```

A nonzero `stuck` (or `oldest` older than your roll cadence) means the queue is not configured
or its concurrency is zero — add `queues: [ash_onetime_partitions: 1]` (or higher) to your Oban
config. A healthy install shows zero stuck rows.

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
  caller's action transaction still holds one — effectively +1 connection per in-flight protected
  request. Under `pool_size N` concurrent protected actions, the `(N+1)`th blocks waiting for a
  checkout; under sustained burst this surfaces as latency and, at the limit, a
  `:checkout_unavailable` rejection (which fails closed — the request is rejected, never
  admitted unsafely). Size the pool for the expected concurrency of DPoP-protected endpoints.
- **30s worker timeout.** If the worker stalls (slow query, lock contention on the unique index,
  pool pressure), admission blocks for up to 30s before the worker times out and returns
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

**Diagnose.** Observe the backlog before reaping — the `processing_backlog/1` figures
from above as SQL (replace `:prefix` with the tenant schema, e.g. `public`):

```sql
SELECT count(*) AS processing_count,
       extract(epoch from now() - min(inserted_at))::int AS oldest_age_seconds
FROM ":prefix".ash_onetime_idempotency_claims
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

**Symptom.** A discarded `PartitionWorker` job on the `ash_onetime_partitions` queue. New
payloads route to `_default` until a roll succeeds. Claim cleanup still deletes them at
retention, but that month can no longer be reclaimed as a whole table (ADR-0001). The bounded jittered backoff (ADR-0005) retries transient failures within minutes,
so a discard means a persistent failure (a malformed argument, an unresolvable repo, a DDL
error) — not a transient stall.

**Diagnose.** Alert on discarded jobs:

```sql
SELECT queue, attempt, max_attempts, inserted_at, discarded_at, args
FROM oban_jobs
WHERE state = 'discarded' AND queue = 'ash_onetime_partitions'
  AND discarded_at > now() - interval '24 hours'
ORDER BY discarded_at DESC;
```

Count payloads stranded in `_default` (replace `:prefix` as above):

```sql
SELECT count(*) AS stranded_payloads
FROM ":prefix".ash_onetime_response_payloads_default;
```

The `_default` partition is created at install and always exists — counting partitions
cannot detect a lapsed window. A non-zero row count means payloads have routed to
`_default` because the forward window lapsed. Read the trend asymmetrically: a GROWING
count means the window is still lapsed (rows only enter `_default` while it is). A
shrinking or steady count does not prove repair — cleanup also deletes past-retention
payloads from `_default`, so the count can decay while the window is still lapsed. To
confirm repair, run the idempotent `mix ash_onetime.roll_partitions --repo MyApp.Repo`
(it creates any missing forward months) and re-check that the count stops growing.

**Remediate.** A discarded `PartitionWorker` triggers the idempotent forward migration, which
both creates the elapsed+forward partitions AND drains past-retention payloads stranded in
`_default`:

```sh
mix ash_onetime.roll_partitions --repo MyApp.Repo --months 18
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
dispatch). In your telemetry backend, filter the `[:ash_onetime, :store_uncertainty]`
stream by `result_class`; to compare the classes live, tally them in IEx attached to the
running release:

```elixir
handler = fn _event, _measurements, %{result_class: result_class}, _config ->
  Agent.update(AshOnetime.UncertaintyTally, fn tally ->
    Map.update(tally, result_class, 1, &(&1 + 1))
  end)
end

{:ok, _} = Agent.start_link(fn -> %{} end, name: AshOnetime.UncertaintyTally)
:ok = :telemetry.attach("ash-onetime-uncertainty-tally", [:ash_onetime, :store_uncertainty], handler, nil)

# under load, then read the distribution and clean up:
Agent.get(AshOnetime.UncertaintyTally, & &1)
:ok = :telemetry.detach("ash-onetime-uncertainty-tally")
Agent.stop(AshOnetime.UncertaintyTally)
```

`result_class` is `:sent`, `:unknown`, `:disconnected`, `:lock_timeout`, or
`:worker_timeout` (see [Telemetry](telemetry.md)); a rising `:worker_timeout` share is
the pool-pressure signal.

Inspect live lock waits and checkout pressure during the worker's window:

```sql
SELECT activity.state, activity.wait_event_type, activity.wait_event,
       count(*)
FROM pg_stat_activity activity
WHERE activity.state != 'idle'
GROUP BY 1, 2, 3
ORDER BY count(*) DESC;
```

Watch checkout queueing on the repo's query event — `:queue_time` is measured on every
pooled checkout (zero when the checkout was instant; it is absent only when the
connection was already held, e.g. inside a transaction). Tally it with `:counters` —
atomic and process-free, so the diagnostic adds no serialization to the query path:

```elixir
counters = :counters.new(2, [:write_concurrency])

handler = fn _event, measurements, _metadata, counters ->
  if queue_time = measurements[:queue_time] do
    ms = System.convert_time_unit(queue_time, :native, :millisecond)
    :counters.add(counters, 1, 1)
    if ms > 50, do: :counters.add(counters, 2, 1)
  end
end

:ok = :telemetry.attach("checkout-queue-watch", [:my_app, :repo, :query], handler, counters)

# exercise the DPoP-protected endpoint, then read {checkouts, waits_over_50ms}:
{:counters.get(counters, 1), :counters.get(counters, 2)}

# when done, detach:
:ok = :telemetry.detach("checkout-queue-watch")
```

Attaching an anonymous handler prints a one-time `local function ... performance
penalty` warning — expected for a diagnostic session. A rising share of waits over
50 ms (tune the threshold to your latency budget) while `:worker_timeout` climbs is
pool pressure: in-flight protected actions are holding connections. Connection counts
cannot establish this — the pool opens all `pool_size` connections eagerly, and
`pg_stat_activity` counts every session on the database (other nodes, tooling,
autovacuum) — the checkout wait can.

The event prefix is your repo module's underscored path: `MyApp.Repo` publishes
`[:my_app, :repo, :query]`, `MyApp.Accounts.Repo` publishes
`[:my_app, :accounts, :repo, :query]`.

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

### restore-from-backup — a database restore has rewound admission state

**Symptom.** This runbook is preventive: read it BEFORE restoring a backup (PITR or snapshot)
of a database carrying `ash_onetime` authority. PostgreSQL's claim tables ARE the admission
truth, and a restore rewinds them: every claim committed after the restore point is gone, so
the store no longer knows those keys were spent. What that means per strategy:

- **One-time nonces:** a proof whose spend committed after the restore point becomes
  spendable again. The exposure is bounded by the proof's acceptance window
  (`max_age + clock_skew` — typically minutes): once the window closes, the restored-away
  claim could not have admitted anyway. Restores landing well past the window carry no
  nonce exposure.
- **Idempotency:** a key whose effect completed after the restore point executes FRESH on
  retry — the restored store has no claim, and the retry's fingerprint matches (it is the
  same request), so it admits rather than conflicts. The protected effect can fire twice.
  Where an `external_effect` adapter is deployed, its `recover/3` protocol observes the peer
  state on the retry; otherwise this is business-level reconciliation.
- **Cross-system disagreement:** external systems (payment providers, webhook targets)
  remember effects the restored store has forgotten. The application's own logs and the
  peers' records for the post-restore-point period are the source of truth for what actually
  happened.

**Diagnose.** Establish the restore point (PITR target or snapshot age), then enumerate what
ran after it — from application logs, the external peers' ledgers, or both. The database
cannot tell you what was lost; the rows are gone. Anything effectful that succeeded after the
restore point is in scope for reconciliation.

**Remediate.**

1. Minimize the window: restore to just before the incident rather than an older snapshot —
   every hour cut from the rewind is an hour of effects that cannot re-execute.
2. Fence the nonce window if it matters: if proofs with acceptance windows spanning the
   restore point are replayable by an adversary (not just a retrying client), block their
   redemption at the edge until the windows close. Minutes of fencing, not hours.
3. Reconcile external effects: for every post-restore-point effect, confirm against the peer
   whether it happened. Idempotency retries with an `external_effect` adapter perform this
   automatically via the recover protocol; adapters without it (or unprotected actions) need
   business reconciliation.
4. Roll the partition window forward: the restored (older) `ash_onetime_response_payloads`
   partition set may have a lapsed forward window — new payloads would route to `_default`
   and never drop. Run `mix ash_onetime.roll_partitions --repo MyApp.Repo` after the restore
   and re-check the stranded count as in partition-discard-detected.
5. No special cleanup action: `prune`/`reap` continue from the restored state under their
   usual guards; retention horizons rewound with everything else.

Restoring per-tenant schemas (`--prefix`) or logical partitions rewinds only that authority's
claims — scope the reconciliation the same way.

## Row-level security

A consumer may put FORCE row-level security on the claims and payload tables, keyed per
tenant on `logical_partition`. Under FORCE RLS any count a non-owner runs can be narrowed
to the current tenant, so a partition holding other tenants' replay payloads could read
as empty. ash_onetime's prune never trusts such a count — and never needs to:

**The prune decides as the table owner, inside a per-partition savepoint.** Only the table
owner can `DROP TABLE` anyway, so the owner uses its own exemption, scoped to a
subtransaction no other session can observe. Per past-retention partition it takes the
DROP's own `ACCESS EXCLUSIVE` lock on the parent first, then the child and the `_default`
partition without waiting, re-verifies by OID that the relation is a plain-heap
child of the schema's payload parent owned by the driver, applies an uncommitted
`ALTER TABLE … NO FORCE ROW LEVEL SECURITY`, refuses if FORCE is still on (a DDL hook
can reapply it), and probes emptiness with `EXISTS` while `row_security` is disabled.
`row_security=off` is armed before the ALTER and remains a required fail-closed defense
through the probe. The probe stops at the first live row, so an occupied partition holds
the parent lock only briefly rather than for a full scan.
PostgreSQL exempts the owner of a non-FORCEd table before it consults `row_security`
(`check_enable_rls`), so the probe is unfiltered or errors — whatever policies exist, in
any shape (restrictive direct, `TO PUBLIC`, via group membership; a missing permissive
policy; an attached partition without grants). That is a mechanism, not a list of cases.
Empty ⇒ drop; otherwise — or on any statement error — rollback-to-savepoint restores
FORCE invisibly to every other session and the partition is reported as kept.

**Maintenance privileges.** The unreleased upgrade replaces caller-owned maintenance SQL
with per-schema SECURITY DEFINER functions owned by the payload parent's owner. Runtime
schedules need membership in the declared maintenance role, with no owner login or owner
membership. The runs table and every child are owner-only; runtime DML addresses the parents.
Non-package policies must be scoped to runtime roles. Any additional policy applying to the
owner directly, through PUBLIC, or through role membership refuses cleanup and reap with
`:maintenance_blinded`. Any relation-shape difference or package-routine digest mismatch refuses before work starts
with `:untrusted_dependency`. The check compares stored node trees without deparsing and
runs after recursive SHARE UPDATE EXCLUSIVE locks on every package root. Runtime DML
continues; inheritance, partition, and trigger DDL cannot enter between the check and work.
The install revokes MAINTAIN, and each step audits effective privileges, including pg_maintain. Transient lock refusals remain
separate from permanent prune refusals in the recorded facts.

Package tables stay in the selected table schema. Routines live in the owner-owned schema
`ash_onetime_` plus the first 48 lowercase hexadecimal characters of SHA-256 of the table
schema's UTF-8 name. The install record and status record both schema names, and the Store
resolves the actual table namespace before addressing its routine schema. Installation
revokes PUBLIC CREATE, grants USAGE to the maintenance role, and each step audits effective
CREATE under the trusted-owner/server boundary described in [Security](security.md).
Publish package tables without row filters. A non-NULL publication row filter refuses the
step with `:untrusted_dependency`; publication membership without a filter is supported.

PostgreSQL 18 `pg_dump`/`pg_restore` preserves package expressions but recreates partition
primary keys with different inheritance metadata (`connoinherit`). The exact relation check
refuses those restored children with `:untrusted_dependency`. A restore procedure must
preserve the package's partition DDL shape; do not bypass the trust check to resume maintenance.

Store maintenance calls each run in a transaction with a separate
`SET LOCAL statement_timeout` statement before the function call. Configure
`config :ash_onetime, :maintenance_statement_timeout_ms, 60_000` (1–2,147,483,647 ms).
Invoke Store maintenance outside a caller-owned transaction. It refuses nested calls with
`:in_transaction` before sending SQL, preserving the caller's settings and pending work.
A direct caller of any definer function must set its own `statement_timeout` before calling
it. An in-function setting cannot arm the current statement's timer. A 57014 cancellation
returns `:maintenance_timeout`, with the fixed message "maintenance statement timed out"
and empty details; retry the rolled-back step. Definers pin `search_path`,
`DateStyle = 'ISO, YMD'`, and `row_security = on`, restoring caller settings on return.

`installed_at` is the install row's creation time inside the migration transaction.
This is conservative: overdue and refusal deadlines start no later than commit.
The reaper accepts 86,400–315,576,000,000 seconds. SQL rejects NULL or an out-of-range
horizon with SQLSTATE `22023`; the Store reports `:invalid_request`.
If an accepted horizon reaches before PostgreSQL's finite timestamp range, no finite
claim is old enough; the reap returns zero rather than raising a timestamp underflow.

Operational notes:

- **One lock budget per prune run.** `config :ash_onetime, :partition_prune_lock_timeout_ms, 2_000`
  (1–5,000 ms; invalid values return `:invalid_request`) bounds the whole call, including lock and trust preflight, not
  each lock: a pending parent `ACCESS EXCLUSIVE` queues every tenant's payload reads and writes,
  so one run can stall that traffic for at most the budget plus the candidate in flight. Each
  parent lock waits only for what remains of the budget; a timeout keeps that candidate with
  reason `:lock_unavailable`, and candidates left when the budget is spent are not examined
  (not counted) until the next run. The child lock is requested while the parent is held, so it
  never waits (`NOWAIT`): a child held by a direct reader or vacuum is kept as
  `:lock_unavailable` and the pass moves on. Taking the parent lock first prevents the late DROP
  upgrade cycle. The caller's `lock_timeout` and `row_security` settings are restored on every
  successful drop or savepoint rollback.
  Dropping a partition also locks the `_default` partition; that lock is taken without waiting
  too, so a `_default`-only holder keeps the candidate as `:lock_unavailable` instead of making
  the drop wait while the parent is held.
- **Running the prune around long transactions.** While something holds the payload table for
  longer than the budget (a backup, a long report, a session idle in a transaction), each cleanup
  run can stall payload traffic once, for up to the budget, and reclaims nothing. Retention is
  unaffected. To avoid the stall: schedule the owner-run prune outside backup and reporting
  windows; or run cleanup with `partition_limit: 0` during them (claim cleanup still runs); or
  lower `:partition_prune_lock_timeout_ms` (a few hundred milliseconds still clears ordinary
  short transactions). Pruning catches up on the first run after the holder ends.
- **One pruner per payload table.** Overlapping cleanups (an Oban run and the mix task, or two
  schedules) both hold the parent's row lock from claim deletion, so both requesting the DROP
  lock would deadlock. The prune takes a transaction-scoped advisory key on the parent's OID just
  before locking; a cleanup that finds it taken stops its partition pass and still commits its
  claim cleanup. Non-owner drivers never take the key.
- **Successful drops hold their locks until the transaction ends**, and the advisory key with
  them. `Store.cleanup` commits right after the pass; if you call it inside your own
  transaction, commit promptly.
- **Why empty months stay attached.** Ordinary short transactions never starve the prune: once
  its lock request is queued, new work queues behind it. Only a lock holder that outlasts the
  budget does, such as a session idle in a transaction, a long report, or a backup. Under
  generic prepared plans, any open transaction that read the payload table holds every
  partition. Find holders with:

  ```sql
  SELECT l.pid, l.mode, a.state, now() - a.xact_start AS xact_age
  FROM pg_locks l LEFT JOIN pg_stat_activity a USING (pid)
  WHERE l.relation = 'your_schema.ash_onetime_response_payloads'::regclass AND l.granted
  ORDER BY xact_age DESC NULLS LAST;
  ```

  Bound them with `idle_in_transaction_session_timeout` and statement timeouts for reporting
  roles, and schedule the prune clear of backups. Retention does not depend on the drop (claim
  cleanup deletes expired payload rows); an unpruned month costs an empty table and its index.
  After lowering retention, months written under the old horizon stay occupied at the front of
  the oldest-first window; raise `partition_limit` (up to 128) to reach newer empty months.
- **Cleanup requires READ COMMITTED.** Under REPEATABLE READ the prune's snapshot predates
  its lock, so a row committed while the lock waits would be invisible to the count;
  cleanup refuses with `:unsupported_isolation` like every claim path.
- **`roll_partitions` copies the parent's ENABLE/FORCE row-security settings and full
  policy set onto every partition it creates.** Children are directly queryable by name
  (a runtime role with default privileges holds SELECT on everything the owner creates),
  so the copied policies are what keep a direct child read tenant-scoped. The store's own
  writes go through the parent, whose policies govern.
- **Children that already exist when you enable RLS must be brought in line once** —
  the copy runs at creation, not retroactively. Include this in the same migration that
  enables RLS on the parent (the `_default` partition and the install-time months
  included):

  ```sql
  DO $copy$
  DECLARE child regclass; r record; roles text; cmd text; using_part text; check_part text;
  BEGIN
    FOR child IN
      SELECT c.oid::regclass FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace n ON n.oid = p.relnamespace
      WHERE n.nspname = 'your_schema' AND p.relname = 'ash_onetime_response_payloads'
    LOOP
      EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', child);
      EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', child);
      FOR r IN SELECT * FROM pg_policies
               WHERE schemaname = 'your_schema'
                 AND tablename = 'ash_onetime_response_payloads'
      LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_policy
                       WHERE polrelid = child AND polname = r.policyname) THEN
          roles := coalesce((SELECT string_agg(quote_ident(m), ', ') FROM unnest(r.roles) AS m), 'PUBLIC');
          cmd := CASE r.cmd WHEN 'ALL' THEN '' ELSE 'FOR ' || r.cmd || ' ' END;
          using_part := CASE WHEN r.qual IS NULL THEN '' ELSE 'USING (' || r.qual || ') ' END;
          check_part := CASE WHEN r.with_check IS NULL THEN '' ELSE 'WITH CHECK (' || r.with_check || ')' END;
          EXECUTE format('CREATE POLICY %I ON %s AS %s %sTO %s %s%s',
                         r.policyname, child, r.permissive, cmd, roles, using_part, check_part);
        END IF;
      END LOOP;
    END LOOP;
  END
  $copy$;
  ```
- **The `_default` partition is load-bearing for the prune's race safety**: an insert that
  arrives while a partition is being dropped blocks, then routes there (dropping `_default`
  converts that into an insert error — still fail-closed, but noisier).
- **A DDL audit tool or event trigger that blocks `ALTER TABLE`** makes the prune keep
  every partition (reason `:ddl_blocked`) without failing cleanup. A hook reapplying FORCE
  similarly refuses with `:force_reapplied`.


## Key rotation

Token verification resolves material by the signed key identifier. Add a new key before
using it to sign. Retain every old verification key until the last token it signed is outside
`max_age + clock_skew`, then remove it. An unknown key identifier fails verification; never
fall back silently to a different key.

The supported runtime is Elixir `~> 1.20` (verified on 1.20.5; this admits later 1.x releases
and excludes 2.0 or newer) and Erlang/OTP 28 or 29 with Ash `>= 3.37.2 and < 4.0.0`,
AshPostgres `~> 2.15 and >= 2.15.2`, and PostgreSQL 18 (the version the project's test harness and release
checks run on). The optional installer HTTP closure is constrained to Mint
`~> 1.10 and >= 1.10.2`. The SQL surface itself needs PostgreSQL 11 or newer — declarative
hash/range partitioning with default partitions, `SELECT ... FOR UPDATE SKIP LOCKED`, and
`pg_advisory_xact_lock(bigint)` are all 11+ features — but nothing below 18 is exercised by
this project's CI: treat older servers as unverified, and report (or CI-pin) the version you
run before relying on one. Release checks include the full suite, mutation matrix, executable
Livebooks against PostgreSQL, warnings-as-errors documentation, exact Hex archive inspection,
and an unpacked zero-configuration consumer, all run on the runtime pinned in `.tool-versions`;
see [CONTRIBUTING](../CONTRIBUTING.md).
