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

## Key rotation

Token verification resolves material by the signed key identifier. Add a new key before
using it to sign. Retain every old verification key until the last token it signed is outside
`max_age + clock_skew`, then remove it. An unknown key identifier fails verification; never
fall back silently to a different key.

The supported runtime is Elixir `~> 1.20` (verified on 1.20.2) and Erlang/OTP 29 with
Ash `>= 3.29.3`, AshPostgres 2, and PostgreSQL 18. Release checks include the full suite, mutation
matrix, warnings-as-errors documentation, exact Hex archive inspection, and an unpacked
zero-configuration consumer, all run on the runtime pinned in `.tool-versions`; see
[CONTRIBUTING](../CONTRIBUTING.md).
