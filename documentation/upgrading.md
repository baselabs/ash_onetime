# Upgrading

Version-to-version migration notes. `ash_onetime` follows semantic versioning: from 1.0.0,
breaking DSL or contract changes bump the major version (pre-1.0, breaking changes could
land in a minor), and each breaking change lands here with the exact edit to make.
Security-driven dependency floors follow the documented minor-release policy in
[ADR 0004](https://github.com/baselabs/ash_onetime/blob/main/docs/adr/0004-security-driven-ash-floor.md);
their required dependency edits appear here too.

This guide targets v1.10.0. Pin the
minor whose public capabilities you use and review this page on each minor bump:

```elixir
{:ash_onetime, "~> 1.10.0"}
```

## v1.10.0 — Operation holds (November 13, 2026)

Existing installations must generate and apply the operation-hold migration before deploying
1.10.0. The 1.10.0 store code reads and writes the new `hold_reference` column, so on an
installation without the migration admission refuses with `:store_invariant`; it never proceeds
unprotected. Run the migration first, check it with the live doctor, then deploy:

```sh
mix ash_onetime.gen.migrations --repo MyApp.Repo --operation-hold
mix ecto.migrate
mix ash_onetime.doctor --repo MyApp.Repo --live
```

For schema-based installations, use `--tenants` and run the generated migration for every
installation prefix using the repo's tenant migration process. The upgrade detects plain or
hash-partitioned claims automatically. It adds nullable `hold_reference`, adds the CHECK as
NOT VALID and then validates it, builds the partial cleanup and release indexes CONCURRENTLY,
and drops the superseded full retention index. For hash claims it creates each parent index
ON ONLY, builds each child concurrently, and attaches them. A failed concurrent build's INVALID
index is dropped and rebuilt on retry; an incomplete parent resumes child attachment. The
migration disables both the DDL transaction and migration lock because concurrent index
creation cannot run inside a transaction. Run one instance of this migration per installation
at a time; rerun it after a failed index build. It also replaces the delete guard and cleanup
function. Existing data keeps its retention and has no hold.

New installs already contain these objects. Run migrations as the installation owner.

The upgrade is reversible. Before `down`, return to a 1.9 release, stop hold-producing callers
and release every outstanding hold. `down` refuses while any hold remains or while row security
prevents it from proving that none does; otherwise it restores the previous functions and the
full retention index and removes hold support. The downgrade probes with row security
disabled, so a FORCE policy that applies to the migrating role refuses the downgrade even when
the policy would show every row; use the installation's authorized maintenance procedure.

The payload prune's schema-resolution fix needs no separate migration. It resolves the
namespace of the addressed `ash_onetime_response_payloads` parent, including an explicit
prefix, instead of the first schema on `search_path`. The generated DEFAULT drain and monthly
partition creation resolve that same namespace, including when no prefix is supplied.

See [Idempotency](idempotency.md#keep-an-open-operations-record) for placing holds, releasing
in the settling transaction, reference uniqueness, row security, and the guard's boundary.

## v1.9.2 — Prune never waits on `_default` (November 10, 2026)

No migration, API, option or telemetry change. The partition prune now takes the `_default`
partition's lock without waiting before a drop; a busy `_default` keeps the candidate as
`:lock_unavailable`. See [Operations](operations.md#row-level-security) for running the prune
around long transactions.

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
payload rows in any partition (ADR-0001 amendment).

## v1.9.0 — RLS-safe payload prune (November 10, 2026)

Cleanup's payload-partition prune decides `DROP TABLE` as the table owner inside a
per-partition savepoint (an uncommitted `NO FORCE` plus an owner-exempt emptiness probe), so no
row-level-security configuration can narrow the probe — see
[Operations](operations.md#row-level-security). No consumer migration is required, and no
role, function, or superuser bootstrap exists to install. Two behavior changes to review:
cleanup now refuses to run outside READ COMMITTED (`:unsupported_isolation`), and a
refused or kept partition no longer rolls back the claim and nonce deletes — the cleanup
counts map gains `payload_partitions_kept` (all candidates kept, including occupied ones)
and `payload_partitions_refused` (reason-to-count map). Refusal telemetry counts only
refusals. Parent and child locks are taken in order with a bounded wait (default 2 seconds,
configurable with `:partition_prune_lock_timeout_ms`, 1–5,000 ms); timeout keeps the
partition for the next run. The `:row_security_blocked` error code never
shipped (it existed only on this unreleased line) and is gone. The context-boundary DSL
and API from 1.8.0 stay unchanged.

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

## v1.7.0 — Ash, AshPostgres, and AshSql security floors (October 28, 2026)

**Consumers locked below Ash 3.37.2 or AshPostgres 2.15.2 must update them to take
1.7.0.** Raise any direct constraints to Ash `>= 3.37.2 and < 4.0.0`, AshPostgres
`~> 2.15 and >= 2.15.2`, and AshSql `~> 0.8 and >= 0.8.4`, then resolve and audit:

```sh
mix deps.update ash ash_postgres ash_sql
mix hex.audit
mix deps.audit
```

[EEF-CVE-2026-96581](https://cna.erlef.org/osv/EEF-CVE-2026-96581.html) (a primary-key
upsert ignores attribute multitenancy) is fixed in Ash 3.37.2, and
[EEF-CVE-2026-114214](https://cna.erlef.org/osv/EEF-CVE-2026-114214.html) in Ash 3.37.1.
[EEF-CVE-2026-115627](https://cna.erlef.org/osv/EEF-CVE-2026-115627.html) and
[EEF-CVE-2026-115635](https://cna.erlef.org/osv/EEF-CVE-2026-115635.html) are fixed in
AshPostgres 2.15.2, which requires AshSql 0.8.4. AshPostgres 2.15 ships version 7 of its SQL
helper functions; if your own resources use AshPostgres, run `mix ash.codegen` and migrate as
AshPostgres directs. ash_onetime's own schema and migrations are unchanged.

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

## v1.5.0 — Ash and Mint security floors (October 7, 2026)

Raise any direct Ash pin to `>= 3.34.3 and < 4.0.0`. If your dependency graph includes Mint,
raise its pin to `~> 1.10 and >= 1.10.2`, then resolve the graph again:

```sh
mix deps.unlock --all
mix deps.get
mix hex.audit
mix deps.audit
```

The Ash floor closes
[EEF-CVE-2026-94201](https://cna.erlef.org/osv/EEF-CVE-2026-94201.html), which affects Ash
`>= 3.5.1 and < 3.34.3`. Ash 3.33.11 includes the
[EEF-CVE-2026-93477](https://cna.erlef.org/osv/EEF-CVE-2026-93477.html) fix but is still in
EEF-CVE-2026-94201's affected range, so it cannot be the package floor. The optional Mint
floor closes the 1.10.x ranges covered by
[EEF-CVE-2026-91043](https://cna.erlef.org/osv/EEF-CVE-2026-91043.html),
[EEF-CVE-2026-92103](https://cna.erlef.org/osv/EEF-CVE-2026-92103.html), and
[EEF-CVE-2026-94194](https://cna.erlef.org/osv/EEF-CVE-2026-94194.html); Mint 1.10.2 contains
the backported fixes for all three. The committed development lock exercises Ash 3.34.4 and
Mint 1.11.0, while the published ranges preserve compatibility with patched Mint 1.10.x
consumers and allow newer Mint 1.x releases.

All other dependency floors are unchanged. This release does not change the ash_onetime DSL,
public API, database schema, persisted response format, or token wire format, and it requires
no migration.

**Keeping your current feature line:** use
`{:ash_onetime, "~> 1.4.2"}` ([1.4.2](https://hex.pm/packages/ash_onetime/1.4.2)) or
`{:ash_onetime, "~> 1.3.4"}` ([1.3.4](https://hex.pm/packages/ash_onetime/1.3.4)). Both
patches carry these dependency floors and preserve their feature line's public interfaces
and storage formats.
The Ash and Mint pin updates above apply to those patches too.

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
  every retry interleaving. See ADR-0010 and ADR-0001's 2026-09-24 amendments.
- **The reaper on external-effect actions requires a reconciliation path.** A reaped claim
  deletes its operation key with it, so a post-reap retry executes under a new key and no
  key-based defense remains at either layer. Enable `ash_onetime.reap` on an
  external-effect action only with a business-level way to settle an outcome-unknown claim
  before its abandonment horizon (ADR-0002's amendment, ADR-0009 records why a
  reap-surviving derived key was rejected).

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

## v1.3.1 — repository-only hardening (2026-09-17)

Nothing to do. No requirement, dependency floor, or public API changed: the release
enforces the project's own build toolchain in-repo (an OTP allowlist in
`config/config.exs`, which never ships in the package), adds a compose test database
with a per-machine port, makes dependency currency mechanical, and makes the
repository's developer surface tri-platform: macOS, Linux, and Windows, with no
POSIX-only tooling in any gate, proven on a developer machine. CI runs on Linux only.

## v1.3.0 — security dependency floors (2026-09-16)

If you pin Ash or AshPostgres yourself, raise those pins to Ash
`>= 3.33.4 and < 4.0.0` and AshPostgres `~> 2.13`, then refresh:

```sh
mix deps.update ash ash_postgres
mix hex.audit
mix deps.audit
```

No action is needed for AshSql, Igniter, or Mint unless you pin them directly:
`ash_onetime`'s own requirements (`ash_sql ~> 0.7 and >= 0.7.1`, and — when present
in your graph — `igniter ~> 0.8 and >= 0.8.4`, `mint ~> 1.10`) already exclude the
advised versions transitively. If you do pin them, raise those pins to the same
floors.

**Ash 3.33 additionally requires a string-length counting config.** Ash refuses to
compile resources until your application declares how `min_length`/`max_length`
count string length (its remediation for EEF-CVE-2026-82752 — grapheme counting
does not bound value size). Add the recommended codepoints mode to your config:

```elixir
config :ash, default_string_length_count: :codepoints
```

`:codepoints` matches how SQL data layers count, so `max_length` bounds the size of
stored values; `:mixed` keeps the pre-3.33 grapheme behavior but does not bound
value size. Individual attributes can override the default with the `length_count`
constraint. See the
[Ash backwards-compatibility config](https://hexdocs.pm/ash/backwards-compatibility-config.html#default_string_length_count).

These consumer requirements implement the security floors in
[ADR 0004](https://github.com/baselabs/ash_onetime/blob/main/docs/adr/0004-security-driven-ash-floor.md).
OBSERVED: the September 15, 2026 Hex audit reported 26 advisories in the previous
development lock; the advisory ranges and release metadata identify the patched
minimums above. The doctor now rejects Ash below 3.33.4. No data migration or
DSL change is required. Mint remains optional, and the optional integrations
remain host-owned runtime applications.

## v1.2.3 — runtime application closure fix (no upgrade action)

The package's `.app` spec no longer lists `plug`, `oban`, `igniter`, or
`stream_data` as runtime applications — previously they were claimed by
ash_onetime whenever present in your own dependency closure. Nothing to do on
upgrade: the optional integrations (the Plug module, the Oban workers, the
Igniter installer) compile exactly when your own `deps()` lists the dependency,
and those applications were always started by your own application tree, never
by this extension. A release that carried any of them keeps working; only the
extension's redundant claim on their boot order is gone.

## v1.2.2 — additive (no upgrade action)

`AshOnetime.Transaction.claim_id/1` — the sanctioned accessor for a fresh admission's
claim UUID. Nothing to do on upgrade; start persisting the UUID wherever you correlate
your own invocation records with the claim or hand it to an external
execute/recover peer.

## v1.2.1 — documentation only (no upgrade action)

README assurance signal (mutation-battery badge, coverage statement). No code, DSL, or
contract change; nothing to do on upgrade.

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
  PostgreSQL 11+; the project's CI exercises 18, and versions below it are unverified.
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

## v0.6.0 — enhancements (no upgrade action)

v0.6.0 is an **additive** minor bump: two new capabilities (a `mix ash_onetime.doctor`
upgrade-preflight task and a Phoenix integration guide) plus internal perf/cleanliness gap
closures. No breaking change, no DSL/contract change, no upgrade action for existing consumers.

- **`mix ash_onetime.doctor --repo MyApp.Repo`** — a read-only preflight that checks the Ash
  security floor, Oban queue configuration (advisory), and prefix validity. Run it after install
  and after each upgrade to catch the silent-failure modes (e.g., a missing
  `:ash_onetime_partitions` queue that silently stops forward partition creation).
- **[Phoenix integration guide](phoenix.md)** — a controller integration pattern wiring the
  Plug, the `replayed?/1` signal, and the error-code → HTTP-status mapping into a complete
  controller pattern.
- **Cleanup delete-guard probe partition-scoped** — the `:complete`-branch cleanup probe
  (`install.exs`) now constrains `partition_date = OLD.response_partition`, turning an
  O(partitions) scan into a point lookup (the H1 read-path tail). Same property shift as H1:
  partition pruning and cross-partition duplicate detection are mutually exclusive; the write
  path remains the authoritative guard.
- **Dead `trusted_context` parameter removed** from the internal scope/key resolution path
  (`admission.ex`) — cleanliness; no behavior change.

## v0.5.1 — internal patch (no upgrade action)

v0.5.1 is a **patch**: test-only hardening of the v0.5.0 closeout's five documented test
gaps, plus a behavior-identical lint cleanup. No consumer-visible change, no DSL/contract
change, no upgrade action.

- Three internal helpers are now `@doc false` public callables for deterministic contract
  testing (`Store.Postgres.roll_advisory_key/1`, `Cache.key/1`,
  `Resource.Verifier.verify_required_shape/2`). They are undocumented test seams, not a
  supported API — do not depend on them.

## v0.5.0 — security hardening from the independent code review

v0.5.0 lands the sixteen findings (M1–M5, L1–L11) from the v0.4.0 independent code review.
It is a **minor** bump because four changes are consumer-visible and require action on
upgrade; the rest are internal hardening (no consumer action). Read the four items below
before upgrading.

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

The remaining twelve findings (M1, M3, M4, L1, L2, L3, L6, L7, L8, L9, L10, L11) are internal
hardening with no consumer action — the bounded callback context, the consolidated
constant-time comparator, the per-tenant partition-roll lock, the reap floor, the store
telemetry event, the cache-key framing, the roll-forward namespace scoping, the
change/generic_action dedup, the compile-cycle diagnostic, and the dropped dead spec arm.
See the CHANGELOG for the full list.

## v0.4.0 — hardening, ops-readiness, and enhancement

v0.4.0 is a hardening + ops-readiness + enhancement release. No breaking contract change for
existing consumers — the minor bump carries new public observability surfaces (the telemetry
default attach helper, the `:worker_timeout` result class, the ETS cache reference adapter)
and the span-events-out-of-scope decision (H22). Existing consumers are unchanged; all new
surfaces are opt-in.

- **External-recovery adversarial-absence proof + normative doc (H10):** a test proving the
  re-execution invariant against a lying-`:absent` adapter, and a normative section in
  `documentation/external-effects.md` stating the adapter MUST prove absence and the peer
  MUST enforce idempotency by operation key. No runtime guard — the trust is inherent to the
  design (ADR-0001).
- **Worker timeout distinguished from disconnect (H11):** the committed-claim worker's 30s
  timeout now surfaces as a distinct `:worker_timeout` result_class on
  `[:ash_onetime, :store_uncertainty]`, separate from `:disconnected` and `:unknown`. All
  three fail closed; the distinction is operational triage (pool/lock contention vs network
  partition).
- **Oban worker backoff + discard alert (H20, ADR-0005):** the three maintenance workers
  (Cleanup, Partition, Reap) declare a bounded, jittered `backoff/1` (30 s × attempt plus
  up-to-30 s jitter, capped at 120 s) instead of the default exponential, spacing DDL-class
  retries far enough apart that a contending lock holder can finish. A documented
  discard-alert SQL names the operational signal for a stranded partition roll.
- **Telemetry default attach handler (H21):** `AshOnetime.Telemetry.attach/0` — an opt-in
  helper that routes the closed event surface into a downstream `:metric` stream for a
  consumer's own aggregator. No `telemetry_metrics` dependency.
- **Telemetry span structure (H22):** documented that the library emits point events only
  (never span events), with the reason (`span/3` cannot preserve the value-free invariant)
  and a recommended consumer-applied `:telemetry.span/3` wrapper.
- **Operations runbook (H23):** three named procedures (backlog-stuck,
  partition-discard-detected, pool-saturated) with exact SQL/telemetry queries.
- **ETS cache reference adapter (H30):** `AshOnetime.Cache.Ets` — bounded, TTL-aware,
  supervised, no third-party dependency. Makes the cache-degradation path reachable.
- **Admission unit tests (H31), key_source/claim property tests (H32):** direct test
  coverage for the pure decision functions and the security-boundary invariants.
- **Runtime security-surface docs (H33):** `@doc` on `token.ex`, `key_source.ex`,
  `fingerprint.ex`, `telemetry.ex` public functions.
- **CI-matrix-asserted compatibility documented (H34):** CONTRIBUTING names the CI matrix as
  the guard against transitive semantic drift (not the dep bounds).

## Ash floor raised to 3.31.3 (v0.7.0, security-driven)

v0.7.0 tightens the Ash requirement from `>= 3.31.1 and < 4.0.0` to
`>= 3.31.3 and < 4.0.0`. EEF-CVE-2026-67579 (filter expression injection via a forged
keyset pagination cursor — HIGH, CVSS 7.5, unauthenticated, no application-side
workaround) affects Ash below 3.31.3 and is fixed only in 3.31.3; Hex additionally
retired 3.31.1 ("breaking change"). A security library must not admit a vulnerable
floor. Historical v0.7.0 upgrade instruction: **bump Ash to ≥ 3.31.3**, then pin that
`ash_onetime` minor:

```elixir
{:ash_onetime, "~> 0.7"}
```

See ADR-0004 (Security-driven Ash floor, amended 2026-08-18). The CI compatibility matrix
moves from `[3.31.1, latest]` to `[3.31.3, latest]` (transiently both cells resolve to
3.31.3 until the next Ash release).

## Ash floor raised to 3.31.1 (v0.3.0, security-driven)

v0.3.0 tightens the Ash requirement from `>= 3.29.3 and < 4.0.0` to
`>= 3.31.1 and < 4.0.0`. Two Ash advisories published during the v0.2.0 window affect Ash
below 3.31.1, both patched in 3.31.1: EEF-CVE-2026-70395 (predicate injection in
`manage_relationship` belongs_to lookup disclosing secret lookup keys) and
EEF-CVE-2026-69659 (memory exhaustion via unbounded keyset-cursor deserialization). A security
library must not admit a vulnerable floor. Historical v0.3.0 upgrade instruction:
**bump Ash to ≥ 3.31.1**, then pin that `ash_onetime` minor:

```elixir
{:ash_onetime, "~> 0.3"}
```

See ADR-0004 (Security-driven Ash floor). The CI compatibility matrix narrows from
`[3.29.3, 3.30.1, latest]` to `[3.31.1, latest]`.

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

The generator requires the 1.10.0 operation-hold migration to be present. Stop old maintenance
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
