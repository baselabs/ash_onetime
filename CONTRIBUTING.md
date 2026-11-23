# Contributing

The tests require a dedicated PostgreSQL server: `DATABASE_URL` must name
`ash_onetime_test` on `127.0.0.1`, as `postgres`, on a non-default port.
The URL guard cannot detect unrelated databases: never use a shared server.
Maintenance tests make cluster-wide grants and require a proven throwaway server: start it
with a hostname that begins `ao-` and set `ASH_ONETIME_TEST_SERVER` to that hostname. The
tests read `/etc/hostname` from the server and refuse a mismatch. In GitHub Actions the
hostname must also carry the run and attempt (`ao-<run_id>-<run_attempt>-`), which CI's
per-job containers do.

Every database job uses [the shared PostgreSQL action](.github/actions/postgres/action.yml).
Qualification and all other database lanes use the single checked-in
[engine reference](.github/postgres.ref), which currently selects PostgreSQL
18.6. Before pulling or starting it, the action anonymously resolves the public
`ghcr.io/baselabs/postgres:current` digest, refuses a mismatch, and pulls the checked reference
by digest. It never pulls the moving tag or reads private infra or runner configuration.

The action starts the engine with `--entrypoint baselabs-test-postgres`, the shape infra
qualifies; that command runs as the image's PostgreSQL user. The action
passes `TEST_PG_USER=postgres`, `TEST_PG_PASSWORD` and `TEST_PG_DATABASE=ash_onetime_test` by
environment name; these are isolated fixture values, never external-service credentials.
The action mounts `/var/lib/pg` as tmpfs owned by the image's PostgreSQL user (UID/GID 26),
and `/tmp` as disposable tmpfs. The command refuses existing data, initializes
`/var/lib/pg/data`, and executes
readable `/init/*.sql` in lexical order. Socket connections trust locally at `/tmp`; all TCP
rules use `scram-sha-256`. It listens on `0.0.0.0` inside the container, published only on
`127.0.0.1:18841`. Readiness uses `pg_isready -h 127.0.0.1`, which answers only after init.

Lanes that exercise replication start a second engine on loopback port `18842`, with
`-c wal_level=logical -c logging_collector=on -c log_destination=csvlog`. The action exports
`ASH_ONETIME_LOGICAL_URL`; workflows supply `DATABASE_URL`, `ASH_ONETIME_SUPERUSER_URL` and
the run-bound `ASH_ONETIME_TEST_SERVER`. Tests derive their connections from those values.
The ordinary and logical containers have separate data and hostnames. An `if: always()`
stop removes both with `docker rm -f -v`, including on failed jobs, and prints failure logs.
The PGDG platform client tools remain pinned in `.github/service-pins`; their major must
match the engine, while client patch releases may advance independently.

Work and qualification run the same suite and comparator partitions for every declared
PostgreSQL major. Suite jobs exclude `exit_boundary`; dedicated native, controls, matrix
and scheduling jobs cover that tag. The shared `.github/test-shards.json` declares every
matrix route and scheduling group, and each partition runs on each major. Both workflows
require every job and expanded matrix cell in their `qualified` verdict.

Native prerequisites use that same declaration to run the transport, driver, pool and TLS
programs separately on every major. Each native test has one `connection_streams` partition
value; its job selects that value, and the controls lane excludes the entire tag.

[`.github/postgres-compat.json`](.github/postgres-compat.json) declares each supported
non-platform major once, with its upstream patch tag, image digest and exact PGDG client
package. The shared toolchain reader validates the compatibility matrix and emits the
platform-plus-compatibility list used by every comparator group. The platform major is
excluded from the compatibility declaration. Compatibility jobs restore the release Mix
cache, so they need no additional cache-warmer job. Each installs client executables matching
its server major, with the pinned platform `libpq5` package.

