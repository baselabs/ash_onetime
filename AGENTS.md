# Repository instructions

`ash_onetime` is a standalone Ash extension for explicit keyed-effect semantics.

## Required checks

Run these commands before reporting a change complete:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix deps.audit
mix hex.build
```

## Boundaries

- Every protected action declares `:idempotency` or `:one_time_nonce`; there is no default strategy.
- Scope is explicit. Missing scope data is an error, never a global fallback.
- PostgreSQL is authoritative. Optional caches cannot grant admission.
- Nonce admission fails closed when authoritative state is unavailable.
- Idempotency may proceed when admission state is unavailable, but must surface that condition through telemetry.
- Verification callbacks return trusted local facts; action input cannot supply pre-verified facts.
- Do not depend on `ash_webhook_it`, `core_os`, QorPay, or Bounded Authority packages.
- Do not place phase, task, slice, release, schema, worker, contract, or API versions in durable project identifiers.
