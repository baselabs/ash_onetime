# Repository instructions

`ash_onetime` is a standalone Ash extension for explicit keyed-effect semantics.

## Boundaries

- Every protected action declares `:idempotency` or `:one_time_nonce`; there is no default strategy.
- Scope is explicit. Missing scope data is an error, never a global fallback.
- PostgreSQL is authoritative. Optional caches cannot grant admission.
- Nonce admission fails closed when authoritative state is unavailable.
- Idempotency may proceed when admission state is unavailable, but must surface that condition through telemetry.
- Verification callbacks return trusted local facts; action input cannot supply pre-verified facts.
- Do not depend on `ash_webhook_it`, `core_os`, QorPay, or Bounded Authority packages.
- Do not place phase, task, slice, release, schema, worker, contract, or API versions in durable project identifiers.
- macOS and Linux developers clone, build and run the gate as-is; Windows developers use WSL2,
  cloning inside the WSL filesystem (owner direction, October 4, 2026); CI runs on Linux only.
  Gates run in Elixir (`.exs`), never POSIX shell; keep `.gitattributes` (`* text=auto eol=lf`)
  intact.

## Workflow

Make the change, run the tests that cover it, commit with named paths, and push to `main`.
CI runs once on `main`; if it goes red, fix forward.

CI runs: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`,
`mix credo --strict`, `mix dialyzer`, `MIX_ENV=test mix dialyzer`, `mix deps.audit`,
`mix hex.audit`, `mix docs --warnings-as-errors`, `mix hex.build`, plus the release battery in
`CONTRIBUTING.md` on tags. Run the ones that cover your change.

- Publishing, deploying and pushes to mirrors always need the owner's approval for that action.
- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update the CHANGELOG when behavior, a dependency or a contract changes; other docs only when
  a contract changes.

Superseded instruction text lives in `docs/reference/agent-history.md`.