The same PostgreSQL action starts these upstream images with their native entrypoint and
`POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB` derived from `TEST_PG_*`.
`POSTGRES_INITDB_ARGS=--auth-local=trust --auth-host=scram-sha-256` and
`POSTGRES_HOST_AUTH_METHOD=scram-sha-256` require SCRAM on every TCP rule. The data directory
is set with native `PGDATA=/var/lib/pg/data` on a `/var/lib/pg` tmpfs; upstream's entrypoint
creates and owns the data directory as its PostgreSQL user. Server arguments set
`password_encryption=scram-sha-256` and `unix_socket_directories=/var/run/postgresql,/tmp`:
upstream initialization requires its default socket, and probes can also use `/tmp`.
Ordinary and logical servers use the same loopback ports, readiness and unconditional
cleanup as the platform engine. `ASH_ONETIME_POSTGRES_COMPAT_MAJOR` selects the declared
contract for live version, data directory, auth and dump/restore assertions; an undeclared
major refuses. Without it, tests require the exact checked platform version.

Compile, tests, format checks, type checks and docs run in this repository's GitHub Actions
jobs on hosted Ubuntu runners, never on an agent's workstation or a shared build machine.
Push a work branch to run `Work`; it exercises the whole suite and both committed locks.
Agents do not dispatch workflows. A failed database start is fixed through this shared
action, never by starting a replacement server elsewhere.

Develop on macOS, Linux, or WSL2. In WSL2, clone inside the Linux filesystem,
not under `/mnt/c`. CI runs on Linux.

CI runs these checks:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test --exclude exit_boundary
mix credo --strict
mix dialyzer
MIX_ENV=test mix dialyzer
mix deps.audit
mix hex.audit
mix hex.build
```

Work and qualification run the same Ash floor/latest, additional BEAM, security,
release-gates and mutation job definitions. Every work-branch push exercises the local
Livebooks and optional consumers before a landing candidate exists. Those jobs run:

```sh
mix run --no-start scripts/check_deps_currency.exs
mix spark.cheat_sheets --check --extensions AshOnetime.Resource
MIX_ENV=test mix ash.codegen --check                      # committed test-repo codegen freshness
MIX_ENV=test mix run scripts/check_mutations.exs -- all   # with CI's DATABASE_URL
                                                          # CI runs it as shards: -- --shard I/N all
elixir scripts/check_livebooks.exs --local                # executes source cells against PostgreSQL
python3 scripts/release_archives.py build _build/release # package and docs archives, inspected
mix run scripts/check_optional_matrix.exs
```

The mutation manifest associates each enforcement marker with one source edit and an owning
assertion. Run `MIX_ENV=test mix run scripts/check_mutations.exs -- --self-test` to audit its
source anchors. The enforcing-site and native catalog checks are in
`test/ash_onetime/external_state/proof_inventory_test.exs`; they cover rendered SQL and library
classifications, plus fresh plain and hash PostgreSQL installs. An unmarked enforcement site
or catalog mismatch refuses the check. Mutation acceptance requires the owning assertion to
fail under the edit and the tagged cases to pass after exact source restoration.

To reset notebook installs, remove `_build/livebook-install` (or your `MIX_INSTALL_DIR`).
Each notebook rolls back and removes its UUID-named schema after accounting for its work.
External operations complete through the protected action, including durable business
rejections. An unresolved operation retains its recovery point and refuses rollback; see
[upgrading](documentation/upgrading.md).

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
`elixir scripts/check_livebooks.exs --published` against its own platform engine. It starts
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
throwaway superuser connection matching the lane's declared PostgreSQL major, supplied by
the shared action's fixture. The ordinary `DATABASE_URL` stays on the
project's dedicated test database. CI runs:

```sh
mix test test/ash_onetime/store/operation_hold_privileged_test.exs --only operation_hold_superuser
```

Supply the auxiliary URL only in the command environment, never in a commit.
Use a throwaway server and retire it when the command ends, pass or fail.
Destructive probes roll back; tests remove their isolated schemas and roles.
