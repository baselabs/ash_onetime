# Changelog

All notable changes to this project are documented in this file.

## Unreleased

## v0.5.0 — 2026-08-10

Minor bump: sixteen findings (M1–M5, L1–L11) from the v0.4.0 independent code review. Four
are CONSUMER-VISIBLE (read `documentation/upgrading.md` before upgrading); the rest are
internal hardening.

- **Independent code-review fixes (M1–M5, L1–L11):** sixteen findings from the v0.4.0
  independent code review, landed in four surface-cohesive clusters:
  - **M1 — bounded callback context:** verifier/mint/scope callbacks now receive exactly
    `%{resource:, action:}` (the prior code ran a dead `Map.take(trusted_context, [:keys,
    :now])` and threaded caller actor/tenant that no callback read; both dead paths removed).
    Least-privilege contract pinned by an admission test.
  - **M2 — reserved-input compile check now matches the runtime guard (CONSUMER-VISIBLE):** a protected
    resource declaring a reserved-named attribute (`:key`/`:issued_at`/...) with no accept
    now fails to compile (previously caught only at runtime by `reject_reserved/1`). Rename
    any such attribute (e.g. `:idempotency_key`).
  - **M3 — `@reserved` single-source:** the reserved-input list is now
    `AshOnetime.reserved_verification_inputs/0`, shared by the transformer (compile-time) and
    `Admission.reject_reserved/1` (runtime); the two copies can no longer drift.
  - **M4 — verifier defense-in-depth:** the Spark verifier now re-asserts strategy in
    `[:idempotency, :one_time_nonce]`, non-nil scope, non-nil key (mirroring the transformer),
    catching a transformer regression before runtime.
  - **M5 — clock override gate:** `@allow_test_clock_override` (`Mix.env() == :test`,
    deployment-fragile) replaced by `Application.compile_env(:ash_onetime,
    :allow_clock_override, false)` — the verify-side `:clock` override is off by default in
    every build; the test suite opts in via `config/test.exs`.
  - **L1 — constant-time comparator consolidated** onto `:crypto.hash_equals/2` (the
    hand-rolled XOR-reduce is gone); the `verify/3` rescue is documented as load-bearing for
    wrong-length signatures (`hash_equals/2` raises on unequal length — verified empirically).
  - **L2 — reap floor enforced at the guard:** `reap/3` rejects sub-86_400 callers with
    `:invalid_request` (no DB round-trip) instead of the migration's `22023` misclassified as
    `:store_invariant`.
  - **L3 — per-tenant advisory lock:** the partition-roll lock key is derived per-prefix, so
    distinct tenants roll concurrently (within-tenant serialization preserved). Cannot
    reintroduce a `CREATE PARTITION OF` race (per-schema partitions, distinct OIDs).
  - **L4 — dedicated `:ash_onetime_partitions` Oban queue (CONSUMER-VISIBLE):**
    `PartitionWorker` moves off the shared cleanup queue so forward partition creation
    (retention-safety) does not compete with routine cleanup under saturation. Operators must
    configure the queue. `documentation/operations.md` updated.
  - **L5 — worker error tuples carry the inner reason (CONSUMER-VISIBLE):** `{:error, :tag}` →
    `{:error, {:tag, reason}}` so the distinguishable store cause survives Oban exhaustion.
    Consumers pattern-matching the old bare atom must update to the 2-tuple inner shape.
  - **L6 — store-transaction exception telemetry:** `committed_claim_transaction` rescue
    emits `[:ash_onetime, :uncertain_exception]` with the exception class before collapsing
    to `:dispatched_unknown`. Telemetry-only posture preserved (no Logger).
  - **L7 — cache key length-prefix:** defense-in-depth framing for the cache key (today's
    fixed-32-byte components have no ambiguity; the framing future-proofs against a
    variable-length change).
  - **L8 — roll_forward OID scoping:** the `_default` partition OID subquery is now
    namespace-scoped (`pg_namespace`), matching the schema-scoped existence checks.
  - **L9 — change/generic_action dedup:** `dispatch_reservation`/`trusted_context`/
    `unavailable_error` hoisted to `Admission` (the near-verbatim duplicates removed).
  - **L10 — ensure_callbacks cycle diagnostic:** `Code.ensure_compiled` now distinguishes the
    `:unavailable`/`:module_unavailable` cycle case with clear ordering guidance.
  - **L11 — `prepare/3` spec dead arm removed** (the `Result.t()` arm never matched);
    dialyzer confirmed the downstream `store_error/1` was dead code and it was removed.

