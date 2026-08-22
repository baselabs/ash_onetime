# Upgrading

Version-to-version migration notes. `ash_onetime` follows semantic versioning: from 1.0.0,
breaking DSL or contract changes bump the major version (pre-1.0, breaking changes could
land in a minor), and each breaking change lands here with the exact edit to make.

The current package release is v1.1.0 on [Hex](https://hex.pm/packages/ash_onetime). Pin the
minor whose public capabilities you use and review this page on each minor bump:

```elixir
{:ash_onetime, "~> 1.1"}
```

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

## Unreleased — additive (no upgrade action)

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

## v0.6.0 — enhancements (no upgrade action)

v0.6.0 is an **additive** minor bump: two new capabilities (a `mix ash_onetime.doctor`
upgrade-preflight task and a Phoenix integration guide) plus internal perf/cleanliness gap
closures. No breaking change, no DSL/contract change, no upgrade action for existing consumers.

- **`mix ash_onetime.doctor --repo MyApp.Repo`** — a read-only preflight that checks the Ash
  security floor, Oban queue configuration (advisory), and prefix validity. Run it after install
  and after each upgrade to catch the silent-failure modes (e.g., a missing
  `:ash_onetime_partitions` queue that strands the retention-safety path).
- **[Phoenix integration guide](phoenix.md)** — a runnable Phoenix controller recipe wiring the
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
  queue (L4).** Forward partition creation is the retention-safety path; it previously shared
  `:ash_onetime_cleanup` with routine cleanup. **Add the queue to your Oban config** or
  `PartitionWorker` jobs sit unscheduled and bounded retention silently degrades past the
  install window:

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
floor. **Bump Ash to ≥ 3.31.3**, then bump `ash_onetime`:

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
library must not admit a vulnerable floor. **Bump Ash to ≥ 3.31.1**, then bump `ash_onetime`:

```elixir
{:ash_onetime, "~> 0.3"}
```

See ADR-0004 (Security-driven Ash floor). The CI compatibility matrix narrows from
`[3.29.3, 3.30.1, latest]` to `[3.31.1, latest]`.

## Forward response-partition maintenance (apply once to existing installs)

Two data-layer fixes shipped for the response store: the `response_partition` index (cleanup's
partition-empty check was a full scan) and forward monthly partition creation (payloads past
the install window routed to `_default` and were never dropped, silently defeating bounded
retention). Greenfield installs on the current version get both automatically from the install
migration. **Existing installs should generate and run the forward migration once:**

```sh
mix ash_onetime.gen.roll_forward --repo MyApp.Repo --months 18
mix ecto.migrate
```

It adds the index, back-fills the elapsed+forward partitions, and drains past-retention
payloads stranded in `_default`. After that, schedule `mix ash_onetime.roll_partitions` (or
`AshOnetime.Oban.PartitionWorker`) on a cadence ahead of your retention horizon — see
[Operations](operations.md#forward-response-partitions). This is additive (no DSL/contract
change) and does not require a dependency version bump.

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
behaviours (`AshOnetime.Codec`, the `classify/2` contract on `AshOnetime.ResponseClassifier`,
verification callbacks returning `AshOnetime.Verified`).
