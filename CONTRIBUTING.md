# Contributing

The tests require a dedicated PostgreSQL 18 instance: `DATABASE_URL` must name
`ash_onetime_test` on `127.0.0.1`, as `postgres`, on a non-default port.
The URL guard cannot detect unrelated databases: never use a shared server.
Maintenance tests make cluster-wide grants and require a proven throwaway server: start it
with a hostname that begins `ao-` and set `ASH_ONETIME_TEST_SERVER` to that hostname. The
tests read `/etc/hostname` from the server and refuse a mismatch. In GitHub Actions the
hostname must also carry the run and attempt (`ao-<run_id>-<run_attempt>-`), which CI's
per-job service containers do.

The repository ships no database container. Point `.env` at a PostgreSQL 18 you
already run as a dedicated instance: copy `.env.example` to `.env`, set `PGPORT` to
that server's non-standard port and keep the port inside `DATABASE_URL` in sync. If the
server is unreachable, fix or report it; do not start a second database on another port.

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

CI's release-gates and mutation-battery jobs also run these on every candidate:

```sh
mix run --no-start scripts/check_deps_currency.exs
mix spark.cheat_sheets --check --extensions AshOnetime.Resource
MIX_ENV=test mix ash.codegen --check                      # committed test-repo codegen freshness
MIX_ENV=test mix run scripts/check_mutations.exs -- all   # with DATABASE_URL exported as in your .env
                                                          # CI runs it as shards: -- --shard I/N all
elixir scripts/check_livebooks.exs --local                # executes source cells against PostgreSQL
python3 scripts/release_archives.py build _build/release # package and docs archives, inspected
mix run scripts/check_optional_matrix.exs
```

To reset notebook installs, remove `_build/livebook-install` (or your `MIX_INSTALL_DIR`).
Each notebook removes its UUID-named schema after verification.

Infra dispatches releases through the `Publish to Hex` workflow after the version commit
qualifies on the default branch. No one publishes from a workstation. The workflow requires
an existing package on Hex, an untagged version and dated release notes. It builds and inspects
the package and docs archives before the one keyed step uploads only missing archives,
without loading a Mix project. It refuses retired releases or differing package bytes. Docs
bytes are never compared, and readable served docs are kept. Each docs archive carries root
`release.json` naming the package, version and build commit. Keyless read-back requires
`index.html` and provenance naming the dispatched commit or an ancestor on the default branch;
that is the published commit. It never replaces a served archive. If Hex holds either upload
for approval, infra finishes it by dispatching again on the same commit after approval.

Only after both archives are served and verified does the publish job upload `release-assets`,
containing the package archive, downloaded served docs archive, recomputed `SHA256SUMS` and
checkout changelog `NOTES.md`. Held runs upload no artifact. Infra compares the package with
that artifact, tags the published commit and creates the GitHub release from those files.
Consumers verify files from that GitHub release; the workflow artifact expires. No workflow
creates a GitHub release or runs on a tag.

The separate, keyless `published-livebooks` job waits until the archives are served, then runs
`elixir scripts/check_livebooks.exs --published` against its own PostgreSQL service. It starts
from Hex rather than the checkout and executes all notebook cells against the package users
will install. Qualification executes the notebooks only with `--local`.

Open work is tracked in [GitHub issues](https://github.com/baselabs/ash_onetime/issues).

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