- **Replay read prunes to the claim's payload partition (H1):** the idempotency replay
  read path (`load_payload/2`) now constrains its `ash_onetime_response_payloads` query by
  `partition_date` as well as `claim_id`, turning a replay of a completed claim into a
  primary-key point lookup on the single monthly child partition instead of a scan of every
  monthly partition. The cost of a replay no longer grows with partition count (retention
  age). No behavior change on the authoritative path — the returned payload and the
  digest/partition-mismatch failure arms are unchanged. One incidental property changes: the
  read no longer detects a stray payload row in a *different* partition from the claim's
  authoritative one (this is necessarily dropped by partition pruning); cross-partition
  cardinality remains enforced at write time (`update_complete`) and re-asserted by the
  cleanup delete guard. ADR-0001 gains a read-path performance subsection. The production
  predicate is pinned by a registered mutation test; an EXPLAIN-based mechanism proof
  documents the pruning directly.

## v0.4.0 — 2026-08-09

Hardening, ops-readiness, and enhancement release. No breaking contract change for existing
consumers — the minor bump carries new public observability surfaces (the telemetry default
attach helper, the `:worker_timeout` result class, the ETS cache reference adapter) and the
span-events-out-of-scope decision. Existing consumers are unchanged; all new surfaces are
opt-in.

- **External-recovery adversarial-absence proof (H10):** a test proving the re-execution
  invariant against a lying-`:absent` adapter, plus a normative section in
  `documentation/external-effects.md` stating the adapter MUST prove absence and the peer
  MUST enforce idempotency by operation key. No runtime guard — the trust is inherent to the
  design (ADR-0001). The library's `:absent` trust is safe against a correct peer.
- **Worker timeout distinguished from disconnect (H11):** the committed-claim worker's 30s
  timeout now surfaces as a distinct `:worker_timeout` result_class on
  `[:ash_onetime, :store_uncertainty]`, separate from `:disconnected` and `:unknown`. All
  three fail closed; the distinction is operational triage (pool/lock contention vs network
  partition).
- **Oban worker backoff + discard alert (H20, ADR-0005):** the three maintenance workers
  (Cleanup, Partition, Reap) declare a bounded, jittered `backoff/1` (30–120 s) instead of
  the default exponential, so transient failures retry within the retention window. A
  documented discard-alert SQL names the operational signal for a stranded partition roll.
- **Telemetry default attach handler (H21):** `AshOnetime.Telemetry.attach/0` — an opt-in
  helper routing the closed event surface into a downstream `:metric` stream for a
  consumer's own aggregator. No `telemetry_metrics` dependency; the value-free invariant is
  preserved.
- **Telemetry span structure (H22):** documented that the library emits point events only
  (never span events), with the reason (`:telemetry.span/3` cannot preserve the value-free
  invariant — it force-injects `telemetry_span_context` and fires `:exception` inside the
  span before any caller rescue) and a recommended consumer-applied `:telemetry.span/3`
  wrapper.
- **Operations runbook (H23):** three named procedures (backlog-stuck,
  partition-discard-detected, pool-saturated) with exact SQL/telemetry queries.
- **ETS cache reference adapter (H30):** `AshOnetime.Cache.Ets` — bounded, TTL-aware,
  supervised, no third-party dependency. Makes the cache-degradation path reachable without
  a Redis dependency.
- **Admission unit tests (H31), key_source/claim property tests (H32):** direct test
  coverage for the pure decision functions and the security-boundary invariants (the
  suite grows from 500 to 553 tests).
- **Runtime security-surface docs (H33):** `@doc` on `token.ex`, `key_source.ex`,
  `fingerprint.ex`, `telemetry.ex` public functions.
- **CI-matrix-asserted compatibility documented (H34):** CONTRIBUTING names the CI matrix
  as the guard against transitive semantic drift (not the dep bounds).

## v0.3.0 — 2026-08-09

Security release: raises the Ash floor to the CVE-patched 3.31.1 and makes the architecture
census robust to dependency framework-injection drift. **Breaking dependency change** —
consumers on Ash 3.29.3–3.31.0 must bump Ash to ≥ 3.31.1 (the library is pre-1.0, so the
minor version carries the break per the documented convention).

