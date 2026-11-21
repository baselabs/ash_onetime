# Upgrading

Version-to-version migration notes. `ash_onetime` follows semantic versioning: from 1.0.0,
breaking DSL or contract changes bump the major version (pre-1.0, breaking changes could
land in a minor), and each breaking change lands here with the exact edit to make.
Security-driven dependency floors follow the documented minor-release policy in
[ADR 0004](https://github.com/baselabs/ash_onetime/blob/main/docs/adr/0004-security-driven-ash-floor.md);
their required dependency edits appear here too.

This guide targets v2.0.0:

```elixir
{:ash_onetime, "~> 2.0.0"}
```

## 2.0.0 — Durable external recovery and response expiry

Existing installations apply the operation-hold migration, then the external-state migration,
then the optional maintenance migration. A single operation-hold generator request writes
both mandatory migrations in timestamp order. Adding `--maintenance --maintenance-role ROLE`
writes all three. New installs already contain the state and guards.

```sh
mix ash_onetime.gen.migrations --repo MyApp.Repo --operation-hold
mix ash_onetime.gen.migrations --repo MyApp.Repo --maintenance --maintenance-role store_maintenance
mix ecto.migrate
mix ash_onetime.doctor --repo MyApp.Repo --live
```

Run migrations as the installation owner. Schema-based installations also use `--tenants`
and apply them for every installation prefix through the repo's tenant migration process.
The generator detects plain and hash-partitioned claims. Maintenance generation refuses
missing prerequisites and timestamps that would put it before them.

Rolling request traffic is supported from v1.9.2. Earlier releases must first upgrade to
v1.9.2, or stop every application node for the 2.0 upgrade. Version 1.10.0 was never published;
its unreleased work is part of 2.0. Stop every v1.9.2 maintenance job, worker and maintenance
Mix task before applying these migrations. Apply the migrations, roll the request nodes, and
start maintenance with 2.0. A late 1.x maintenance call cannot find the moved routines (42883)
and deletes nothing. Request traffic does not call those moved routines.

The external-state upgrade authenticates the historical package shape before changing it,
re-keys historical hash sequences, and adds the claim state, outcome relation, guards and
policies in one transaction. Existing processing rows become `unknown` at attempt 0 and
cannot be reaped. Their response deadline starts at the existing claim deadline. A 2.0 retry
grants an external attempt before recovery. Complete rows retain their existing response.
Retention safety holds throughout a supported rolling deploy; attempt ownership applies
between 2.0 nodes, with the existing claim lock serializing 1.x callers against them.

The operation-hold upgrade builds its indexes concurrently, outside a DDL transaction. Run
one instance per installation. Retry a failed build; invalid indexes are rebuilt and child
attachment resumes. The external-state and maintenance upgrades lock the claim and outcome
parents recursively with a five-second lock timeout. A busy installation can return 55P03;
retry the migration after the long transaction ends. New code against a schema missing the
mandatory state fails closed with `:install_mismatch` before writing a claim.

Ordered rollback retains the same protection. Stop 2.0 callers and maintenance before
rolling back maintenance, external state, then operation hold. Each native `down` locks the
parents before counting unresolved external claims and refuses while any remain. The
external-state rollback also refuses expired responses that the old schema cannot represent.
Row security that prevents an exact refusal count raises instead of proving the set empty.
The external-state upgrade saves the six replaced routines' live definitions, owners,
settings, security modes and full EXECUTE grants in `ash_onetime_external_state_restore`.
This owner-only journal is created atomically with the upgrade and dropped only after exact
rollback restoration. A missing or incomplete journal refuses rollback; do not remove or edit
it. Fresh installs carry the same empty owner-only relation for maintenance trust and doctor
checks. External-state rollback reads the full claim set as its owner with FORCE temporarily
disabled, then restores the original FORCE flag within the same transaction.

Before optional maintenance is installed, only the owner can execute the definer maintenance
steps and cleanup eligibility routine. Maintenance grants its declared maintainer access. The
invoker visibility helper alone retains PUBLIC EXECUTE for bound RLS policies; those policies
need no PUBLIC USAGE on the private routine schema. Each migration scope restores its entering
role before Ecto writes `schema_migrations`.

The operation-hold rollback refuses remaining holds and restores its guards inside the same
locked block. Historical migrations run out of order are owner DDL outside this guarantee.

After migration or restore, run the live doctor for every runtime role on its own connection.
Every package trigger must fire ALWAYS. A full archive restore preserves this; a data-only
restore with `--disable-triggers` changes firing modes and must be repaired before maintenance.
See [maintenance](maintenance.md) and [restore trigger modes](operations.md#trigger-modes-during-restore).

## v1.9.1 — Bounded payload prune (November 10, 2026)

No migration, API, option or telemetry change. Two behavior changes in cleanup's partition
pass: `:partition_prune_lock_timeout_ms` (same default and range) now bounds the whole pass
instead of each lock, so one run can stall payload traffic for at most that budget rather
than once per candidate, and candidates left when it is spent wait for the next run
uncounted; and only one cleanup prunes a given payload table at a time, so overlapping runs
(an Oban job and the mix task) no longer deadlock: the second skips its partition pass and
still commits its claim cleanup. The child lock no longer waits. See
[Operations](operations.md#row-level-security) for finding the lock holder that keeps
empty months attached. Retention never depended on the drop: claim cleanup deletes expired
payload rows in any partition (ADR 0001).

## v1.9.0 — RLS-safe payload prune (November 10, 2026)

Cleanup's payload-partition prune decides `DROP TABLE` as the table owner inside a
per-partition savepoint (an uncommitted `NO FORCE` plus an owner-exempt emptiness probe), so no
row-level-security configuration can narrow the probe — see
[Operations](operations.md#row-level-security). Current installations must apply the
maintenance migration and declare its maintenance role; owner-owned routines perform the prune.
Two cleanup behaviors to review:
cleanup now refuses to run outside READ COMMITTED (`:unsupported_isolation`), and a
refused or kept partition no longer rolls back the claim and nonce deletes — the cleanup
counts map gains `payload_partitions_kept` (all candidates kept, including occupied ones)
and `payload_partitions_refused` (reason-to-count map). Refusal telemetry counts only
refusals. The parent lock has a bounded wait (default 2 seconds, configurable with
`:partition_prune_lock_timeout_ms`, 1–5,000 ms); the child and DEFAULT locks never wait.
Timeout keeps the partition for the next run. The context-boundary DSL and API remain unchanged.

**Dependency security floor:** AshSql now requires `~> 0.8 and >= 0.8.6`.
[0.8.4](https://hex.pm/packages/ash_sql/0.8.4) and
[0.8.5](https://hex.pm/packages/ash_sql/0.8.5) were retired for a query-cache security
issue; [0.8.6](https://hex.pm/packages/ash_sql/0.8.6) is the patched minimum. Consumers
locked below it must run `mix deps.update ash_sql` and `mix hex.audit` when upgrading
to 1.9.0. This constraint change needs no database migration.

## v1.8.0 — context boundaries (November 8, 2026)

Additive: no existing behavior changes and existing consumers need no migration. The new
`context_boundary` section opts a resource into conditional-append semantics over an
append-only fact table (`AshOnetime.Boundary.read/3` and `append_if/5`, plus
`AshOnetime.Boundary.Change` for create actions). Resources that adopt it create their
fact tables with `mix ash_onetime.gen.migrations --fact-tables <names>`; resources that
do not declare the section are unaffected.

## v1.7.0 — Ash, AshPostgres, and AshSql security floors

Use current floors: Ash `>= 3.37.2 and < 4.0.0`, AshPostgres `~> 2.15 and >= 2.15.2`,
and AshSql `~> 0.8 and >= 0.8.6` (the patched floor for the query cache).
Run `mix deps.update ash ash_postgres ash_sql`, `mix hex.audit`, and `mix deps.audit`.
For application resources, run `mix ash.codegen` and migrate the AshPostgres helpers.

## v1.6.0 — Separate nonce retention and Ash security floor

**Consumers locked below Ash 3.34.6 must update Ash to take 1.6.0.** Raise any
direct Ash constraint to `>= 3.34.6 and < 4.0.0`, then resolve and audit:

```sh
mix deps.update ash
mix hex.audit
mix deps.audit
```

[EEF-CVE-2026-101028](https://cna.erlef.org/osv/EEF-CVE-2026-101028.html) is fixed
in Ash 3.34.6. The previous 3.34.3 floor admits this advisory. All other dependency
floors are unchanged.

Optional `retain_for` keeps nonce claims longer than `max_age` accepts proofs. Set it
inside the DSL `window` as a duration, or pass integer seconds to `Transaction.nonce/2`.
It must be at least `max_age`, and its sum with `clock_skew` must stay within the existing
duration ceiling. Omit it to preserve 1.5.0 behavior. Keep the extended configuration on
retries to classify retained late replays as `:nonce_already_used`.

Use `Transaction.nonce_retention_deadline/2` to read the stored deadline by the same
operation, partition, scope, key, and optional prefix used for admission. See the
[executable nonce examples](one-time-nonces.md#retain-claims-longer-than-proof-acceptance).
No migration is required: existing rows keep their deadlines, and new claims use the
configured retention.

## v1.5.0 — Ash and Mint security floors

Raise direct constraints to the current Ash floor `>= 3.37.2 and < 4.0.0` and optional
Mint `~> 1.10 and >= 1.10.2`, then run `mix deps.unlock --all` and `mix deps.get`.
Run `mix hex.audit` and `mix deps.audit`. Mint's patched 1.10 line remains supported.
Consumers upgrading from older feature lines must apply the later migration instructions above.

## v1.4.0 — the pre-peer claim lock and the corrected external-effect contract (2026-09-24)

**One behavior change to review.** A concurrent same-key retry of an external-effect action
may now return `:request_in_progress` (409/425) within `external_lock_timeout_ms`
(default 2000) instead of waiting out the original and replaying. Clients should treat that
code as wait-or-retry — the correct posture for idempotent actions. If you need the old
waiting behavior, raise `external_lock_timeout_ms` toward its 25000 ceiling (5s of
headroom under the committed-claim worker kill, so the lock timeout — not the worker
kill — decides a contended wait); if you want refusal faster, lower it. Nothing to edit otherwise: the lock is automatic for every
`external_effect` protection.

Two normative requirements in [External effects and recovery](external-effects.md) were
corrected/tightened after a 2026-09-24 design review — no library schema or API change,
but a peer or adapter that conformed under the previous wording may no longer conform:

- **The peer's idempotency-by-operation-key defense remains a MUST; atomic key claims
  (insert-on-key, not check-then-act) are now a SHOULD.** Before this release an honest
  in-flight retry produced two executes under one operation key (observed, overlapping) —
  a check-then-act peer double-spends in exactly that window, and the pre-peer lock now
  prevents the overlap. If your peer claims keys with a read-then-write sequence, moving
  the claim into one `INSERT ... ON CONFLICT`-style statement keeps you correct under
  every retry interleaving. See ADR 0010 and ADR 0001.
The historical 1.x reaper could remove external recovery points. In 2.0 the package excludes
all external and legacy unknown processing claims itself; the current procedure above replaces
that historical operational requirement.

Also new: the adapter execution environment is normative (callbacks run inside the
caller's open transaction, unbounded — adapters MUST bound their own peer call; an
ambiguous execute is followed by recover in the same transaction), a `:absent` vs
`:unknown` mapping table for real HTTP peers with a worked bounded adapter, and Recipe 4
(external effect via a transactional outbox) in the recipes guide.

## v1.3.2 — the `Verified` constructor (2026-09-20)

`AshOnetime.Verified.new/1` is the sanctioned
constructor for the opaque type, for hosts implementing the `AshOnetime.Verifier`
verify callback or the `AshOnetime.KeySource` mint callback. Existing struct-literal
construction keeps working at runtime but violates the opacity contract Dialyzer
enforces (`contract_with_opaque`) — switch verifier/minter callbacks to
`Verified.new/1`, which validates at mint time and never raises.

This patch also raised the optional Mint floor to `~> 1.10 and >= 1.10.1` for
[EEF-CVE-2026-82672](https://cna.erlef.org/osv/EEF-CVE-2026-82672.html). Hosts that carried
Mint through the optional installer HTTP closure needed to resolve Mint 1.10.1 or newer; core
consumers did not gain a Mint runtime dependency.

## v1.3.0 — Security dependency floors

Use the current dependency floors in [ADR 0004](https://github.com/baselabs/ash_onetime/blob/main/docs/adr/0004-security-driven-ash-floor.md),
then run `mix deps.update ash ash_postgres ash_sql`, `mix hex.audit`, and `mix deps.audit`.
Ash resources require `config :ash, default_string_length_count: :codepoints`.
Codepoints match SQL length counting; grapheme counting does not bound stored value size.

## v1.2.2 — additive (no upgrade action)

`AshOnetime.Transaction.claim_id/1` — the sanctioned accessor for a fresh admission's
claim UUID. Nothing to do on upgrade; start persisting the UUID wherever you correlate
your own invocation records with the claim or hand it to an external
execute/recover peer.

## v1.2.0 — operations preflight and hardening (additive, no upgrade action)

v1.2.0 is an **additive** minor: one new operator capability (`mix ash_onetime.doctor --live`)
plus documentation and internal hardening. No breaking change, no DSL/contract change, no
migration, no upgrade action for existing consumers.

- **`mix ash_onetime.doctor --live`** — an opt-in extension to the install preflight that
  connects to the database (read-only, catalog tables) and verifies the schema is current
  for the running package: the `logical_partition` columns (the 1.1 upgrade marker), the
  `ash_onetime_response_payloads` table and its `_default` partition, the cleanup/reap
  functions by exact arity, and the delete-guard triggers. This catches
  upgrade-package-without-running-migrations as a named failure at preflight time instead
  of a cryptic `:store_invariant` at the first admission after deploy. Without `--live`
  the doctor stays offline. The schema checked is `--prefix` when given, else `public`.
- **Backup/restore runbook** (operations.md) — the `restore-from-backup` procedure: what a
  database restore rewinds per strategy (nonce windows, idempotent re-execution), how to
  scope reconciliation, and the post-restore partition roll-forward.
- **PostgreSQL floor statement** (README, operations.md) — the SQL surface requires
  PostgreSQL 17+ (the maintenance SQL uses `MAINTAIN`); the project's CI exercises 18, and versions below it are unverified.
- **Store digest comparisons unified to constant-time** — the last two plain-`==` digest
  comparisons in the store (the stored-payload digest check and the caller-digest
  completion check) now use a size-guarded `:crypto.hash_equals` helper, so every digest
  comparison site in the library follows one convention. No behavior change: neither site
  compares attacker-secret material, and both operands were already 32-byte-constrained.
- **Test-lifecycle hardening** — the full-suite `RollContentionTest` flake is eliminated
  at the mechanism (same-process connection checkout/checkin through a shared test
  helper), and the admission decision functions (`resolve/5` arms and the request/claim
  sanitizers) carry direct unit coverage naming the failing function. No library code
  changed for the test fixes.

## v1.1.0 — transaction-owned admission and logical partitions

v1.1.0 adds `AshOnetime.Transaction` for hosts that already own the authoritative Ecto
transaction. The public boundary admits idempotency and one-time nonce claims without starting
or committing a transaction, and completes exact replay bytes in that same transaction.

Fresh installs already include the bounded `logical_partition` column in all claim and response
payload tables. Existing 1.0 installs must generate and run the additive upgrade before calling
the new API:

```sh
mix ash_onetime.gen.logical_partitions --repo MyApp.Repo
mix ecto.migrate
```

All existing rows are backfilled to `global`; existing Ash DSL callers therefore preserve their
locator authority byte-for-byte. The new collision identity is
`(logical_partition, operation_hash, scope_hash, key_hash)`. The generated down migration
refuses while any non-global claim or payload exists because collapsing those rows would merge
distinct authorities. Remove or migrate non-global rows through the owning application before
attempting rollback; never edit the generated refusal guard.

This is an additive minor release. Existing resource DSL call sites require no code changes.

## v1.0.0 — the stability contract

From 1.0.0, `ash_onetime` publishes this compatibility contract:

- **The public surface is the published documentation.** The stable API is exactly what
  the docs show at 1.0.0: the `AshOnetime.Resource` DSL (pinned by the cheat-sheet
  freshness gate), every function with a public `@doc` in a module with a public
  `@moduledoc` (the hexdocs reference surface), the closed telemetry surface (event
  names, measurements, metadata shapes, `result_class` atoms), the typed-error and
  replay-result shapes, the generated install DDL and flow, and the mix tasks' CLI.
  `@doc false`/`@moduledoc false` seams are internal even where tracked by the
  architecture census — the census is the drift guard, not the promise.
- **The promise.** Code written against the documented 1.0 surface compiles and behaves
  compatibly across the whole v1 branch. Breaking changes to the public surface happen
  only at 2.0. Additions ship in minors; fixes in patches.
- **Deprecations** are announced in the CHANGELOG with compile-time warnings where
  feasible and removed only at a major.
- **Reserved break-rights** (incompatible change permitted, each explained in the release
  notes): security (the v0.7.0 EEF-CVE floor repair is the operating precedent),
  behavior-correcting bug fixes, and new compiler/linter warnings.
- **Ash floor raises after 1.0.** Security-driven raises ship as a minor immediately
  (never held for a major number) with an entry on this page; non-security raises ship as
  a minor only when the CI compatibility matrix is proven green on the new floor and this
  page documents the operator step. Breaking changes to ash_onetime's own DSL/API remain
  major-only; a future Ash 4 is a matrix-extension event first.
- **Experimental carve-out.** Features explicitly marked experimental in their docs carry
  no compatibility guarantee until a release marks them stable (nothing is marked
  experimental today).
- **Pre-1.0 releases were non-binding.** Compatibility was guaranteed only within a 0.x
  patch series (each 0.x minor could break — v0.7.0's floor raise did); from 1.0.0,
  strict semver.
- **Frozen formats.** Persisted response payloads (codec tag + contract-digest binding +
  digest + encoded bytes — ADR-0007) and the token wire format within its acceptance
  window (ADR-0008) are 1.x cross-version compatibility surfaces; see the repository's
  `docs/adr/` records for the rules.

## v0.6.0 — Doctor and Phoenix integration

Run `mix ash_onetime.doctor --repo MyApp.Repo` after installation and upgrades.
It checks the Ash security floor, configured worker queues, and prefix validity.
Add `--live` to verify the installed schema and role boundary against PostgreSQL.
The [Phoenix guide](phoenix.md) composes the Plug, replay signal, and typed HTTP mapping.
Replay and cleanup read the authoritative payload partition; completion enforces
cross-partition payload uniqueness.

## v0.5.1 — Internal helpers

`Cache.key/1` and `Resource.Verifier.verify_required_shape/2` are internal test seams, not supported consumer APIs.
- **CONSUMER-VISIBLE — PartitionWorker moved to a dedicated `:ash_onetime_partitions` Oban
  queue (L4).** Forward partition creation previously shared `:ash_onetime_cleanup` with
  cleanup. **Add the queue to your Oban config** or `PartitionWorker` jobs sit unscheduled and
  payloads past the install window route to `_default` (deleted at retention by claim cleanup,
  never reclaimed as a table; corrected in v1.9.1):

  ```elixir
  config :my_app, Oban,
    queues: [ash_onetime_cleanup: 1, ash_onetime_reap: 1, ash_onetime_partitions: 1]
  ```

  The discard-alert SQL and the partition-discard triage in `operations.md` now name the new
  queue.

- **CONSUMER-VISIBLE — protected resources declaring a reserved-named attribute now fail to
  compile (M2).** A protected resource that declares an attribute named `:key`, `:issued_at`,
  `:expires_at`, `:verification_state`, or `:algorithm` — even with no `accept` on any action —
  now fails compilation (it previously compiled and was caught only at runtime by
  `reject_reserved/1`). If a protected resource has such an attribute, **rename it** (e.g.
  `:idempotency_key` instead of `:key`); reserved names are trusted local facts the
  verification path derives itself and may not come from caller input.

- **CONSUMER-VISIBLE — the `:clock` verify-option override is off by default in every build
  (M5).** The gate changed from `Mix.env() == :test` (which a `MIX_ENV=test mix deps.compile`
  consumer could accidentally ship live) to `Application.compile_env(:ash_onetime,
  :allow_clock_override, false)`. The override is now disabled unless explicitly configured,
  regardless of `MIX_ENV`. If your test suite pins verification time via the `:clock` option,
  set it in `config/test.exs`:

  ```elixir
  config :ash_onetime, allow_clock_override: true
  ```

  (set BEFORE compiling `ash_onetime` — the gate is read at build time).

- **CONSUMER-VISIBLE — Oban worker error tuples now carry the inner reason (L5).**
  `{:error, :reap_failed}` became `{:error, {:reap_failed, reason}}` (and likewise for
  `:roll_partitions_failed`, `:cleanup_failed`). Oban serializes the tuple into `job.errors`;
  the distinguishable store cause (`:lock_timeout` / `:disconnected` / `:store_invariant` / …)
  now survives exhaustion. If you pattern-match the old bare atom, update to the 2-tuple
  inner shape. Retry/discard semantics are unchanged.

## v0.4.0 — Operational surfaces

External recovery trusts proven absence and requires peer idempotency by operation key.
A redundant execute is safe only when the peer deduplicates it.

The committed-claim worker's 30-second deadline emits `:worker_timeout`, distinct from
`:disconnected` and unknown dispatch. All uncertain nonce admissions fail closed.

Maintenance workers use bounded linear backoff with jitter, capped at 120 seconds.
Configure their separate queues and monitor discarded jobs; see [Operations](operations.md).

`AshOnetime.Telemetry.attach/0` routes point events to a consumer metric stream.
Library events contain value-free metadata and never span exception data. Consumers
own aggregation and tracing at their own boundary.

`AshOnetime.Cache.Ets` supplies a supervised, bounded, TTL-aware optional response cache.
Cache entries remain untrusted, and PostgreSQL alone grants admission.
See [Telemetry](telemetry.md) and [Security](security.md) for the public contracts.

## Ash floor raised in v0.7.0

The old 3.31.3 minimum addressed forged keyset-cursor injection. Current installs require
Ash `>= 3.37.2 and < 4.0.0`; earlier floors do not include subsequent security fixes.
Update direct constraints and run `mix deps.update ash`, `mix hex.audit`, and `mix deps.audit`.
See [ADR 0004](https://github.com/baselabs/ash_onetime/blob/main/docs/adr/0004-security-driven-ash-floor.md).

## Ash floor raised in v0.3.0

The old 3.31.1 minimum addressed relationship predicate injection and keyset deserialization.
Current installs require Ash `>= 3.37.2 and < 4.0.0`; do not retain the earlier constraint.
Update direct constraints and run `mix deps.update ash`, `mix hex.audit`, and `mix deps.audit`.
See [ADR 0004](https://github.com/baselabs/ash_onetime/blob/main/docs/adr/0004-security-driven-ash-floor.md).

## Database maintenance upgrade

The replacement for forward-migration generation is one maintenance upgrade per schema:

```sh
mix ash_onetime.gen.migrations --repo MyApp.Repo --prefix store --maintenance --maintenance-role store_maintenance
mix ecto.migrate
```

Existing installations must first apply the migrations their install predates, in order:

- v0.1 installs: generate and apply the shipped `ash_onetime.gen.roll_forward`
  migration using a 1.x release. It adds the response-partition index. Keep that
  migration; the generator is removed in 2.0, so run it before updating the dependency.
- Installs before v1.1: apply `ash_onetime.gen.logical_partitions` to backfill `global`
  and replace the claim collision keys.
- Installs before v1.10: apply `ash_onetime.gen.migrations --operation-hold`.

Fresh v1.10 installs already contain the operation-hold schema. If they have no separate
operation-hold migration, generate and apply `--operation-hold` once (it is idempotent)
before generating `--maintenance`, whose file-level prerequisite checks for that migration.
These prerequisites apply to plain and hash claims, every supported hash partition count,
and each install schema. `--tenants` selects the tenant migration directory; run the chain
for every schema through the application's ordinary migration runner. Fact-table migrations
are independent and retain their data, identity sequences, indexes and append-only guards.

The maintenance upgrade recognizes the exact surviving primary keys from the historical
logical-partition upgrade: `(operation_hash, id)` on hash claims and
`(partition_date, claim_id)` on payloads. It compares every root and child against fresh
same-server package references before altering any relation. Only validated historical keys
are rebuilt to include `logical_partition`; validated historical CHECK expressions are
recreated in their restore-stable form using their actual catalog names. This preserves
claim and payload data, including rows backfilled by ADD COLUMN, and makes the upgraded
schema equal to a fresh install. Column order and generated constraint/index names are
not schema semantics. Other changes, missing constraints, duplicate replacement CHECKs,
and altered children refuse rather than being adopted. No trust field is relaxed by this
conversion. Upgraded databases support stock PostgreSQL 18 dump/restore followed by prune,
reap and roll, with the same exact reference comparison.

The conversion holds an ACCESS EXCLUSIVE lock on each converted table and all its
partitions while it re-adds the CHECKs, which scans every row, and rebuilds the primary key
index. Its duration grows with the claim and payload rows, and requests that touch those
tables wait for it. Run this migration in a window sized to those tables.

The generator requires both mandatory 2.0 migrations, operation hold and external state, to precede maintenance. Stop old maintenance
jobs first: their prefix-hash advisory lock does not coordinate with the new OID lock. Scope
all consumer policies on package tables to runtime roles before applying the migration;
it raises and names every extra policy that applies to the owner.

The migrator needs CREATE on the database for the dedicated routine schema. It must own
every replaced function and be able to SET ROLE to the payload owner;
that owner needs CREATE on the install schema. No catalog grants are required.
The migration constructs a reference copy from package DDL in its own transaction and drops
it after capturing the expected shape. Attribute numbers are normalized to column names,
so adding operation-hold columns to a 1.x install does not change its logical shape.
Shapes are keyed to `server_version_num`; after a server-version change the function
rebuilds its reference on that server. The install record's `installed_at` is its creation
time inside the transaction, so deadlines start no later than commit.
The upgrade moves the original package functions into the dedicated routine schema before
replacing them. Downgrade restores their original schema, owners, definitions, and grants.

Downgrade restores the original routine owners and ACL grantor chains. PostgreSQL requires
the migrating login to be able to SET ROLE to every original owner and grantor. SET ROLE to
the payload owner alone cannot authorize acting as a different grantor. Without that
capability, PostgreSQL returns `42501` and the entire downgrade rolls back; it does not
silently attribute grants to the owner. Grant the needed SET membership before downgrading.

After upgrading, call `mix ash_onetime.roll_partitions` to recover missed past and forward
months from `_default`. Recovery replaces the removed `ash_onetime.gen.roll_forward` task.
The roll does not delete retained or held claims. See [Operations](operations.md#forward-response-partitions).

## DPoP replay fence (`commit: :independent`)

Additive: a new opt-in `commit:` option on `:one_time_nonce` protections (default
`:with_action`). No migration, no schema change, no new error code. Existing nonce consumers are
unchanged. Adopt by adding `commit :independent` to a nonce `protect` block whose proof should
survive action-body failure (RFC 9449 §11.1). See ADR-0003 (Independent-commit nonce) and the
[operational characteristics](operations.md#dpop-replay-fence-operational-characteristics) for
pool-sizing notes. Declaring `commit:` on `:idempotency` is now a compile error (idempotency
commits with its effect).

## Single `limits` surface (shipped in v0.1.0)

The dual `limits` surface collapsed to one `protect`-level vocabulary in v0.1.0. Response-size
limits are declared on the `protect` block, not the `response` entity:

```elixir
protect :charge do
  strategy :idempotency
  # ...
  response MyApp.ChargeCodec, fields: [:id, :status], classify: MyApp.ChargeClassifier
  limits max_response_bytes: 8_388_608
end
```

The `protect limits:` option accepts the full 11-key union — the key/verification/cache
keys (`max_key_bytes`, `max_token_bytes`, `max_scope_components`, `max_fingerprint_bytes`,
`verifier_timeout_ms`, `max_cache_entry_bytes`) and the response-payload keys
(`max_response_bytes`, `max_response_depth`, `max_response_nodes`, `max_response_entries`,
`max_response_scalar_bytes`). All keys are validated at compile time. If you are upgrading
from a pre-v0.1.0 snapshot, move any `response ..., limits: [max_response_*: ...]` onto
`protect ..., limits: [...]`.

This change is additive in coverage (no limit is lost) and removes a redundant configuration
surface where two places could spell overlapping limits.

## Between releases

Non-breaking additions (new optional integrations, new introspection helpers, new guides)
ship in patch or minor releases and need no migration. Check the
[CHANGELOG](https://github.com/baselabs/ash_onetime/blob/main/CHANGELOG.md) for the full list
per release.

If you depend on a private (non-documented) module or function, it may change in any release
— the public contract is the documented DSL, the modules in the API reference, and the
behaviors (`AshOnetime.Codec`, the `classify/2` contract on `AshOnetime.ResponseClassifier`,
verification callbacks returning `AshOnetime.Verified`).
