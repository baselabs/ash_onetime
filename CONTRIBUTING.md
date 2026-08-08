# Contributing

Work directly from a clean checkout and keep changes focused on one behavior. New
behavior starts with a test that fails for the intended reason.

The test suite requires the dedicated PostgreSQL database documented in
`documentation/getting-started.md`. Set `DATABASE_URL` explicitly; the test harness
rejects any other database name or port.

Before reporting a change complete, run:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix deps.audit
mix hex.audit
mix spark.cheat_sheets --check --extensions AshOnetime.Resource
mix docs --warnings-as-errors
DATABASE_URL=ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test \
  MIX_ENV=test mix run scripts/check_mutations.exs -- all
mix hex.build
mix run scripts/check_package.exs
```

Inspect the Hex archive by exact file allowlist and compile/test an unpacked archive consumer;
building an archive alone is not package proof. Remove the generated tar after verification.

Run the gate battery on the runtime pinned in `.tool-versions` (Elixir 1.20.2,
Erlang/OTP 29), which is the supported and released runtime.

Every mutation row must name one exact source edit, one owned test and assertion, demonstrate
RED, restore the exact source bytes, and demonstrate GREEN. New public modules or dependencies
must update the exact architecture census. Public documentation changes must regenerate the
Spark reference and pass warnings as errors.

Never commit secrets, provider-specific signature implementations, reference-project
dependencies, or project-owned version suffixes in durable identifiers.
