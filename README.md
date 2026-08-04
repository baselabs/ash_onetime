# ash_onetime

`ash_onetime` is an Ash extension for explicit keyed-effect semantics. It separates
replay-safe idempotency from collision-rejecting one-time nonces and uses PostgreSQL as
the authoritative admission store.

## Status

The package is under active construction and is not published. The accepted public
contract requires every protected action to choose `:idempotency` or `:one_time_nonce`
and declare a nonempty scope. There is no default strategy or global scope fallback.
The resource DSL, normalized introspection, and compile-time safety boundary are present;
the admission store and action execution path are not yet present.

## Compatibility

- Elixir 1.15 through 1.20
- Erlang/OTP 26 through 29
- Ash 3
- AshPostgres 2
- PostgreSQL 18 for the project test harness

The compatibility matrix is exercised before release. Local development currently
pins Elixir 1.20.2 and Erlang/OTP 29 in `.tool-versions`.

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

## License

MIT. See [LICENSE](LICENSE).
