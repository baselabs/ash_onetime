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
- Ash 3.29.x
- AshPostgres 2
- PostgreSQL 18 for the project test harness

The supported runtime is the one pinned in `.tool-versions` (Elixir 1.20.2,
Erlang/OTP 29); release gates run against it. Other versions permitted by the
declared requirements are not part of the tested matrix.

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
