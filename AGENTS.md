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

## Workflow (owner ruling, October 28, 2026)

Process is sized to the risk of the specific change, never the repository. Each check, gate,
record or review names the failure it prevents.

- **Heavy** when the diff touches admission, scope or replay safety (`admission.ex`, `scope.ex`,
  `replay_safety.ex`), the store and claims (`store/**`), tokens, signers and keys (`token.ex`,
  `signer/**`, `key_resolver.ex`, `key_source.ex`), verification (`verifier.ex`), the effect
  paths (`change.ex`, `generic_action.ex`, `external_effect.ex`) or migration templates
  (`priv/**`). Write the failing test first, get one independent review and do one fix round,
  and run the declared local gate once before pushing. Heavy pushes need the owner's approval.
- **Light** for everything else: focused checks on the changed behavior, then push; hosted CI
  is the gate. No outcome record, gauge or review; the commit message is the record. A light
  change the owner asked for lands without a separate push approval.
- Publishing, deploying and pushes to mirrors always need the owner's approval for that action.
- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update the CHANGELOG when behavior, a dependency or a contract changes; other docs only when
  a contract changes.

Declared local gate:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
MIX_ENV=test mix dialyzer
mix deps.audit
mix hex.audit
mix hex.build
```

Superseded instruction text lives in `docs/reference/agent-history.md`.
