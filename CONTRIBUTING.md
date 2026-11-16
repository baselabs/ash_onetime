# Contributing

The tests require a dedicated PostgreSQL 18 instance: `DATABASE_URL` must name
`ash_onetime_test` on `127.0.0.1`, as `postgres`, on a non-default port.
The URL guard cannot detect unrelated databases: never use a shared server.
Maintenance tests make cluster-wide grants and require a proven per-run container:
set `TEST_ENV_RUN` to a name whose container `/etc/hostname` is `<name>-packages-pg`.
The box route and CI supply that isolated server.

The repository ships no database container. Point `.env` at a PostgreSQL 18 you
already run as a dedicated instance: copy `.env.example` to `.env`, set `PGPORT` to
that server's non-standard port and keep the port inside `DATABASE_URL` in sync;
`.env` also carries `HEX_API_KEY` when publishing. If the server is unreachable, fix
or report it; do not start a second database on another port.

```sh
cp .env.example .env   # then set PGPORT and DATABASE_URL's port to your server's port
set -a && . ./.env && set +a
mix deps.get
mix test
```

Develop on macOS, Linux, or WSL2. In WSL2, clone inside the Linux filesystem,
not under `/mnt/c`. CI runs on Linux.

CI runs these checks; run the ones that cover your change:

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

Run these additional commands before publishing a release:

```sh
mix run --no-start scripts/check_deps_currency.exs
mix spark.cheat_sheets --check --extensions AshOnetime.Resource
mix docs --warnings-as-errors
MIX_ENV=test mix ash.codegen --check                      # committed test-repo codegen freshness
MIX_ENV=test mix run scripts/check_mutations.exs -- all   # with DATABASE_URL exported as in your .env
elixir scripts/check_livebooks.exs --local                # executes source cells against PostgreSQL
mix run scripts/check_package.exs                         # after the gate's mix hex.build
mix run scripts/check_optional_matrix.exs
```

To reset notebook installs, remove `_build/livebook-install` (or your `MIX_INSTALL_DIR`).
Each notebook removes its UUID-named schema after verification.

After publishing, run `elixir scripts/check_livebooks.exs --published` with the same
`DATABASE_URL`. The published mode starts from Hex rather than the checkout, then executes all
notebook cells against PostgreSQL; it is the executable consumer check for the artifact users
will install.

Never commit secrets, provider-specific signature implementations, or reference-project dependencies.

## Dependency compatibility

The consumer `mix.exs` bounds (`ash_postgres ~> 2.15 and >= 2.15.2`, `spark ~> 2.7`, and the
Ash floor `>= 3.37.2`) allow forward drift within their major lines. AshSql additionally requires
`~> 0.8 and >= 0.8.6`; optional Igniter and Mint require `~> 0.8 and >= 0.8.4` and
`~> 1.10 and >= 1.10.2`. These security floors follow ADR 0004.

After every dependency move, rerun `mix hex.audit` — Hex advisories lag public disclosures
by hours, so after a fresh disclosure also check the advisory's affected range (OSV/GHSA)
for each directly-consumed package in the affected family.

## Privileged operation-hold probes

`test/ash_onetime/store/operation_hold_privileged_test.exs` carries the
`:operation_hold_superuser` tag. It skips unless `ASH_ONETIME_SUPERUSER_URL` supplies a separate,
throwaway PostgreSQL 18 superuser connection. The ordinary `DATABASE_URL` stays on the
project's dedicated test database. Run:

```sh
mix test test/ash_onetime/store/operation_hold_privileged_test.exs --only operation_hold_superuser
```

Supply the auxiliary URL only in the command environment, never in a commit.
Use a throwaway server and retire it when the command ends, pass or fail.
Destructive probes roll back; tests remove their isolated schemas and roles.