- **Ash floor raised to 3.31.1** (from 3.29.3). EEF-CVE-2026-70395 (predicate injection in
  `manage_relationship` belongs_to lookup disclosing secret lookup keys) and
  EEF-CVE-2026-69659 (memory exhaustion via unbounded keyset-cursor deserialization) affect
  Ash below 3.31.1; both are patched in 3.31.1. `mix hex.audit` — a required gate — now fails
  on the 3.29.3 lock. Consumers pinned to Ash 3.29.3–3.31.0 must bump Ash to ≥ 3.31.1. See
  ADR-0004 (Security-driven Ash floor). The CI matrix narrows from
  `[3.29.3, 3.30.1, latest]` to `[3.31.1, latest]`.
- **Export census version-tolerance (test harness):** the documented public-export census no
  longer breaks on Splode/Ash framework-injection drift. It derives each module's
  project-authored exports from its own source AST, so framework-injected functions (e.g.
  Splode 0.3.2's `keyword_list_options?/0`) are auto-classified rather than hand-maintained,
  and the census guards exactly the project-owned public surface. This fixed a CI failure
  present since v0.1.0 across all Ash-matrix cells. Also fixes a seed-dependent flake in the
  ARCH-1 Splode-membership assertion (force-loads the module before the check).

## v0.2.0 — 2026-08-09

Feature release: the DPoP replay fence, forward response-partition maintenance (SEC-5/6), and
notebook-per-concern docs. New user-facing capabilities (minor bump); no contract break since
v0.1.1 — existing consumers are unchanged, all new surfaces are opt-in.

- **DPoP replay fence (admission):** add `commit: :independent` (default `:with_action`) on
  `:one_time_nonce` protections. When set, the nonce claim commits in its own transaction before
  the action body runs (via the existing `claim_committed` worker), so a body failure cannot make
  the proof reusable — RFC 9449 §11.1 request-attempt scope. A reused proof within the acceptance
  window is rejected with `:nonce_already_used` via the existing collision path. Opt-in: existing
  nonce consumers are byte-for-byte unchanged. Rejected (compile error) on `:idempotency`. No new
  table, migration, error code, or telemetry event. See ADR-0003 (Independent-commit nonce).
  Operational note: the `claim_committed`
  worker uses a +1 connection checkout per in-flight protected request and a 30s timeout (fails
  closed); size the pool accordingly.
- **SEC-5 (data-layer):** add forward monthly `response_payloads` partition creation
  (`Store.roll_partitions/2`, `mix ash_onetime.roll_partitions`,
  `AshOnetime.Oban.PartitionWorker`) plus a one-time forward migration
  (`mix ash_onetime.gen.roll_forward`). The install migration generates a fixed 13-month window;
  once retention exceeds it, payloads routed to `_default` and were never dropped (the drop path
  excludes `_default`), silently defeating bounded retention (ADR-0001:65 "reuse after retention
  is a new execution"). The roll keeps the window ahead of retention; the forward migration
  back-fills elapsed partitions, adds the index, and drains past-retention payloads stranded in
  `_default` via a claim-scoped delete. The roll is idempotent and concurrency-safe
  (advisory-locked, bounded `lock_timeout`). Existing installs run the forward migration once.
- **SEC-6 (data-layer):** add an index on `ash_onetime_idempotency_claims(response_partition)`.
  Cleanup's partition-empty check was a full scan per partition per cycle.
- Telemetry: add `:partitions_created` to the `[:ash_onetime, :cleanup]` event's result-class
  enum (closed-schema extension, pinned by a mutation fixture). See
  [Telemetry](documentation/telemetry.md).

## v0.1.1 — 2026-08-08

Adoption polish: a runnable Livebook walkthrough, richer Igniter installer, and adoption docs.
No contract change; safe minor bump from v0.1.0.

- Add runnable [Livebook notebooks](documentation/livebooks/idempotency.livemd) — one per
  concern (idempotency, one-time nonces, external recovery) — covering fresh execution, replay,
  fingerprint conflict, nonce spend/reuse, and the external-effect protocol end-to-end against a
  real PostgreSQL. Each notebook's code is regression-pinned by `test/ash_onetime/livebook_walkthrough_test.exs`.
- Extend the Igniter installer with a repeatable `--resource MyApp.MyResource` flag that wires
  `AshOnetime.Resource` into a resource and scaffolds a starter `onetime` block. Non-resource
  targets and missing modules are rejected loudly instead of silently no-op'ing.
- Add adoption docs: [Recipes](documentation/recipes.md),
  [Telemetry](documentation/telemetry.md), [Upgrading](documentation/upgrading.md), and
  [FAQ](documentation/faq.md). Add a README "When to use this vs. hand-rolled idempotency"
  section and a "Try it" livebook pointer.
- Reorder [Getting started](documentation/getting-started.md) to lead with the consumer
  quickstart (install → protect → handle the result); move the test-DB harness to
  CONTRIBUTING. Fix the stale "not published yet" line (the package is live on Hex).

## v0.1.0 — 2026-08-08

- **Breaking (DSL):** collapse the dual `limits` surface into a single `protect`-level
  vocabulary. Response-size limits can no longer be declared on the `response` entity
  (`response ..., limits: [...]`); declare them on `protect` instead. The `protect limits:`
  option now accepts the full 11-key union vocabulary: `max_key_bytes`, `max_token_bytes`,
  `max_scope_components`, `max_fingerprint_bytes`, `verifier_timeout_ms`,
  `max_cache_entry_bytes` (key/verification/cache paths), and `max_response_bytes`,
  `max_response_depth`, `max_response_nodes`, `max_response_entries`,
  `max_response_scalar_bytes` (response payload). All keys are validated at compile time.
  To migrate, move any `response ..., limits: [max_response_*: ...]` keys onto
  `protect ..., limits: [...]`.
- Make `AshOnetime.Error` a Splode error of class `:invalid` so Ash recognizes it and
  preserves the typed `:code` through the action pipeline. Before, a protected-action
  failure was wrapped as `Ash.Error.Unknown.UnknownError` and the code (e.g.
  `:nonce_already_used`, `:key_reused_with_different_request`) was lost before it could
  reach the caller. Add `AshOnetime.Error.code/1` to recover the code from a leaf or class
  wrapper. See `documentation/errors.md` for the code→HTTP table.
- Add a caller-visible replayed-vs-fresh signal. After `Ash.create/2` / `Ash.run_action/2`
  returns, `AshOnetime.replayed?/1` reports whether the result was a stored replay (`true`),
  a fresh execution (`false`), or carries no signal (`nil` — untracked execution,
  primitive-return action, or unprotected). The signal rides `__metadata__[:ash_onetime]`
  for tracked admission classes; `:untracked` is deliberately not stamped to preserve
  untracked transparency. See `documentation/replay.md`.
- Broaden the Ash dependency requirement from `~> 3.29.0` (only 3.29.x) to
  `>= 3.29.3 and < 4.0.0`, so the package installs across the whole Ash 3.x line.
  The floor is 3.29.3, not 3.29.0: EEF-CVE-2026-55736 (private action arguments
  settable by user input) affects Ash 3.29.0–3.29.2 and is fixed in 3.29.3.
- Add a CI compatibility matrix (`.github/workflows/ci.yml`), configured to run
  the full gate battery — including `mix hex.audit` — against the 3.29.3 floor,
  each intermediate minor, and a floating `latest` Ash 3.x cell on every push
  and pull request once the repository is pushed to a GitHub remote.
- Establish the standalone Mix package, PostgreSQL 18 test harness, package boundary
  checks, accepted architecture decision, and project documentation.
- Add the per-action Spark resource DSL, normalized introspection, precompile rejection
  boundary, fail-closed runtime stubs, compile-fixture battery, and mutation proofs.
- Add PostgreSQL-authoritative idempotency and one-time nonce admission with exact operation,
  scope, key, fingerprint, transaction, and failure-direction invariants.
- Add transactional CRUD and generic-action execution, classified typed response persistence,
  digest-bound replay, and replay-safe lifecycle enforcement. The response contract digest binds
  the codec options, so stored bytes cannot be reinterpreted under changed options; replayed
  results carry the same `selected`/`tenant` metadata as a first execution.
- Enforce the configurable `max_scope_components`, `max_fingerprint_bytes`, and
  `max_response_bytes` limit overrides at their declared values, not only their package ceilings.
- Add bounded canonical encoding, HMAC-SHA-256 and Ed25519 signing, trusted verification facts,
  self-identifying tokens, and inclusive nonce windows.
- Add committed external-effect recovery points, stable peer operation keys, conservative
  ambiguous-outcome handling, and crash recovery.
- Add unpartitioned and operation-hash-partitioned claim layouts, date-partitioned response
  payloads, strict bounded cleanup, deletion guards, the prune task, and optional Oban cleanup.
- Add PostgreSQL-gated cache degradation, optional Plug header extraction, closed value-free
  telemetry, deterministic Igniter installation, and migration generation.
- Add system, architecture, mutation, documentation, exact Hex archive, unpacked consumer,
  and dependency audit release gates, run on the pinned Elixir 1.20.2 / Erlang/OTP 29 runtime.
