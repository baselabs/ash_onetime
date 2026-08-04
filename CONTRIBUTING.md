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
mix hex.build
```

Never commit secrets, provider-specific signature implementations, reference-project
dependencies, or project-owned version suffixes in durable identifiers.
