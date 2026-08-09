# Changelog

All notable changes to this project are documented in this file.

## Unreleased

Security-driven dependency floor bump (breaking for consumers on the old floor).

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
  present since v0.1.0 across all Ash-matrix cells.

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
