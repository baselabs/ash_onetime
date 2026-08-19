# Contributing

Work directly from a clean checkout and keep changes focused on one behavior. New
behavior starts with a test that fails for the intended reason.

The test suite requires a dedicated PostgreSQL 18 database on `127.0.0.1:18841`. The suite
fails closed unless `DATABASE_URL` points at exactly that database and port; it rejects any
other name or port.

Before creating the container, verify that neither a container named `ash-onetime-postgres`
nor a listener on port `18841` already exists. Reuse the existing container across sessions;
do not start a second database on another port.

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

## Dependency compatibility

The published `mix.exs` bounds (`ash_postgres ~> 2.11`, `spark ~> 2.7`, and the Ash floor
`>= 3.31.3`) allow forward drift within their major lines. They are NOT the primary guard
against a transitive semantic shift — a future `ash_postgres` 2.x or `spark` 2.x minor that
changes transaction-visibility semantics the fail-closed logic depends on would still satisfy
the bound. The real guard is the **CI compatibility matrix** in `.github/workflows/ci.yml`:

- the declared Ash floor (`3.31.3`, CVE-justified per ADR-0004);
- a floating `latest` cell that resolves the newest published Ash 3.x on every run via
  `deps.unlock ash` / `deps.update ash` and re-runs the per-cell gate battery against it
  (format, compile warnings-as-errors, hex.audit, deps.audit, test, credo --strict,
  dialyzer, docs --warnings-as-errors, hex.build).

The release battery (mutation matrix, unpacked-package check, DSL cheat-sheet freshness)
is deliberately lock-pinned: it runs once in the `release-checks` job against the
committed lock, not per matrix cell.

Forward drift that breaks the fail-closed surface surfaces as a red `latest` cell, not as a
bound violation. When updating a dependency bound, ensure the matrix still covers the new
range; tightening a bound without matrix coverage is a regression in the guard. A breaking
major bump of `ash_postgres` or `spark` (3.x for either) is a matrix-extension event first —
add the cell, confirm green, then update the bound.

Never commit secrets, provider-specific signature implementations, reference-project
dependencies, or project-owned version suffixes in durable identifiers.
