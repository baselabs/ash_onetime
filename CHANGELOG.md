# Changelog

All notable changes to this project are documented here.

## Unreleased

- Establish the standalone Mix package, PostgreSQL 18 test harness, package boundary
  checks, accepted architecture decision, and project documentation.
- Add the per-action Spark resource DSL, normalized introspection, precompile rejection
  boundary, fail-closed runtime stubs, compile-fixture battery, and mutation proofs.
- Add PostgreSQL-authoritative idempotency and one-time nonce admission with exact operation,
  scope, key, fingerprint, transaction, and failure-direction invariants.
- Add transactional CRUD and generic-action execution, classified typed response persistence,
  digest-bound replay, and replay-safe lifecycle enforcement.
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
