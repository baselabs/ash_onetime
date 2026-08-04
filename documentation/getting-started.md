# Getting started

`ash_onetime` currently targets Elixir 1.15+, Erlang/OTP 26+, Ash 3, AshPostgres 2,
and PostgreSQL 18.

## Test database

The suite fails closed unless `DATABASE_URL` points to the dedicated database and port:

```sh
docker run --name ash-onetime-postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=ash_onetime_test \
  -p 127.0.0.1:18841:5432 \
  -d postgres:18

export DATABASE_URL=ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test
mix deps.get
mix test
```

Before creating the container, verify that neither a container named
`ash-onetime-postgres` nor a listener on port `18841` already exists. Reuse the existing
dedicated container; do not start a second database on another port.

## Package dependency

The package is not published yet. After publication, consumers will add the released
Hex requirement and enable `AshOnetime.Resource` on individual Ash resources. The DSL,
migration, and operations guides will land with the corresponding implementation.
