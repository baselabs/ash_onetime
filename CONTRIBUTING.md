# Contributing

Work directly from a clean checkout and keep changes focused on one behavior. New
behavior starts with a test that fails for the intended reason.

The test suite requires a dedicated PostgreSQL 18 database on `127.0.0.1`. The suite
fails closed unless `DATABASE_URL` targets exactly that dedicated database under the
`postgres` user on a non-default port; the port is per-machine, so the dedicated instance
never collides with another local listener.

`docker compose up -d` provisions that database from the committed compose file
(postgres:18 — the same image CI uses), interpolating the `PG*` variables from `.env`.
Copy `.env.example` to `.env`, pick a random non-standard `PGPORT`, and keep the port
inside `DATABASE_URL` in sync with it; `.env` also carries `HEX_API_KEY` when publishing.
If a listener on your chosen port already exists, reuse it; do not start a second
database on another port.

```sh
cp .env.example .env   # then set PGPORT (and DATABASE_URL's port) to a free port
docker compose up -d

export DATABASE_URL=ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test  # as in your .env
mix deps.get
mix test
```

The repository is cross-platform by requirement: the same clone and the same gate
battery must work on macOS, Linux, and Windows (CI's `windows-build` lane proves
the Windows pickup surface on every push). On Windows, set the variable in
PowerShell instead of `export`:

```powershell
$env:DATABASE_URL = "ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test"
```

(match the port to your `.env` `PGPORT` in every shell form)

Before reporting a change complete, run:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
MIX_ENV=test mix dialyzer
mix deps.audit
mix hex.audit
mix run --no-start scripts/check_deps_currency.exs
mix spark.cheat_sheets --check --extensions AshOnetime.Resource
mix docs --warnings-as-errors
MIX_ENV=test mix run scripts/check_mutations.exs -- all   # with DATABASE_URL exported as in your .env
mix hex.build
mix run scripts/check_package.exs
mix run scripts/check_optional_matrix.exs
```

Inspect the Hex archive by exact file allowlist and compile/test an unpacked archive consumer;
building an archive alone is not package proof. Remove the generated tar after verification.
The optional-integration matrix compiles a consumer per dependency set (none/plug/oban/
igniter/all/mint-pin), asserts none of the optional deps leak into the package's runtime
application closure, and proves the security floors bind in resolution: exact advised
pins (igniter == 0.8.3, mint == 1.9.3) must FAIL to resolve next to this package.

Run the gate battery on the runtime pinned in `.tool-versions` (Elixir 1.20.4 on
Erlang/OTP 29.0.3) — the primary CI runtime. Development on OTP 28 is equally
supported: `config/config.exs` refuses any OTP release outside the supported set
(`28`, `29`) before anything compiles, and CI's dedicated `otp-28` job proves that
end. The set grows only in the same commit that adds the CI leg.

Every mutation row must name one exact source edit, one owned test and assertion, demonstrate
RED, restore the exact source bytes, and demonstrate GREEN. New public modules or dependencies
must update the exact architecture census. Public documentation changes must regenerate the
Spark reference and pass warnings as errors.

Never commit secrets, provider-specific signature implementations, reference-project
dependencies, or project-owned version suffixes in durable identifiers.

## Dependency compatibility

The consumer `mix.exs` bounds (`ash_postgres ~> 2.13`, `spark ~> 2.7`, and the Ash floor
`>= 3.33.4`) allow forward drift within their major lines. AshSql additionally requires
`~> 0.7 and >= 0.7.1`; optional Igniter and Mint require `~> 0.8 and >= 0.8.4` and
`~> 1.10 and >= 1.10.1`. These security floors follow ADR 0004. They are NOT the primary guard
against a transitive semantic shift — a future `ash_postgres` 2.x or `spark` 2.x minor that
changes transaction-visibility semantics the fail-closed logic depends on would still satisfy
the bound. The real guard is the **CI compatibility matrix** in `.github/workflows/ci.yml`:

- the declared Ash floor (`3.33.4`, CVE-justified per ADR-0004);
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

Dependency currency is mechanical, not remembered: `scripts/check_deps_currency.exs` exits
nonzero whenever `mix hex.outdated` shows resolver-updatable drift ("Update possible") and
prints blocked packages with the requirement chains that hold them. Anything deliberately
not at latest carries an inline reason in `mix.exs`; "we never bumped it" is not a reason.
After every dependency move, rerun `mix hex.audit` — Hex advisories lag public disclosures
by hours, so after a fresh disclosure also check the advisory's affected range (OSV/GHSA)
for each directly-consumed package in the affected family.

Never commit secrets, provider-specific signature implementations, reference-project
dependencies, or project-owned version suffixes in durable identifiers.
