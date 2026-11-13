# Repository instructions

`ash_onetime` is a standalone Ash extension for explicit keyed-effect semantics.

## Boundaries

- Every protected action declares `:idempotency` or `:one_time_nonce`; there is no default strategy.
- Scope is explicit. Missing scope data is an error, never a global fallback.
- PostgreSQL is authoritative. Optional caches cannot grant admission.
- Nonce admission fails closed when authoritative state is unavailable.
- Idempotency may proceed when admission state is unavailable, but must surface that condition through telemetry.
- Verification callbacks return trusted local facts; action input cannot supply pre-verified facts.
- Do not depend on `ash_webhook_it` or Bounded Authority packages.
- Do not place phase, task, slice, release, schema, worker, contract, or API versions in durable project identifiers.
- macOS and Linux developers clone, build and run the gate as-is; Windows developers use WSL2,
  cloning inside the WSL filesystem (owner direction, October 4, 2026); CI runs on Linux only.
  Gates run in Elixir (`.exs`), never POSIX shell; keep `.gitattributes` (`* text=auto eol=lf`)
  intact.

## Workflow

Make the change, run the tests that cover it, commit with named paths, and land it on `main`.
CI runs once on `main`; if it goes red, fix forward. The lock and `.tool-versions` hold the
latest stable releases; the published dependency ranges stay as wide as the supported floors.

- Publishing, deploying and pushes to mirrors always need the owner's approval for that action.
- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update the CHANGELOG when behavior, a dependency or a contract changes; other docs only when
  a contract changes.

## Build and test

- **Build.** `mix compile --warnings-as-errors`, through the box route.
- **Covering tests.** `mix test <paths>` for the changed files and their direct dependents, on
  the box route, against a real PostgreSQL 18 test database (`DATABASE_URL`, see
  `CONTRIBUTING.md`).
- **Before a push.** `mix precommit`: format check, compile with warnings as errors,
  `credo --strict`, the DSL cheat-sheet freshness check, `hex.audit` and `deps.audit`. Not
  Dialyzer and not the full suite.
- **Exceptions.** A release runs the release battery in `CONTRIBUTING.md` on the box.
- **Development tooling.** None beyond the Mix project's own dev and test dependencies.
- **Landing.** `kimosabe-land`: CI's full suite on `kci/**` before `main` moves.
- **CI.** One `ci.yml`. `compat` runs the gate battery (format, compile, `hex.audit`,
  `deps.audit`, the full suite, `credo --strict`, Dialyzer in dev and test, docs, `hex.build`)
  on the Ash floor and the latest Ash; `release-checks` runs the release battery against the
  committed lock; `otp-28` runs the suite on OTP 28; `security` scans `mix.lock` offline with
  osv-scanner and runs `hex.audit`.

Superseded instruction text lives in `docs/reference/agent-history.md`.
