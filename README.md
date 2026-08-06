# ash_onetime

`ash_onetime` is an Ash extension for explicit keyed-effect semantics. It separates
replay-safe idempotency from collision-rejecting one-time nonces and uses PostgreSQL as
the authoritative admission store.

## Status

The package implements its accepted public contract and is not yet published. Every
protected action chooses `:idempotency` or `:one_time_nonce` and declares a nonempty scope;
there is no default strategy or global scope fallback. PostgreSQL-authoritative admission,
transactional Ash execution, typed replay, fail-closed nonce spending, signed tokens,
external-effect recovery, bounded cleanup, optional cache/Plug/Oban integrations, and
release gates are present.

## Compatibility

- Elixir `~> 1.20` (developed and tested on 1.20.2)
- Erlang/OTP 29
- Ash `>= 3.29.3` and `< 4.0.0` (the whole 3.x line from the 3.29.3 floor up)
- AshPostgres 2
- PostgreSQL 18 for the project test harness

The floor is Ash 3.29.3, not 3.29.0: EEF-CVE-2026-55736 (private action
arguments settable by user input) affects Ash 3.29.0–3.29.2 and is fixed in
3.29.3. Compatibility across the range is verified by the full gate battery —
including `mix hex.audit` — run against the 3.29.3 floor, each intermediate
minor, and the latest published Ash 3.x. `.github/workflows/ci.yml` is
configured to re-run this matrix on every push and pull request. The pinned
development runtime is Elixir 1.20.2 / Erlang/OTP 29 (`.tool-versions`).

## Development

Start the dedicated test database described in [Getting started](documentation/getting-started.md),
then run:

```sh
mix deps.get
DATABASE_URL=ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test mix test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete gate battery and
[usage-rules.md](usage-rules.md) for non-negotiable integration boundaries.
The [Getting started guide](documentation/getting-started.md) includes the resource DSL.

## Guides

- [Resource DSL](documentation/dsl.md)
- [Idempotency](documentation/idempotency.md)
- [One-time nonces](documentation/one-time-nonces.md)
- [External effects and recovery](documentation/external-effects.md)
- [Operations](documentation/operations.md)
- [Security model](documentation/security.md)
- [Generated Spark DSL reference](documentation/dsls/DSL-AshOnetime.Resource.md)

## License

MIT. See the repository `LICENSE` file.
