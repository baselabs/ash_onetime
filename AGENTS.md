# Repository instructions

`ash_onetime` is a standalone Ash extension for explicit keyed-effect semantics.

## Boundaries

- Every protected action declares `:idempotency` or `:one_time_nonce`; there is no default strategy.
- Scope is explicit. Missing scope data is an error, never a global fallback.
- PostgreSQL is authoritative. Optional caches cannot grant admission.
- Nonce admission fails closed when authoritative state is unavailable.
- Idempotency may proceed when admission state is unavailable, but must surface that condition through telemetry.
- Verification callbacks return trusted local facts; action input cannot supply pre-verified facts.
- Do not depend on or name the reference projects listed (as digests) in `scripts/reference_projects.exs`.
- macOS and Linux are supported; Windows developers use WSL2, cloning inside its filesystem.
  CI runs on Linux; gates use Elixir (`.exs`) and `.gitattributes` preserves LF checkouts.

The lock and `.tool-versions` pin development releases; published ranges preserve supported floors.

- Publishing, deploying and pushes to mirrors always need the owner's approval for that action.

## Build and test

- Build: `mix compile --warnings-as-errors`, through the box route.
- Covering tests: `mix test <paths>` through the box route against PostgreSQL 18 (`DATABASE_URL`; see `CONTRIBUTING.md`).
- **Before a push.** `mix precommit`, through the box route.
- **Type check.** `mix dialyzer` (and `MIX_ENV=test mix dialyzer`), through the box route.
- **Never on the workstation.** Every Mix task that compiles (build, tests, dialyzer, docs, precommit) runs through the box route; the full suite runs only in CI.
- **Exceptions.** A release runs the release battery in `CONTRIBUTING.md` on the box.
- **Landing.** CI runs the full suite on a candidate branch before `main` moves.
