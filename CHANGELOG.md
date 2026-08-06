# Changelog

All notable changes to this project are documented here.

## Unreleased

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
